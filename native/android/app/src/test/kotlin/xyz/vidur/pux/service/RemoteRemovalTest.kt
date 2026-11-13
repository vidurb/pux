package xyz.vidur.pux.service

import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.api.ApiClient
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.testutil.FakeSharedPreferences
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class RemoteRemovalTest {
    private lateinit var server: MockWebServer
    private lateinit var prefs: FakeSharedPreferences
    private lateinit var store: RecordStore
    @Before fun setup() {
        server = MockWebServer().apply { start() }
        prefs = FakeSharedPreferences()
        store = RecordStore(prefs, server.url("").toString().removeSuffix("/"))
        store.saveEnrollment(mapOf("v" to 1, "record_id" to "12345678-1234-1234-1234-123456789abc",
            "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
            "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI", "inbox" to "test@pux.xyz"))
        store.saveDeviceId("device")
    }
    @After fun teardown() { server.shutdown() }

    @Test fun failedIntentWriteNeverSendsDelete() = runBlocking {
        prefs.failNextCommit = true
        try { RemoteRemoval(store, ApiClient(store)).removeDevice(store.recordId()!!, "device"); fail() }
        catch (_: IllegalStateException) { }
        assertNull(server.takeRequest(100, TimeUnit.MILLISECONDS))
        assertTrue(store.isEnrolled())
    }

    @Test fun restartAfterSuccessfulDeviceDeleteBlocksRegistrationAndCanRetry() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(204))
        RemoteRemoval(store, ApiClient(store)).removeDevice(store.recordId()!!, "device")
        assertEquals("DELETE", server.takeRequest().method)
        // Simulate death after the remote response but before local cleanup.
        val restarted = RecordStore(prefs, store.serverUrl)
        assertEquals("remove_device", restarted.pendingRemoteRemoval())
        var calls = 0
        val controller = DeliveryController(restarted, ApiClient(restarted), fcmRegistrar = object : FcmRegistrar {
            override suspend fun register() { calls++ }
        })
        controller.start()
        controller.onResume()
        assertEquals(0, calls)
        server.enqueue(MockResponse().setResponseCode(404))
        RemoteRemoval(restarted, ApiClient(restarted)).removeDevice(restarted.recordId()!!, "device")
        assertEquals("DELETE", server.takeRequest().method)
        assertEquals("remove_device", restarted.pendingRemoteRemoval())
        restarted.clear()
        assertNull(restarted.pendingRemoteRemoval())
        assertFalse(restarted.isEnrolled())
    }

    @Test fun relayDeletionIntentSurvivesLostResponseAndRestart() = runBlocking {
        server.enqueue(MockResponse().setSocketPolicy(okhttp3.mockwebserver.SocketPolicy.DISCONNECT_AFTER_REQUEST))
        try { RemoteRemoval(store, ApiClient(store)).deleteRelay(store.recordId()!!); fail() } catch (_: java.io.IOException) { }
        val restarted = RecordStore(prefs, store.serverUrl)
        assertEquals("delete_relay", restarted.pendingRemoteRemoval())
        assertTrue(restarted.isEnrolled())
        server.enqueue(MockResponse().setResponseCode(404))
        RemoteRemoval(restarted, ApiClient(restarted)).deleteRelay(restarted.recordId()!!)
        assertEquals("delete_relay", restarted.pendingRemoteRemoval())
    }
    @Test fun restartAfterSuccessfulRelayDeleteRetainsIntentUntilCleanup() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(204))
        RemoteRemoval(store, ApiClient(store)).deleteRelay(store.recordId()!!)
        val restarted = RecordStore(prefs, store.serverUrl)
        assertEquals("delete_relay", restarted.pendingRemoteRemoval())
        assertTrue(restarted.isEnrolled())
        server.enqueue(MockResponse().setResponseCode(404))
        RemoteRemoval(restarted, ApiClient(restarted)).deleteRelay(restarted.recordId()!!)
        assertEquals("delete_relay", restarted.pendingRemoteRemoval())
        restarted.clear()
        assertFalse(restarted.isEnrolled())
        assertNull(restarted.pendingRemoteRemoval())
    }

}
