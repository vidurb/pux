package xyz.vidur.pux.service

import android.content.Context
import xyz.vidur.pux.PuxApplication
import xyz.vidur.pux.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import xyz.vidur.pux.api.ApiClient
import xyz.vidur.pux.api.remoteRemovalRequestLikelyUnsent
import xyz.vidur.pux.storage.FlutterSecureStorageMigrator
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.storage.RemovalNoticeStore
import xyz.vidur.pux.ui.screens.RemovalAction
import xyz.vidur.pux.ui.screens.RemovalFailure

internal sealed interface RemovalState {
    data object Idle : RemovalState
    data object Running : RemovalState
    data class Failed(val failure: RemovalFailure) : RemovalState
    data class Completed(val staleRegistrationNotice: String? = null) : RemovalState
}

/** Application-owned: neither operations nor their results belong to an Activity. */
internal class RemovalController(
    private val context: Context,
    private val store: RecordStore,
    private val api: ApiClient,
    private val delivery: DeliveryController,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
) {
    private val _state = MutableStateFlow<RemovalState>(initialState(store, context))
    val state = _state.asStateFlow()

    @Synchronized
    fun run(action: RemovalAction) {
        if (_state.value == RemovalState.Running || _state.value is RemovalState.Completed) return
        _state.value = RemovalState.Running
        scope.launch {
            var remoteRemovalCompleted = false
            try {
                delivery.beginRemoval()
                val staleNotice = when (action) {
                    RemovalAction.FORGET -> null
                    RemovalAction.REMOVE_DEVICE -> {
                        val record = store.recordId()
                        val device = store.deviceId()
                        if (!record.isNullOrEmpty() && !device.isNullOrEmpty()) {
                            RemoteRemoval(store, api).removeDevice(record, device)
                        }
                        remoteRemovalCompleted = true
                        staleRegistrationNoticeAfterRemoval()
                    }
                    RemovalAction.DELETE_RELAY -> {
                        val record = requireNotNull(store.recordId()) { "Relay ID unavailable" }
                        RemoteRemoval(store, api).deleteRelay(record)
                        remoteRemovalCompleted = true
                        null
                    }
                }
                staleNotice?.let { notice ->
                    RemovalNoticeStore.save(context, notice)
                    if (store.staleRegistrationPossible()) {
                        store.clearStaleRegistrationPossible()
                    }
                }
                try {
                    clearEnrollmentLocally()
                } catch (e: Exception) {
                    delivery.endRemoval()
                    (context.applicationContext as? PuxApplication)?.refreshEnrollmentGate()
                    val forgetPending = FlutterSecureStorageMigrator.isForgetPending(context)
                    _state.value = RemovalState.Failed(
                        failure(
                            RemovalAction.FORGET,
                            e,
                            serverUnreachable = false,
                            keepRemovalIntentOnCancel =
                                store.pendingRemoteRemoval() != null || forgetPending
                        )
                    )
                    return@launch
                }
                delivery.endRemoval()
                (context.applicationContext as? PuxApplication)?.refreshEnrollmentGate()
                _state.value = RemovalState.Completed(staleNotice)
            } catch (e: Exception) {
                delivery.endRemoval()
                presentNetworkFailure(action, e, remoteRemovalCompleted)
            } finally {
                try {
                    if (_state.value == RemovalState.Running) {
                        delivery.endRemoval()
                        _state.value = RemovalState.Failed(
                            failure(
                                RemovalAction.FORGET,
                                IllegalStateException("Removal stopped unexpectedly"),
                                serverUnreachable = false,
                                keepRemovalIntentOnCancel =
                                    FlutterSecureStorageMigrator.isForgetPending(context)
                            )
                        )
                    }
                } catch (e: Exception) {
                    _state.value = RemovalState.Failed(
                        failure(action, e, serverUnreachable = false)
                    )
                }
            }
        }
    }

    private fun presentNetworkFailure(action: RemovalAction, error: Exception, remoteRemovalCompleted: Boolean) {
        var serverUnreachable = remoteRemovalRequestLikelyUnsent(error, remoteRemovalCompleted)
        val errorForUi = try {
            if (serverUnreachable) {
                store.markPendingRemovalServerUnreachable()
            }
            error
        } catch (storageError: Exception) {
            serverUnreachable = false
            storageError
        }
        _state.value = RemovalState.Failed(
            failure(action, errorForUi, serverUnreachable = serverUnreachable)
        )
    }

    private fun clearEnrollmentLocally() {
        if (FlutterSecureStorageMigrator.isForgetPending(context) && !store.isEnrolled()) {
            store.completeForget(context)
        } else {
            store.clear(context)
        }
    }

    internal fun staleRegistrationNoticeAfterRemoval(): String? {
        val uncertain = store.registrationUncertain()
        val stale = store.staleRegistrationPossible()
        if (!uncertain && !stale) return null
        return buildString {
            if (uncertain) {
                append(
                    "A push registration may have reached the server without a saved device ID on this phone. "
                )
            }
            if (stale) {
                append("An earlier registration may still exist on the server until it goes unused. ")
            }
            append("If codes continue arriving here after removal, delete the relay or reinstall the app.")
        }
    }

    @Synchronized
    fun cancelFailure(clearPendingRemoval: Boolean = true) {
        if (_state.value !is RemovalState.Failed) return
        if (FlutterSecureStorageMigrator.isForgetPending(context)) return
        val failedAction = (_state.value as RemovalState.Failed).failure.action
        if (clearPendingRemoval && failedAction != RemovalAction.FORGET) {
            try {
                store.clearPendingRemoteRemoval()
            } catch (e: Exception) {
                _state.value = RemovalState.Failed(
                    failure(failedAction, e, serverUnreachable = false)
                )
                return
            }
        }
        delivery.endRemoval()
        _state.value = RemovalState.Idle
        delivery.start(resumeDespitePendingRemoval = !clearPendingRemoval)
    }

    @Synchronized
    fun acknowledgeCompletion() {
        if (_state.value is RemovalState.Completed) _state.value = RemovalState.Idle
    }

    private fun failure(
        action: RemovalAction,
        error: Exception,
        serverUnreachable: Boolean,
        keepRemovalIntentOnCancel: Boolean = false
    ): RemovalFailure {
        val res = context.resources
        return when (action) {
            RemovalAction.FORGET -> RemovalFailure(
                action,
                res.getString(R.string.removal_forget_failure_title),
                error.message ?: res.getString(R.string.removal_error_storage),
                res.getString(R.string.removal_forget_failure_warn),
                serverUnreachable = false,
                keepRemovalIntentOnCancel = keepRemovalIntentOnCancel
            )
            RemovalAction.REMOVE_DEVICE -> RemovalFailure(
                action,
                res.getString(R.string.removal_remove_device_failure_title),
                error.message ?: res.getString(R.string.removal_error_network),
                res.getString(R.string.removal_warn_forget_device_registration),
                serverUnreachable = serverUnreachable,
                keepRemovalIntentOnCancel = false
            )
            RemovalAction.DELETE_RELAY -> RemovalFailure(
                action,
                res.getString(R.string.removal_delete_relay_failure_title),
                error.message ?: res.getString(R.string.removal_error_network),
                res.getString(R.string.removal_warn_forget_relay_keeps_server),
                serverUnreachable = serverUnreachable,
                keepRemovalIntentOnCancel = !serverUnreachable
            )
        }
    }

    companion object {
        private fun initialState(store: RecordStore, context: Context): RemovalState {
            val res = context.resources
            if (FlutterSecureStorageMigrator.isForgetPending(context)) {
                val (title, detail, warn) = if (store.isEnrolled()) {
                    Triple(
                        res.getString(R.string.removal_forget_title_enrolled),
                        res.getString(R.string.removal_forget_detail_enrolled),
                        res.getString(R.string.removal_forget_warn_enrolled),
                    )
                } else {
                    Triple(
                        res.getString(R.string.removal_forget_title_legacy),
                        res.getString(R.string.removal_forget_detail_legacy),
                        res.getString(R.string.removal_forget_warn_legacy),
                    )
                }
                return RemovalState.Failed(
                    RemovalFailure(
                        RemovalAction.FORGET,
                        title,
                        detail,
                        warn,
                        serverUnreachable = false,
                        keepRemovalIntentOnCancel = true
                    )
                )
            }
            val pending = store.pendingRemoteRemoval() ?: return RemovalState.Idle
            val action = when (pending) {
                "remove_device" -> RemovalAction.REMOVE_DEVICE
                "delete_relay" -> RemovalAction.DELETE_RELAY
                else -> return RemovalState.Failed(
                    RemovalFailure(
                        RemovalAction.FORGET,
                        res.getString(R.string.removal_state_error_title),
                        res.getString(R.string.removal_state_error_detail),
                        res.getString(R.string.removal_state_error_warn),
                        serverUnreachable = false
                    )
                )
            }
            val unreachable = store.pendingRemovalServerUnreachable()
            val (title, detail) = if (unreachable && action == RemovalAction.DELETE_RELAY) {
                res.getString(R.string.removal_relay_unreachable_title) to
                    res.getString(R.string.removal_relay_unreachable_detail)
            } else {
                res.getString(R.string.removal_interrupted_title) to
                    res.getString(R.string.removal_interrupted_detail)
            }
            val warning = if (action == RemovalAction.DELETE_RELAY) {
                res.getString(R.string.removal_warn_forget_relay_keeps_server)
            } else {
                res.getString(R.string.removal_warn_forget_device_registration)
            }
            return RemovalState.Failed(
                RemovalFailure(
                    action,
                    title,
                    detail,
                    warning,
                    serverUnreachable = unreachable,
                    keepRemovalIntentOnCancel = action == RemovalAction.DELETE_RELAY && !unreachable
                )
            )
        }
    }
}
