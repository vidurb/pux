package xyz.vidur.pux.service

import android.app.Application
import org.junit.Assert.assertNotEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.api.ApiClient
import xyz.vidur.pux.model.DeliveryState
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.testutil.FakeSharedPreferences

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], application = Application::class)
class DeliveryControllerPendingRemovalTest {
    @Test fun startDespitePendingRemoteRemovalResumesDelivery() {
        val store = RecordStore(FakeSharedPreferences())
        store.saveEnrollment(
            mapOf(
                "v" to 1,
                "record_id" to "12345678-1234-1234-1234-123456789abc",
                "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
                "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
                "inbox" to "test@pux.xyz"
            )
        )
        store.beginRemoteRemoval("delete_relay")
        val controller = DeliveryController(store, ApiClient(store))
        controller.start()
        assertNotEquals(DeliveryState.READY, controller.status.value.state)
        controller.start(resumeDespitePendingRemoval = true)
        assertNotEquals(DeliveryState.IDLE, controller.status.value.state)
    }
}
