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
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.api.ApiClient
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.storage.RemovalNoticeStore
import xyz.vidur.pux.testutil.FakeSharedPreferences
import xyz.vidur.pux.testutil.RecordStoreTestIsolation
import xyz.vidur.pux.ui.screens.RemovalAction

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], application = Application::class)
class RemovalControllerNoticeTest {
    private lateinit var server: MockWebServer
    private lateinit var store: RecordStore
    private lateinit var controller: RemovalController
    private val context = ApplicationProvider.getApplicationContext<Application>()

    @Before fun setup() {
        RecordStoreTestIsolation.reset()
        server = MockWebServer().apply {
            enqueue(MockResponse().setResponseCode(204))
            start()
        }
        store = RecordStore(FakeSharedPreferences(), server.url("/").toString().removeSuffix("/"))
        store.saveEnrollment(
            mapOf(
                "v" to 1,
                "record_id" to "12345678-1234-1234-1234-123456789abc",
                "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
                "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
                "inbox" to "test@pux.xyz",
                "device_id" to "device-known"
            )
        )
        store.beginDeviceRegistration()
        assertTrue(store.registrationUncertain())
        val api = ApiClient(store)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        controller = RemovalController(context, store, api, DeliveryController(store, api), scope)
        RemovalNoticeStore.clear(context)
    }

    @After fun teardown() {
        server.shutdown()
        RemovalNoticeStore.clear(context)
    }

    @Test fun removeDeviceWithUncertainRegistrationPersistsNotice() = runBlocking {
        controller.run(RemovalAction.REMOVE_DEVICE)
        withTimeout(5_000) {
            while (controller.state.value !is RemovalState.Completed) {
                kotlinx.coroutines.delay(10)
            }
        }
        val completed = controller.state.value as RemovalState.Completed
        assertNotNull(completed.staleRegistrationNotice)
        assertTrue(completed.staleRegistrationNotice!!.contains("without a saved device ID"))
        assertNotNull(RemovalNoticeStore.peek(context))
        assertNull(store.deviceId())
    }
}
