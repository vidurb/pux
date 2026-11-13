package xyz.vidur.pux.service

import android.app.Application
import android.os.Bundle
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class CreateRelayObserverActivity : ComponentActivity() {
    companion object { internal lateinit var source: StateFlow<CreateRelayState> }
    internal var observed: CreateRelayState? = null
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        lifecycleScope.launch { source.collect { observed = it } }
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], application = Application::class)
class CreateRelayControllerRecreationTest {
    private lateinit var server: MockWebServer
    private lateinit var store: RecordStore
    private lateinit var owner: CreateRelayController
    private lateinit var release: CountDownLatch

    @Before
    fun setup() {
        server = MockWebServer().apply { start() }
        store = RecordStore(FakeSharedPreferences(), server.url("").toString().removeSuffix("/"))
        val api = ApiClient(store)
        val delivery = DeliveryController(store, api)
        owner = CreateRelayController(
            store,
            api,
            delivery,
            CoroutineScope(SupervisorJob() + Dispatchers.IO)
        )
        CreateRelayObserverActivity.source = owner.state
        release = CountDownLatch(1)
    }

    @After fun tearDown() {
        release.countDown()
        server.shutdown()
    }

    @Test
    fun replacementActivitySeesCompletedCreateRelay() {
        runBlocking {
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setBody("""{"record_id":"12345678-1234-1234-1234-123456789abc","inbox_address":"new@pux.xyz"}""")
                .setBodyDelay(50, TimeUnit.MILLISECONDS)
        )
        val activity = Robolectric.buildActivity(CreateRelayObserverActivity::class.java).setup()
        shadowOf(Looper.getMainLooper()).idle()
        owner.start()
        assertEquals(CreateRelayState.Running, activity.get().observed)
        activity.recreate()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(CreateRelayState.Running, activity.get().observed)
        kotlinx.coroutines.withTimeout(5000) {
            while (owner.state.value != CreateRelayState.Completed) {
                kotlinx.coroutines.delay(10)
            }
        }
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(store.isEnrolled())
        assertEquals(CreateRelayState.Completed, activity.get().observed)
        activity.destroy()
        }
    }
}
