package xyz.vidur.pux.service

import android.app.Application
import android.os.Bundle
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import xyz.vidur.pux.api.ApiClient
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.testutil.FakeSharedPreferences
import xyz.vidur.pux.testutil.RecordStoreTestIsolation
import xyz.vidur.pux.ui.screens.RemovalAction
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** A replacement Activity subscribes independently, as PuxApp does. */
class RemovalObserverActivity : ComponentActivity() {
    companion object { internal lateinit var source: StateFlow<RemovalState> }
    internal var observed: RemovalState? = null
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        lifecycleScope.launch { source.collect { observed = it } }
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], application = Application::class)
class RemovalControllerRecreationTest {
    private lateinit var server: MockWebServer
    private lateinit var store: RecordStore
    private lateinit var owner: RemovalController
    private lateinit var release: CountDownLatch
    private lateinit var responseReceived: CountDownLatch

    @Before fun setup() {
        RecordStoreTestIsolation.reset()
        server = MockWebServer().apply { start() }
        store = RecordStore(FakeSharedPreferences(), server.url("").toString().removeSuffix("/"))
        store.saveEnrollment(mapOf("v" to 1, "record_id" to "12345678-1234-1234-1234-123456789abc",
            "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
            "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI", "inbox" to "test@pux.xyz"))
        store.saveDeviceId("device")
        val api = ApiClient(store)
        val context = ApplicationProvider.getApplicationContext<Application>()
        context.getSharedPreferences("pux_migration_state", 0).edit().clear().commit()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        owner = RemovalController(context, store, api, DeliveryController(store, api), scope)
        RemovalObserverActivity.source = owner.state
        release = CountDownLatch(1)
        responseReceived = CountDownLatch(1)
    }

    @After fun teardown() { release.countDown(); server.shutdown() }

    @Test fun replacementActivitySeesCompletionAfterDelayedDelete() = runBlocking {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                responseReceived.countDown()
                check(release.await(30, TimeUnit.SECONDS))
                return MockResponse().setResponseCode(204)
            }
        }
        val activity = Robolectric.buildActivity(RemovalObserverActivity::class.java).setup()
        shadowOf(Looper.getMainLooper()).idle()
        owner.run(RemovalAction.REMOVE_DEVICE)
        assertTrue(responseReceived.await(5, TimeUnit.SECONDS))
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(RemovalState.Running, activity.get().observed)
        activity.recreate()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(RemovalState.Running, activity.get().observed)
        release.countDown()
        kotlinx.coroutines.withTimeout(5000) {
            while (owner.state.value !is RemovalState.Completed) kotlinx.coroutines.delay(10)
        }
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(activity.get().observed is RemovalState.Completed)
        assertFalse(store.isEnrolled())
        assertNull(store.pendingRemoteRemoval())
        assertEquals(1, server.requestCount)
        activity.close()
    }
    @Test fun replacementActivitySeesFailureAfterDelayedDelete() = runBlocking {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                responseReceived.countDown()
                check(release.await(30, TimeUnit.SECONDS))
                return MockResponse().setResponseCode(503)
            }
        }
        val activity = Robolectric.buildActivity(RemovalObserverActivity::class.java).setup()
        shadowOf(Looper.getMainLooper()).idle()
        owner.run(RemovalAction.REMOVE_DEVICE)
        assertTrue(responseReceived.await(5, TimeUnit.SECONDS))
        shadowOf(Looper.getMainLooper()).idle()
        activity.recreate()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(RemovalState.Running, activity.get().observed)
        release.countDown()
        shadowOf(Looper.getMainLooper()).idle()
        kotlinx.coroutines.withTimeout(15_000) {
            while (owner.state.value !is RemovalState.Failed) {
                shadowOf(Looper.getMainLooper()).idle()
                kotlinx.coroutines.yield()
                kotlinx.coroutines.delay(50)
            }
        }
        shadowOf(Looper.getMainLooper()).idle()
        val failure = owner.state.value as RemovalState.Failed
        assertEquals(RemovalAction.REMOVE_DEVICE, failure.failure.action)
        kotlinx.coroutines.withTimeout(2_000) {
            while (activity.get().observed !is RemovalState.Failed) {
                shadowOf(Looper.getMainLooper()).idle()
                kotlinx.coroutines.delay(10)
            }
        }
        assertEquals(RemovalAction.REMOVE_DEVICE, (activity.get().observed as RemovalState.Failed).failure.action)
        assertTrue(store.isEnrolled())
        assertEquals("remove_device", store.pendingRemoteRemoval())
        owner.cancelFailure()
        assertTrue(owner.state.value is RemovalState.Idle)
        assertNull(store.pendingRemoteRemoval())
        activity.close()
    }

}
