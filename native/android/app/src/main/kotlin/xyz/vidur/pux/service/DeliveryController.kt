package xyz.vidur.pux.service

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withTimeout
import xyz.vidur.pux.api.ApiClient
import java.net.UnknownHostException
import xyz.vidur.pux.api.RateLimitedException
import xyz.vidur.pux.api.RecordNotFoundException
import xyz.vidur.pux.api.RegistrationRejectedException
import xyz.vidur.pux.api.TooManyDevicesException
import xyz.vidur.pux.model.DeliveryState
import xyz.vidur.pux.model.DeliveryStatus
import xyz.vidur.pux.storage.RecordStore
import java.util.Random
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

interface FcmRegistrar {
    suspend fun register()
}

class DefaultFcmRegistrar : FcmRegistrar {
    override suspend fun register() {
        FirebaseMessaging.getInstance().register().await()
    }
}

/**
 * Manages push delivery lifecycle, Firebase Installation ID (FID) registration,
 * FCM registration callbacks, and transient failure retries with exponential backoff and jitter.
 */
class DeliveryController(
    private val recordStore: RecordStore,
    private val apiClient: ApiClient,
    private val scope: CoroutineScope = CoroutineScope(Dispatchers.IO),
    private val fcmRegistrar: FcmRegistrar = DefaultFcmRegistrar(),
    private val handler: Handler = Handler(Looper.getMainLooper())
) {
    private val _status = MutableStateFlow(DeliveryStatus(DeliveryState.IDLE))
    val status: StateFlow<DeliveryStatus> = _status.asStateFlow()

    private val registrationMutex = Mutex()
    private var retryRunnable: Runnable? = null
    private var activeJob: Job? = null
    private var currentRefreshJob: Job? = null
    private var pendingRegistration: CompletableDeferred<String>? = null
    @Volatile private var registeredFid: String? = null
    private var attempt = 0
    @Volatile private var isStarted = false
    @Volatile private var currentGeneration = 0L
    @Volatile private var removalInProgress = false
    @Volatile private var lastRegisteredTimeMs: Long = 0L

    companion object {
        private const val TAG = "DeliveryController"
        const val MIN_BACKOFF_MS = 2_000L
        const val MAX_BACKOFF_MS = 300_000L // 5 minutes
        const val RATE_LIMITED_ATTEMPT = 4 // ~30s
        const val FCM_REGISTRATION_TIMEOUT_MS = 30_000L
        val REFRESH_INTERVAL_MS = TimeUnit.HOURS.toMillis(12)

        @Volatile
        private var _instance: DeliveryController? = null

        val instance: DeliveryController
            get() = requireNotNull(_instance) { "DeliveryController not initialized" }

        fun getInstance(recordStore: RecordStore, apiClient: ApiClient): DeliveryController {
            return _instance ?: synchronized(this) {
                _instance ?: DeliveryController(recordStore, apiClient).also { _instance = it }
            }
        }

        fun backoff(attempt: Int, random: Random = Random()): Long {
            val base = (MIN_BACKOFF_MS * 2.0.pow(min(attempt, 16).toDouble())).toLong()
            val capped = min(base, MAX_BACKOFF_MS)
            val jitter = if (capped > 4) random.nextInt((capped / 4).toInt() + 1) else 0
            return min(capped + jitter, MAX_BACKOFF_MS)
        }
    }

    @Synchronized
    fun start(resumeDespitePendingRemoval: Boolean = false) {
        if (removalInProgress) return
        if (!DeliveryStartGate.mayStart(
                store = recordStore,
                forgetCleanupPending = RecordStore.enrollmentBlocked,
                storageUnavailable = recordStore.failureReason != null,
                resumeDespitePendingRemoval = resumeDespitePendingRemoval,
            )
        ) {
            return
        }
        cancelRetry()
        isStarted = true
        currentGeneration++
        attempt = 0
        tryStart(currentGeneration)
    }

    @Synchronized
    private fun invalidateAndTakeJobs(): Pair<Job?, Job?> {
        isStarted = false
        currentGeneration++
        cancelRetry()
        pendingRegistration?.cancel()
        pendingRegistration = null
        val jobs = activeJob to currentRefreshJob
        activeJob = null
        currentRefreshJob = null
        return jobs
    }

    @Synchronized
    private fun blockStartsForRemoval() { removalInProgress = true }

    @Synchronized
    fun endRemoval() { removalInProgress = false }

    suspend fun beginRemoval() {
        blockStartsForRemoval()
        stop()
    }

    suspend fun stop() {
        val (job, refresh) = invalidateAndTakeJobs()
        job?.cancelAndJoin()
        refresh?.cancelAndJoin()
        registrationMutex.withLock { }
        synchronized(this) {
            if (!isStarted) _status.value = DeliveryStatus(DeliveryState.IDLE)
        }
    }

    @Synchronized
    fun onResume() {
        val now = System.currentTimeMillis()
        val stale = lastRegisteredTimeMs == 0L || (now - lastRegisteredTimeMs) > REFRESH_INTERVAL_MS
        val currentState = _status.value.state

        if (stale || currentState == DeliveryState.RETRYING || currentState == DeliveryState.TOO_MANY_DEVICES) {
            start()
        }
    }

    @Synchronized
    fun onRegistered(fid: String) {
        if (!isStarted || !recordStore.isEnrolled()) return

        val pending = pendingRegistration
        if (pending != null && !pending.isCompleted) {
            pending.complete(fid)
            return
        }

        // Routine background sync or changed FID
        if (fid == registeredFid) return

        val generation = currentGeneration
        currentRefreshJob?.cancel()
        val job = scope.launch {
            registrationMutex.withLock {
                if (!isStarted || generation != currentGeneration || !recordStore.isEnrolled() || fid == registeredFid) {
                    return@withLock
                }
                try {
                    val recordId = recordStore.recordId() ?: return@withLock
                    val oldDeviceId = recordStore.deviceId()
                    val newDeviceId = withContext(NonCancellable) {
                        registerWithRecordedOutcome(recordId, fid, oldDeviceId)
                    }
                    synchronized(this@DeliveryController) {
                        if (!isStarted || generation != currentGeneration) return@withLock
                        registeredFid = fid
                        lastRegisteredTimeMs = System.currentTimeMillis()
                        attempt = 0
                        _status.value = _status.value.copy(state = DeliveryState.READY, message = null)
                    }
                    Log.i(TAG, "Updated server device registration on FID refresh. New Device ID: $newDeviceId")
                } catch (e: CancellationException) {
                    throw e
                } catch (e: RecordNotFoundException) {
                    setRegistrationFailure(generation, DeliveryState.RECORD_UNKNOWN, e.message)
                } catch (e: TooManyDevicesException) {
                    setRegistrationFailure(generation, DeliveryState.TOO_MANY_DEVICES, e.message)
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to update device registration on FID refresh: ${e.message}")
                    if (isStarted && generation == currentGeneration) {
                        scheduleRetry(e, generation)
                    }
                }
            }
        }
        currentRefreshJob = job
    }

    @Synchronized
    fun onUnregistered(fid: String) {
        if (registeredFid == fid) {
            registeredFid = null
            if (isStarted && recordStore.isEnrolled()) {
                Log.w(TAG, "Device token unregistered by FCM. Triggering re-registration.")
                _status.value = _status.value.copy(
                    state = DeliveryState.CONNECTING,
                    message = "Re-registering with push service..."
                )
                start()
            }
        }
    }

    fun reportError(error: Throwable) {
        when (error) {
            is RecordNotFoundException -> {
                _status.value = _status.value.copy(
                    state = DeliveryState.RECORD_UNKNOWN,
                    message = error.message
                )
            }
            is TooManyDevicesException -> {
                _status.value = _status.value.copy(
                    state = DeliveryState.TOO_MANY_DEVICES,
                    message = error.message
                )
            }
            else -> {
                _status.value = _status.value.copy(
                    state = DeliveryState.RETRYING,
                    message = error.message
                )
            }
        }
    }

    fun reportUndecryptable() {
        _status.value = _status.value.copy(
            undecryptable = _status.value.undecryptable + 1
        )
    }

    private fun cancelRetry() {
        retryRunnable?.let { handler.removeCallbacks(it) }
        retryRunnable = null
    }

    @Synchronized
    private fun tryStart(generation: Long) {
        if (!isStarted || generation != currentGeneration) return
        if (!recordStore.isEnrolled()) {
            _status.value = DeliveryStatus(DeliveryState.IDLE)
            return
        }

        _status.value = _status.value.copy(state = DeliveryState.CONNECTING)

        val deferred = CompletableDeferred<String>()
        pendingRegistration = deferred

        activeJob?.cancel()
        activeJob = scope.launch {
            try {
                // 1 & 2. Execute registration and await confirmed FID callback within a unified timeout
                val fid = try {
                    withTimeout(FCM_REGISTRATION_TIMEOUT_MS) {
                        fcmRegistrar.register()
                        deferred.await()
                    }
                } catch (e: TimeoutCancellationException) {
                    throw IllegalStateException("FCM registration sequence timed out after ${FCM_REGISTRATION_TIMEOUT_MS / 1000}s", e)
                }

                if (!isStarted || generation != currentGeneration) return@launch

                // 3. Register confirmed FID with server inside mutex
                registrationMutex.withLock {
                    if (!isStarted || generation != currentGeneration || !recordStore.isEnrolled()) return@launch

                    val recordId = recordStore.recordId()
                        ?: throw RecordNotFoundException()

                    val oldDeviceId = recordStore.deviceId()
                    val newDeviceId = withContext(NonCancellable) {
                        registerWithRecordedOutcome(recordId, fid, oldDeviceId)
                    }

                    synchronized(this@DeliveryController) {
                        if (!isStarted || generation != currentGeneration) return@launch
                        registeredFid = fid
                        lastRegisteredTimeMs = System.currentTimeMillis()
                        attempt = 0
                        _status.value = _status.value.copy(state = DeliveryState.READY, message = null)
                    }
                    Log.i(TAG, "Push registration successful")
                }
            } catch (e: CancellationException) {
                // Propagation of coroutine cancellation: do NOT catch or retry
                throw e
            } catch (e: RecordNotFoundException) {
                Log.w(TAG, "Record not found on server: ${e.message}")
                setRegistrationFailure(generation, DeliveryState.RECORD_UNKNOWN, e.message)
            } catch (e: TooManyDevicesException) {
                Log.w(TAG, "Too many devices: ${e.message}")
                setRegistrationFailure(generation, DeliveryState.TOO_MANY_DEVICES, e.message)
            } catch (e: Exception) {
                Log.w(TAG, "Registration attempt failed: ${e.message}")
                if (isStarted && generation == currentGeneration) {
                    scheduleRetry(e, generation)
                }
            } finally {
                synchronized(this@DeliveryController) {
                    if (pendingRegistration === deferred) pendingRegistration = null
                }
            }
        }
    }

    private suspend fun registerWithRecordedOutcome(recordId: String, fid: String, oldDeviceId: String?): String? {
        val alreadyUncertain = recordStore.beginDeviceRegistration()
        val result = try {
            apiClient.registerDevice(recordId, fid, "fcm", oldDeviceId)
        } catch (e: RateLimitedException) {
            recordStore.rejectDeviceRegistration(alreadyUncertain)
            throw e
        } catch (e: TooManyDevicesException) {
            recordStore.rejectDeviceRegistration(alreadyUncertain)
            throw e
        } catch (e: RecordNotFoundException) {
            recordStore.rejectDeviceRegistration(alreadyUncertain)
            throw e
        } catch (e: RegistrationRejectedException) {
            recordStore.rejectDeviceRegistration(alreadyUncertain)
            throw e
        } catch (e: UnknownHostException) {
            recordStore.rejectDeviceRegistration(alreadyUncertain)
            throw e
        }
        recordStore.finishDeviceRegistration(result, alreadyUncertain)
        return result
    }

    @Synchronized
    private fun setRegistrationFailure(generation: Long, state: DeliveryState, message: String?) {
        if (isStarted && generation == currentGeneration) {
            _status.value = _status.value.copy(state = state, message = message)
        }
    }

    @Synchronized
    private fun scheduleRetry(e: Exception, generation: Long) {
        if (!isStarted || generation != currentGeneration) return
        val currentAttempt = attempt++
        val effectiveAttempt = if (e is RateLimitedException) {
            max(currentAttempt, RATE_LIMITED_ATTEMPT)
        } else {
            currentAttempt
        }
        val delayMs = backoff(effectiveAttempt)
        val delaySec = delayMs / 1000

        _status.value = _status.value.copy(
            state = DeliveryState.RETRYING,
            message = "${e.message ?: "Connection error"} (retrying in ${delaySec}s)"
        )

        cancelRetry()
        val runnable = Runnable {
            if (isStarted && generation == currentGeneration && recordStore.isEnrolled()) {
                tryStart(generation)
            }
        }
        retryRunnable = runnable
        handler.postDelayed(runnable, delayMs)
    }
}
