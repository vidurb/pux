package xyz.vidur.pux.service

import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertNotEquals
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
class RemovalControllerNoticeFailureTest {
    private lateinit var server: MockWebServer
    private lateinit var store: RecordStore
    private lateinit var removalNoticePrefs: FakeSharedPreferences
    private lateinit var testContext: Context
    private lateinit var controller: RemovalController

    @Before fun setup() {
        RecordStoreTestIsolation.reset()
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse =
                MockResponse().setResponseCode(204)
        }
        server.start()
        store = RecordStore(FakeSharedPreferences(), server.url("/").toString().removeSuffix("/"))
        store.saveEnrollment(enrollment())
        removalNoticePrefs = FakeSharedPreferences()
        val base = ApplicationProvider.getApplicationContext<Context>()
        testContext = object : ContextWrapper(base) {
            override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences = when (name) {
                "pux_removal_state" -> removalNoticePrefs
                else -> super.getSharedPreferences(name, mode)
            }
        }
        val delivery = DeliveryController(store, ApiClient(store))
        controller = RemovalController(
            testContext,
            store,
            ApiClient(store),
            delivery,
            CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        )
    }

    @After fun tearDown() {
        server.shutdown()
    }

    @Test fun noticeCommitFailureAfterDeleteDoesNotLeaveRunning() = runBlocking {
        removalNoticePrefs.failNextCommit = true
        store.beginDeviceRegistration()
        store.finishDeviceRegistration("dev", true)
        controller.run(RemovalAction.REMOVE_DEVICE)
        withTimeout(5_000) {
            while (controller.state.value == RemovalState.Running) {
                kotlinx.coroutines.delay(10)
            }
        }
        assertTrue(controller.state.value is RemovalState.Failed)
        assertNotEquals(RemovalState.Running, controller.state.value)
        removalNoticePrefs.failNextCommit = false
        RemovalNoticeStore.clear(testContext)
    }

    private fun enrollment() = mapOf(
        "v" to 1,
        "record_id" to "12345678-1234-1234-1234-123456789abc",
        "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
        "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
        "inbox" to "test@pux.xyz",
        "device_id" to "device-1"
    )
}
