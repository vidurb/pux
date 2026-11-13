package xyz.vidur.pux.service

import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.api.ApiClient
import xyz.vidur.pux.model.DeliveryState
import xyz.vidur.pux.storage.FlutterSecureStorageMigrator
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.testutil.FakeSharedPreferences
import xyz.vidur.pux.testutil.RecordStoreTestIsolation

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], application = Application::class)
class InterruptedForgetDeliveryGateTest {
    private lateinit var prefs: FakeSharedPreferences
    private lateinit var migrationPrefs: FakeSharedPreferences
    private lateinit var store: RecordStore
    private lateinit var delivery: DeliveryController
    private lateinit var forgetContext: Context

    @Before fun setUp() {
        RecordStoreTestIsolation.reset()
        prefs = FakeSharedPreferences()
        migrationPrefs = FakeSharedPreferences()
        store = RecordStore(prefs)
        store.saveEnrollment(enrollment())
        delivery = DeliveryController(store, ApiClient(store))
        val base = ApplicationProvider.getApplicationContext<Context>()
        forgetContext = object : ContextWrapper(base) {
            override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences = when (name) {
                FlutterSecureStorageMigrator.MIGRATION_PREFS_NAME -> migrationPrefs
                else -> super.getSharedPreferences(name, mode)
            }
        }
    }

    @Test fun standaloneForgetWithRepeatedNativeWipeFailureBlocksDeliveryAcrossRestart() {
        FlutterSecureStorageMigrator.beginForget(forgetContext)
        assertTrue(RecordStore.enrollmentBlocked)

        prefs.failNextCommit = true
        try {
            store.completeForget(forgetContext)
        } catch (_: IllegalStateException) {
        }
        assertTrue(FlutterSecureStorageMigrator.isForgetPending(forgetContext))
        assertTrue(store.isEnrolled())

        assertFalse(
            DeliveryStartGate.mayStart(
                store = store,
                forgetCleanupPending = FlutterSecureStorageMigrator.isForgetPending(forgetContext),
                storageUnavailable = false,
            )
        )
        delivery.start()
        assertEquals(DeliveryState.IDLE, delivery.status.value.state)

        prefs.failNextCommit = true
        try {
            store.completeForget(forgetContext)
        } catch (_: IllegalStateException) {
        }
        delivery.onResume()
        assertEquals(DeliveryState.IDLE, delivery.status.value.state)

        prefs.failNextCommit = false
        store.completeForget(forgetContext)
        assertFalse(FlutterSecureStorageMigrator.isForgetPending(forgetContext))
        assertFalse(store.isEnrolled())
        delivery.start()
        assertEquals(DeliveryState.IDLE, delivery.status.value.state)
    }

  private fun enrollment() = mapOf(
    "v" to 1,
    "record_id" to "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
    "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
    "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
    "inbox" to "test@pux.xyz",
  )
}
