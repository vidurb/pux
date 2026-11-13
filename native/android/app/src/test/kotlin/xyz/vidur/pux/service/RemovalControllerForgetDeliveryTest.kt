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
import org.junit.Assert.assertEquals
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
import xyz.vidur.pux.ui.screens.RemovalAction

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], application = Application::class)
class RemovalControllerForgetDeliveryTest {
    private lateinit var server: MockWebServer
    private lateinit var store: RecordStore
    private lateinit var prefs: FakeSharedPreferences
    private lateinit var migrationPrefs: FakeSharedPreferences
    private lateinit var testContext: Context
    private lateinit var delivery: DeliveryController
    private lateinit var controller: RemovalController

    @Before fun setup() {
        RecordStoreTestIsolation.reset()
        prefs = FakeSharedPreferences()
        migrationPrefs = FakeSharedPreferences()
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.method == "DELETE") {
                    prefs.failNextCommit = true
                }
                return MockResponse().setResponseCode(204)
            }
        }
        server.start()
        store = RecordStore(prefs, server.url("/").toString().removeSuffix("/"))
        store.saveEnrollment(enrollment())
        val base = ApplicationProvider.getApplicationContext<Context>()
        testContext = object : ContextWrapper(base) {
            override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences = when (name) {
                FlutterSecureStorageMigrator.MIGRATION_PREFS_NAME -> migrationPrefs
                else -> super.getSharedPreferences(name, mode)
            }
        }
        delivery = DeliveryController(store, ApiClient(store))
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

    @Test fun cancelLocalForgetFailureDoesNotResumeDelivery() = runBlocking {
        controller.run(RemovalAction.DELETE_RELAY)
        withTimeout(5_000) {
            while (controller.state.value !is RemovalState.Failed) {
                kotlinx.coroutines.delay(10)
            }
        }
        assertTrue(FlutterSecureStorageMigrator.isForgetPending(testContext))
        val before = controller.state.value
        controller.cancelFailure(clearPendingRemoval = false)
        assertEquals(before, controller.state.value)
        assertEquals(DeliveryState.IDLE, delivery.status.value.state)
        delivery.start()
        assertEquals(DeliveryState.IDLE, delivery.status.value.state)
    }

    @Test fun interruptedForgetSurfacesOnColdStart() {
        store.saveEnrollment(enrollment())
        FlutterSecureStorageMigrator.beginForget(testContext)
        val restarted = RemovalController(testContext, store, ApiClient(store), delivery)
        val failed = restarted.state.value as RemovalState.Failed
        assertEquals(RemovalAction.FORGET, failed.failure.action)
        assertTrue(failed.failure.keepRemovalIntentOnCancel)
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
