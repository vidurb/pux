package xyz.vidur.pux

import android.app.Application
import android.util.Log
import xyz.vidur.pux.api.ApiClient
import xyz.vidur.pux.push.NotificationHelper
import xyz.vidur.pux.push.SensitiveClipboard
import xyz.vidur.pux.service.CreateRelayController
import xyz.vidur.pux.service.DeliveryController
import xyz.vidur.pux.service.DeliveryStartGate
import xyz.vidur.pux.service.RemovalController
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import xyz.vidur.pux.storage.FlutterSecureStorageMigrator
import xyz.vidur.pux.storage.MigrationRecovery
import xyz.vidur.pux.storage.RecordStore

class PuxApplication : Application() {

    lateinit var recordStore: RecordStore
        private set

    lateinit var apiClient: ApiClient
        private set

    lateinit var deliveryController: DeliveryController
        private set

    internal lateinit var removalController: RemovalController
        private set

    lateinit var createRelayController: CreateRelayController
        private set

    lateinit var sensitiveClipboard: SensitiveClipboard
        private set

    lateinit var notificationHelper: NotificationHelper
        private set

    var keystoreError: Exception? = null
        private set

    var migrationResult: FlutterSecureStorageMigrator.MigrationResult? = null
        private set

    private val _migrationResultState = MutableStateFlow<FlutterSecureStorageMigrator.MigrationResult?>(null)
    val migrationResultState: StateFlow<FlutterSecureStorageMigrator.MigrationResult?> = _migrationResultState.asStateFlow()

    private fun publishMigrationResult(result: FlutterSecureStorageMigrator.MigrationResult?) {
        migrationResult = result
        _migrationResultState.value = result
    }

    fun discardFailedMigration() {
        FlutterSecureStorageMigrator.clearLegacyData(this)
        publishMigrationResult(FlutterSecureStorageMigrator.MigrationResult.NotNeeded)
    }

    fun retryFlutterMigration(): Boolean {
        if (keystoreError != null) return false
        val migrator = FlutterSecureStorageMigrator(this, recordStore)
        val result = migrator.migrate()
        publishMigrationResult(result)
        val recovered = MigrationRecovery.succeeded(this, result)
        if (recovered && canStartDelivery()) {
            deliveryController.start()
        }
        return recovered
    }

    fun canStartDelivery(resumeDespitePendingRemoval: Boolean = false): Boolean =
        DeliveryStartGate.mayStart(
            store = recordStore,
            forgetCleanupPending = forgetBlocksSetup(),
            storageUnavailable = keystoreError != null,
            resumeDespitePendingRemoval = resumeDespitePendingRemoval,
        )

    fun migrationBlocksSetup(): Boolean =
        migrationResult is FlutterSecureStorageMigrator.MigrationResult.Failed ||
            FlutterSecureStorageMigrator.isLegacyCleanupPending(this)

    fun forgetBlocksSetup(): Boolean =
        keystoreError == null && FlutterSecureStorageMigrator.isForgetPending(this)

    fun refreshEnrollmentGate() {
        RecordStore.enrollmentBlocked = forgetBlocksSetup()
    }

    override fun onCreate() {
        super.onCreate()

        // 1. Initialize Keystore-backed secure storage (fails closed on Keystore errors)
        recordStore = try {
            RecordStore.createEncrypted(this, BuildConfig.DEFAULT_SERVER_URL)
        } catch (e: Exception) {
            Log.e(TAG, "Fatal: Keystore-backed secure storage failed to initialize", e)
            keystoreError = e
            RecordStore.createFailing(e)
        }
        if (keystoreError == null && FlutterSecureStorageMigrator.isForgetPending(this)) {
            try {
                recordStore.completeForget(this)
            } catch (e: Exception) {
                Log.e(TAG, "Could not finish interrupted forget", e)
            }
        }
        refreshEnrollmentGate()
        RecordStore.instance = recordStore

        // 2. Initialize API client and delivery controller
        apiClient = ApiClient(recordStore)
        ApiClient.instance = apiClient
        deliveryController = DeliveryController.getInstance(recordStore, apiClient)
        removalController = RemovalController(this, recordStore, apiClient, deliveryController)
        createRelayController = CreateRelayController(recordStore, apiClient, deliveryController)

        // 3. Initialize notification channel and sensitive clipboard
        notificationHelper = NotificationHelper.getInstance(this)
        sensitiveClipboard = SensitiveClipboard.getInstance(this)

        // 4. Run FlutterSecureStorage migration investigation
        try {
            val migrator = FlutterSecureStorageMigrator(this, recordStore)
            val result = migrator.migrate()
            publishMigrationResult(result)
            if (result is FlutterSecureStorageMigrator.MigrationResult.Success) {
                Log.i(TAG, "Migrated Flutter enrollment successfully.")
            } else if (result is FlutterSecureStorageMigrator.MigrationResult.Failed) {
                Log.w(TAG, "Flutter enrollment migration could not complete: ${result.reason}")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error checking Flutter storage migration: ${e.message}", e)
        }

        // 5. Start delivery only when forget cleanup and storage are healthy
        if (canStartDelivery()) {
            deliveryController.start()
        }
    }

    companion object {
        private const val TAG = "PuxApp"
    }
}
