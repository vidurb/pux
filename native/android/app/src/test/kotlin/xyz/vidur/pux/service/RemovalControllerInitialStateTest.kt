package xyz.vidur.pux.service

import android.app.Application
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
import xyz.vidur.pux.storage.FlutterSecureStorageMigrator
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.testutil.FakeSharedPreferences
import xyz.vidur.pux.testutil.RecordStoreTestIsolation
import xyz.vidur.pux.ui.screens.RemovalAction

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], application = Application::class)
class RemovalControllerInitialStateTest {
    private val context = ApplicationProvider.getApplicationContext<Application>()

    @Before fun resetGate() {
        RecordStoreTestIsolation.reset()
    }

    @Test fun restartWithUnreachableRelayDeleteExplainsAndAllowsClearOnCancel() {
        val store = RecordStore(FakeSharedPreferences())
        store.saveEnrollment(enrollment())
        store.beginRemoteRemoval("delete_relay")
        store.markPendingRemovalServerUnreachable()
        val controller = RemovalController(context, store, ApiClient(store), DeliveryController(store, ApiClient(store)))
        val state = controller.state.value as RemovalState.Failed
        assertEquals(RemovalAction.DELETE_RELAY, state.failure.action)
        assertTrue(state.failure.serverUnreachable)
        assertFalse(state.failure.keepRemovalIntentOnCancel)
        assertEquals("Relay deletion incomplete", state.failure.title)
    }

    @Test fun restartWithForgetPendingAfterNativeWipeSurfacesFinishState() {
        val migrationPrefs = FakeSharedPreferences()
        val forgetContext = object : ContextWrapper(context) {
            override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences = when (name) {
                FlutterSecureStorageMigrator.MIGRATION_PREFS_NAME -> migrationPrefs
                else -> super.getSharedPreferences(name, mode)
            }
        }
        val store = RecordStore(FakeSharedPreferences())
        store.saveEnrollment(enrollment())
        FlutterSecureStorageMigrator.beginForget(forgetContext)
        store.completeForget(null)
        assertFalse(store.isEnrolled())
        val controller = RemovalController(
            forgetContext,
            store,
            ApiClient(store),
            DeliveryController(store, ApiClient(store))
        )
        val state = controller.state.value as RemovalState.Failed
        assertEquals(RemovalAction.FORGET, state.failure.action)
        assertTrue(state.failure.keepRemovalIntentOnCancel)
    }

    @Test fun restartWithInFlightRelayDeleteKeepsIntentOnCancel() {
        val store = RecordStore(FakeSharedPreferences())
        store.saveEnrollment(enrollment())
        store.beginRemoteRemoval("delete_relay")
        val controller = RemovalController(context, store, ApiClient(store), DeliveryController(store, ApiClient(store)))
        val state = controller.state.value as RemovalState.Failed
        assertFalse(state.failure.serverUnreachable)
        assertTrue(state.failure.keepRemovalIntentOnCancel)
    }

    private fun enrollment() = mapOf(
        "v" to 1,
        "record_id" to "12345678-1234-1234-1234-123456789abc",
        "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
        "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
        "inbox" to "test@pux.xyz",
        "device_id" to "device"
    )
}
