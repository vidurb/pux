package xyz.vidur.pux.api

import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import xyz.vidur.pux.model.ServerHealthState
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.testutil.FakeSharedPreferences

class ApiClientTest {

    private lateinit var server: MockWebServer
    private lateinit var store: RecordStore
    private lateinit var client: ApiClient

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()

        val prefs = FakeSharedPreferences()
        val baseUrl = server.url("").toString().removeSuffix("/")
        store = RecordStore(prefs, defaultServerUrl = baseUrl)
        client = ApiClient(store)
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun createRecordSendsPublicKeyAndParsesResponse() = runBlocking {
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setBody("""{"record_id":"uuid-1234","inbox_address":"test@pux.vidur.xyz"}""")
        )

        val result = client.createRecord("test-public-key-32-bytes")

        assertEquals("uuid-1234", result.recordId)
        assertEquals("test@pux.vidur.xyz", result.inboxAddress)

        val request = server.takeRequest()
        assertEquals("/api/v1/records", request.path)
        assertEquals("POST", request.method)
        assertTrue(request.body.readUtf8().contains("test-public-key-32-bytes"))
    }

    @Test
    fun registerDeviceSendsBearerTokenAndReturnsDeviceId() = runBlocking {
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setBody("""{"device_id":"dev-999"}""")
        )

        val deviceId = client.registerDevice(
            recordId = "record-secret-uuid",
            pushToken = "fid-token-123",
            platform = "fcm",
            replacesDeviceId = "old-dev-111"
        )

        assertEquals("dev-999", deviceId)

        val request = server.takeRequest()
        assertEquals("/api/v1/record/devices", request.path)
        // Record ID must NOT be in URL
        assertFalse(request.path?.contains("record-secret-uuid") == true)
        // Must be in Authorization header
        assertEquals("Bearer record-secret-uuid", request.getHeader("Authorization"))

        val body = request.body.readUtf8()
        assertTrue(body.contains("fid-token-123"))
        assertTrue(body.contains("fcm"))
        assertTrue(body.contains("old-dev-111"))
    }

    @Test(expected = RecordNotFoundException::class)
    fun registerDeviceThrowsRecordNotFoundOn404() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(404))
        client.registerDevice("rec-1", "token-1")
        Unit
    }

    @Test(expected = TooManyDevicesException::class)
    fun registerDeviceThrowsTooManyDevicesOn422() = runBlocking {
        server.enqueue(
            MockResponse()
                .setResponseCode(422)
                .setBody("""{"error":"too_many_devices"}""")
        )
        client.registerDevice("rec-1", "token-1")
        Unit
    }

    @Test(expected = RateLimitedException::class)
    fun registerDeviceThrowsRateLimitedOn429() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(429))
        client.registerDevice("rec-1", "token-1")
        Unit
    }

    @Test
    fun deleteDeviceSucceedsAndIgnores404() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(404))
        client.deleteDevice("rec-1", "dev-1")

        val request = server.takeRequest()
        assertEquals("/api/v1/record/devices/dev-1", request.path)
        assertEquals("DELETE", request.method)
        assertEquals("Bearer rec-1", request.getHeader("Authorization"))
    }

    @Test
    fun deleteRecordSucceedsAndIgnores401() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(401))
        client.deleteRecord("rec-1")

        val request = server.takeRequest()
        assertEquals("/api/v1/record", request.path)
        assertEquals("DELETE", request.method)
    }

    @Test
    fun sendTestCodeParsesOtpAndDevices() = runBlocking {
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setBody("""{"otp":"456789","devices":2}""")
        )

        val testCode = client.sendTestCode("rec-1")
        assertEquals("456789", testCode.otp)
        assertEquals(2, testCode.devices)

        val request = server.takeRequest()
        assertEquals("/api/v1/record/test", request.path)
        assertEquals("Bearer rec-1", request.getHeader("Authorization"))
    }

    @Test(expected = NoDevicesException::class)
    fun sendTestCodeThrowsNoDevicesOn409() = runBlocking {
        server.enqueue(
            MockResponse()
                .setResponseCode(409)
                .setBody("""{"error":"no_devices"}""")
        )
        client.sendTestCode("rec-1")
        Unit
    }

    @Test
    fun checkHealthReportsReachableOnOk() = runBlocking {
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setBody("""{"status":"ok"}""")
        )

        val health = client.checkHealth()
        assertEquals(ServerHealthState.REACHABLE, health.state)
        assertNull(health.reason)
    }

    @Test
    fun checkHealthReportsDatabaseUnavailableOn503() = runBlocking {
        server.enqueue(
            MockResponse()
                .setResponseCode(503)
                .setBody("""{"status":"error","detail":"db down"}""")
        )

        val health = client.checkHealth()
        assertEquals(ServerHealthState.SERVER_ERROR, health.state)
        assertEquals("its database is unavailable", health.reason)
    }

    @Test
    fun checkHealthReportsNonPuxServerOn200WithoutOkStatus() = runBlocking {
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setBody("""{"status":"pong"}""")
        )

        val health = client.checkHealth()
        assertEquals(ServerHealthState.SERVER_ERROR, health.state)
        assertEquals("the answer isn't from a pux server", health.reason)
    }
}
