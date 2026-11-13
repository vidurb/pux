package xyz.vidur.pux.service

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.api.ApiClient
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.testutil.FakeSharedPreferences
import xyz.vidur.pux.ui.screens.RemovalAction
import xyz.vidur.pux.ui.screens.RemovalFailure

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], application = Application::class)
class RemovalControllerCancelTest {
    private val context = ApplicationProvider.getApplicationContext<Application>()

    @Test fun cancelForgetFailureKeepsPendingRemoteRemoval() = runBlocking {
        val store = RecordStore(FakeSharedPreferences())
        store.saveEnrollment(enrollment())
        store.beginRemoteRemoval("delete_relay")
        val delivery = DeliveryController(store, ApiClient(store))
        val controller = RemovalController(context, store, ApiClient(store), delivery)
        delivery.beginRemoval()
        setFailed(
            controller,
            RemovalFailure(
                RemovalAction.FORGET,
                "Could not forget",
                "Storage error",
                "warn",
                serverUnreachable = false,
                keepRemovalIntentOnCancel = true
            )
        )
        controller.cancelFailure(clearPendingRemoval = false)
        assertEquals("delete_relay", store.pendingRemoteRemoval())
        assertEquals(RemovalState.Idle, controller.state.value)
    }

    @Test fun cancelDeleteRelayFailureKeepsPendingIntent() = runBlocking {
        val store = RecordStore(FakeSharedPreferences())
        store.saveEnrollment(enrollment())
        store.beginRemoteRemoval("delete_relay")
        val delivery = DeliveryController(store, ApiClient(store))
        val controller = RemovalController(context, store, ApiClient(store), delivery)
        delivery.beginRemoval()
        setFailed(
            controller,
            RemovalFailure(
                RemovalAction.DELETE_RELAY,
                "Couldn't delete the relay",
                "503",
                "forget warning",
                serverUnreachable = false,
                keepRemovalIntentOnCancel = true
            )
        )
        controller.cancelFailure(clearPendingRemoval = false)
        assertEquals("delete_relay", store.pendingRemoteRemoval())
        assertEquals(RemovalState.Idle, controller.state.value)
    }

    @Test fun cancelDeleteRelayUnreachableClearsPendingIntent() = runBlocking {
        val store = RecordStore(FakeSharedPreferences())
        store.saveEnrollment(enrollment())
        store.beginRemoteRemoval("delete_relay")
        store.markPendingRemovalServerUnreachable()
        val delivery = DeliveryController(store, ApiClient(store))
        val controller = RemovalController(context, store, ApiClient(store), delivery)
        delivery.beginRemoval()
        setFailed(
            controller,
            RemovalFailure(
                RemovalAction.DELETE_RELAY,
                "Couldn't delete the relay",
                "UnknownHost",
                "forget warning",
                serverUnreachable = true,
                keepRemovalIntentOnCancel = false
            )
        )
        controller.cancelFailure(clearPendingRemoval = true)
        assertNull(store.pendingRemoteRemoval())
        assertEquals(RemovalState.Idle, controller.state.value)
    }

    @Test fun cancelRemoveDeviceFailureClearsPendingIntent() = runBlocking {
        val store = RecordStore(FakeSharedPreferences())
        store.saveEnrollment(enrollment())
        store.beginRemoteRemoval("remove_device")
        val delivery = DeliveryController(store, ApiClient(store))
        val controller = RemovalController(context, store, ApiClient(store), delivery)
        delivery.beginRemoval()
        setFailed(
            controller,
            RemovalFailure(
                RemovalAction.REMOVE_DEVICE,
                "Couldn't remove",
                "503",
                "forget warning",
                serverUnreachable = false,
                keepRemovalIntentOnCancel = false
            )
        )
        controller.cancelFailure(clearPendingRemoval = true)
        assertNull(store.pendingRemoteRemoval())
        assertEquals(RemovalState.Idle, controller.state.value)
    }

    private fun setFailed(controller: RemovalController, failure: RemovalFailure) {
        val field = RemovalController::class.java.getDeclaredField("_state")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val flow = field.get(controller) as kotlinx.coroutines.flow.MutableStateFlow<RemovalState>
        flow.value = RemovalState.Failed(failure)
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
