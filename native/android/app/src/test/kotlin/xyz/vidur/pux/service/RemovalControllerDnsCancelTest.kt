package xyz.vidur.pux.service

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import xyz.vidur.pux.ui.screens.RemovalFailure
import java.net.UnknownHostException
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.api.ApiClient
import xyz.vidur.pux.model.DeliveryState
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.testutil.FakeSharedPreferences
import xyz.vidur.pux.testutil.RecordStoreTestIsolation
import xyz.vidur.pux.ui.screens.RemovalAction

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], application = Application::class)
class RemovalControllerDnsCancelTest {
    private lateinit var server: MockWebServer
    private lateinit var store: RecordStore
    private lateinit var delivery: DeliveryController
    private lateinit var controller: RemovalController

    @Before fun setup() {
        RecordStoreTestIsolation.reset()
        server = MockWebServer()
        server.enqueue(MockResponse().setResponseCode(503))
        server.start()
        store = RecordStore(FakeSharedPreferences(), server.url("/").toString().removeSuffix("/"))
        store.saveEnrollment(
            mapOf(
                "v" to 1,
                "record_id" to "12345678-1234-1234-1234-123456789abc",
                "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
                "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
                "inbox" to "test@pux.xyz"
            )
        )
        delivery = DeliveryController(store, ApiClient(store))
        controller = RemovalController(
            ApplicationProvider.getApplicationContext(),
            store,
            ApiClient(store),
            delivery,
            CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        )
    }

    @After fun tearDown() {
        server.shutdown()
    }

    @Test fun cancelAfterRelayDeleteServerErrorKeepsPendingWhenCancelRetainsIntent() = runBlocking {
        controller.run(RemovalAction.DELETE_RELAY)
        withTimeout(5_000) {
            while (controller.state.value !is RemovalState.Failed) {
                kotlinx.coroutines.delay(10)
            }
        }
        val failure = (controller.state.value as RemovalState.Failed).failure
        assertEquals(false, failure.serverUnreachable)
        assertEquals(true, failure.keepRemovalIntentOnCancel)
        assertEquals("delete_relay", store.pendingRemoteRemoval())
        controller.cancelFailure(clearPendingRemoval = false)
        assertEquals("delete_relay", store.pendingRemoteRemoval())
        assertEquals(RemovalState.Idle, controller.state.value)
        assertNotEquals(DeliveryState.IDLE, delivery.status.value.state)
    }

    @Test fun cancelAfterRelayDeleteUnknownHostClearsPendingOnCancel() = runBlocking {
        store.beginRemoteRemoval("delete_relay")
        store.markPendingRemovalServerUnreachable()
        val failure = RemovalFailure(
            RemovalAction.DELETE_RELAY,
            "Couldn't delete the relay",
            UnknownHostException("no.dns.example").message ?: "DNS",
            "If you forget locally, the relay keeps running on the server and your other devices keep receiving codes.",
            serverUnreachable = true,
            keepRemovalIntentOnCancel = false
        )
        val field = RemovalController::class.java.getDeclaredField("_state")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val flow = field.get(controller) as kotlinx.coroutines.flow.MutableStateFlow<RemovalState>
        flow.value = RemovalState.Failed(failure)
        assertEquals(true, failure.serverUnreachable)
        assertEquals(false, failure.keepRemovalIntentOnCancel)
        controller.cancelFailure(clearPendingRemoval = true)
        assertNull(store.pendingRemoteRemoval())
        assertEquals(RemovalState.Idle, controller.state.value)
    }
}
