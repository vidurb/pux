package xyz.vidur.pux.service

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.api.ApiClient
import xyz.vidur.pux.model.DeliveryState
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.testutil.FakeSharedPreferences
import java.io.IOException
import java.util.Random

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class DeliveryControllerTest {

    private lateinit var server: MockWebServer
    private lateinit var store: RecordStore
    private lateinit var apiClient: ApiClient

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()

        val prefs = FakeSharedPreferences()
        val baseUrl = server.url("").toString().removeSuffix("/")
        store = RecordStore(prefs, defaultServerUrl = baseUrl)
        apiClient = ApiClient(store)
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun enrollStore() {
        store.saveEnrollment(mapOf(
            "v" to 1,
            "record_id" to "12345678-1234-1234-1234-123456789abc",
            "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
            "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
            "inbox" to "test@pux.xyz"
        ))
    }

    @Test
    fun testBackoffCalculation() {
        val zeroRandom = object : Random() {
            override fun nextInt(bound: Int): Int = 0
        }

        // Attempt 0: 2000ms
        val delay0 = DeliveryController.backoff(0, zeroRandom)
        assertEquals(2000L, delay0)

        // Attempt 1: 4000ms
        val delay1 = DeliveryController.backoff(1, zeroRandom)
        assertEquals(4000L, delay1)

        // Attempt 4: 32000ms
        val delay4 = DeliveryController.backoff(4, zeroRandom)
        assertEquals(32000L, delay4)

        // Attempt 10: capped at MAX_BACKOFF_MS (300_000L)
        val delay10 = DeliveryController.backoff(10, zeroRandom)
        assertEquals(DeliveryController.MAX_BACKOFF_MS, delay10)

        // Attempt 25: still capped at MAX_BACKOFF_MS
        val delay25 = DeliveryController.backoff(25, zeroRandom)
        assertEquals(DeliveryController.MAX_BACKOFF_MS, delay25)
    }

    @Test
    fun testBackoffJitterRange() {
        for (attempt in 0..6) {
            val delayWithJitter = DeliveryController.backoff(attempt, Random())
            val base = DeliveryController.backoff(attempt, object : Random() {
                override fun nextInt(bound: Int): Int = 0
            })
            assertTrue(delayWithJitter >= base)
            assertTrue(delayWithJitter <= DeliveryController.MAX_BACKOFF_MS)
        }
    }

    @Test
    fun testReportUndecryptableIncrements() {
        val controller = DeliveryController(store, apiClient)

        assertEquals(0, controller.status.value.undecryptable)

        controller.reportUndecryptable()
        assertEquals(1, controller.status.value.undecryptable)

        controller.reportUndecryptable()
        assertEquals(2, controller.status.value.undecryptable)
    }

    @Test
    fun testStopResetsToIdle() = runTest {
        val controller = DeliveryController(store, apiClient)

        controller.stop()
        assertEquals(DeliveryState.IDLE, controller.status.value.state)
    }

    @Test
    fun testFcmRegisterFailureTransitionsToRetryingAndDoesNotSetReady() = runTest {
        enrollStore()
        val testDispatcher = UnconfinedTestDispatcher(testScheduler)
        val testScope = TestScope(testDispatcher)
        val testApiClient = ApiClient(store, ioDispatcher = testDispatcher)

        val failingRegistrar = object : FcmRegistrar {
            override suspend fun register() {
                throw IOException("FCM service unavailable")
            }
        }

        val controller = DeliveryController(
            recordStore = store,
            apiClient = testApiClient,
            scope = testScope,
            fcmRegistrar = failingRegistrar
        )

        controller.start()
        testScheduler.advanceUntilIdle()

        assertEquals(DeliveryState.RETRYING, controller.status.value.state)
        assertTrue(controller.status.value.message?.contains("FCM service unavailable") == true)
        assertNotEquals(DeliveryState.READY, controller.status.value.state)
    }

    @Test
    fun testSuccessfulFcmRegistrationTransitionsToReady() = runTest {
        enrollStore()
        val testDispatcher = UnconfinedTestDispatcher(testScheduler)
        val testScope = TestScope(testDispatcher)
        val testApiClient = ApiClient(store, ioDispatcher = testDispatcher)

        val successfulRegistrar = object : FcmRegistrar {
            override suspend fun register() {
                // Successful registration
            }
        }

        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setBody("""{"device_id":"dev-12345"}""")
        )

        val controller = DeliveryController(
            recordStore = store,
            apiClient = testApiClient,
            scope = testScope,
            fcmRegistrar = successfulRegistrar
        )

        controller.start()
        controller.onRegistered("valid-fcm-installation-id")
        testScheduler.advanceUntilIdle()

        assertEquals(DeliveryState.READY, controller.status.value.state)
        assertNull(controller.status.value.message)
        assertEquals("dev-12345", store.deviceId())
    }

    @Test
    fun testStopPreventsSubsequentOnRegisteredFromModifyingStateOrStorage() = runTest {
        enrollStore()
        val testDispatcher = UnconfinedTestDispatcher(testScheduler)
        val testScope = TestScope(testDispatcher)
        val testApiClient = ApiClient(store, ioDispatcher = testDispatcher)

        val controller = DeliveryController(
            recordStore = store,
            apiClient = testApiClient,
            scope = testScope,
            fcmRegistrar = object : FcmRegistrar { override suspend fun register() {} }
        )

        controller.start()
        controller.stop()
        assertEquals(DeliveryState.IDLE, controller.status.value.state)

        // Late callback arrives after stop()
        controller.onRegistered("late-fid")
        testScheduler.advanceUntilIdle()

        assertEquals(DeliveryState.IDLE, controller.status.value.state)
        assertNull(store.deviceId())
    }

    @Test
    fun testFidRefreshFailureReportsRetrying() = runTest {
        enrollStore()
        val testDispatcher = UnconfinedTestDispatcher(testScheduler)
        val testScope = TestScope(testDispatcher)
        val testApiClient = ApiClient(store, ioDispatcher = testDispatcher)

        val controller = DeliveryController(
            recordStore = store,
            apiClient = testApiClient,
            scope = testScope,
            fcmRegistrar = object : FcmRegistrar { override suspend fun register() {} }
        )

        // 1. Initial success
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setBody("""{"device_id":"dev-initial"}""")
        )
        controller.start()
        controller.onRegistered("fid-1")
        testScheduler.advanceUntilIdle()
        assertEquals(DeliveryState.READY, controller.status.value.state)

        // 2. Refresh FID arrives, but server registration fails
        server.enqueue(
            MockResponse()
                .setResponseCode(503)
                .setBody("Service unavailable")
        )
        controller.onRegistered("fid-2")
        testScheduler.advanceUntilIdle()

        assertEquals(DeliveryState.RETRYING, controller.status.value.state)
    }

    @Test
    fun testRegisterTimeoutCoversSuspendedFcmRegistrar() = runTest {
        enrollStore()
        val testDispatcher = UnconfinedTestDispatcher(testScheduler)
        val testScope = TestScope(testDispatcher)
        val testApiClient = ApiClient(store, ioDispatcher = testDispatcher)

        val hangingRegistrar = object : FcmRegistrar {
            override suspend fun register() {
                kotlinx.coroutines.delay(60_000)
            }
        }

        val controller = DeliveryController(
            recordStore = store,
            apiClient = testApiClient,
            scope = testScope,
            fcmRegistrar = hangingRegistrar
        )

        controller.start()
        testScheduler.advanceTimeBy(35_000)
        testScheduler.advanceUntilIdle()

        assertEquals(DeliveryState.RETRYING, controller.status.value.state)
        assertTrue(controller.status.value.message?.contains("timed out") == true)
        assertNotEquals(DeliveryState.READY, controller.status.value.state)
    }

    @Test
    fun testOnUnregisteredTriggersReRegistration() = runTest {
        enrollStore()
        val testDispatcher = UnconfinedTestDispatcher(testScheduler)
        val testScope = TestScope(testDispatcher)
        val testApiClient = ApiClient(store, ioDispatcher = testDispatcher)

        val controller = DeliveryController(
            recordStore = store,
            apiClient = testApiClient,
            scope = testScope,
            fcmRegistrar = object : FcmRegistrar { override suspend fun register() {} }
        )

        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setBody("""{"device_id":"dev-1"}""")
        )

        controller.start()
        controller.onRegistered("fid-active")
        assertEquals(DeliveryState.READY, controller.status.value.state)

        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setBody("""{"device_id":"dev-2"}""")
        )

        // FCM reports unregistered
        controller.onUnregistered("fid-active")

        // New callback arrives for the re-registration
        controller.onRegistered("fid-new")

        assertEquals(DeliveryState.READY, controller.status.value.state)
        assertEquals("dev-2", store.deviceId())
    }

    @Test
    fun stopWaitsForServerRegistrationBeforeDeletingReturnedDevice() = kotlinx.coroutines.runBlocking {
        enrollStore()
        val release = java.util.concurrent.CountDownLatch(1)
        server.dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse {
                if (request.method == "POST") {
                    check(release.await(10, java.util.concurrent.TimeUnit.SECONDS))
                    return MockResponse().setResponseCode(200).setBody("""{"device_id":"dev-delayed"}""")
                }
                return MockResponse().setResponseCode(204)
            }
        }
        val controller = DeliveryController(store, apiClient, fcmRegistrar = object : FcmRegistrar {
            override suspend fun register() {}
        })
        try {
            controller.start()
            controller.onRegistered("fid")
            assertEquals("POST", server.takeRequest(5, java.util.concurrent.TimeUnit.SECONDS)?.method)
            val stopping = async(kotlinx.coroutines.Dispatchers.Default) { controller.stop() }
            kotlinx.coroutines.delay(100)
            assertFalse(stopping.isCompleted)
            release.countDown()
            stopping.await()
            assertEquals("dev-delayed", store.deviceId())
            apiClient.deleteDevice(store.recordId()!!, store.deviceId()!!)
            val deletion = server.takeRequest(5, java.util.concurrent.TimeUnit.SECONDS)
            assertEquals("DELETE", deletion?.method)
            assertTrue(deletion?.path?.endsWith("/dev-delayed") == true)
            assertEquals(DeliveryState.IDLE, controller.status.value.state)
        } finally { release.countDown() }
    }
    @Test
    fun lostRegistrationResponseRemainsUncertainAcrossRestartAndRetry() = runTest {
        enrollStore()
        val dispatcher = UnconfinedTestDispatcher(testScheduler)
        val controller = DeliveryController(store, ApiClient(store, ioDispatcher = dispatcher), TestScope(dispatcher),
            object : FcmRegistrar { override suspend fun register() {} })
        val serverRegistrations = java.util.concurrent.atomic.AtomicInteger()
        server.dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse {
                serverRegistrations.incrementAndGet() // Simulate the server committing before the response is lost.
                return MockResponse().setSocketPolicy(okhttp3.mockwebserver.SocketPolicy.DISCONNECT_AFTER_REQUEST)
            }
        }
        try {
            controller.start()
            controller.onRegistered("fid-uncertain")
            testScheduler.advanceUntilIdle()
            assertEquals(1, serverRegistrations.get())
            assertTrue(store.registrationUncertain())
            assertNull(store.deviceId())
            controller.stop()
            // A retry may recover an ID, but cannot prove the first request is no longer executing.
            server.dispatcher = okhttp3.mockwebserver.QueueDispatcher()
            server.enqueue(MockResponse().setResponseCode(200).setBody("""{"device_id":"dev-recovered"}"""))
            controller.start()
            controller.onRegistered("fid-uncertain")
            testScheduler.advanceUntilIdle()
            assertEquals("dev-recovered", store.deviceId())
            assertFalse(store.registrationUncertain())
            assertTrue(store.staleRegistrationPossible())
        } finally {
            controller.stop()
        }
    }

    @Test
    fun resumeDuringDelayedRemovalDoesNotRegisterUntilGateReleased() = kotlinx.coroutines.runBlocking {
        enrollStore()
        store.saveDeviceId("device-before")
        val release = java.util.concurrent.CountDownLatch(1)
        server.dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse {
                if (request.method == "DELETE") {
                    check(release.await(10, java.util.concurrent.TimeUnit.SECONDS))
                    return MockResponse().setResponseCode(204)
                }
                return MockResponse().setResponseCode(200).setBody("""{"device_id":"unexpected"}""")
            }
        }
        val registrations = java.util.concurrent.atomic.AtomicInteger()
        val controller = DeliveryController(store, apiClient, fcmRegistrar = object : FcmRegistrar {
            override suspend fun register() { registrations.incrementAndGet() }
        })
        try {
            controller.beginRemoval()
            val deleting = async(kotlinx.coroutines.Dispatchers.IO) {
                apiClient.deleteDevice(store.recordId()!!, store.deviceId()!!)
            }
            assertEquals("DELETE", server.takeRequest(5, java.util.concurrent.TimeUnit.SECONDS)?.method)
            controller.onResume()
            controller.start()
            controller.onRegistered("late-fid")
            kotlinx.coroutines.delay(100)
            assertEquals(0, registrations.get())
            assertNull(server.takeRequest(100, java.util.concurrent.TimeUnit.MILLISECONDS))
            release.countDown()
            deleting.await()
            controller.endRemoval()
            controller.start()
            kotlinx.coroutines.withTimeout(5000) { while (registrations.get() == 0) kotlinx.coroutines.delay(10) }
            assertEquals(1, registrations.get())
            controller.stop()
        } finally { release.countDown() }
    }

    @Test
    fun definitiveRejectionsDoNotPoisonSuccessfulRetry() = runTest {
        for (response in listOf(
            MockResponse().setResponseCode(429),
            MockResponse().setResponseCode(422).setBody("""{"error":"too_many_devices"}"""),
            MockResponse().setResponseCode(422).setBody("""{"error":"invalid token"}""")
        )) {
            val prefs = FakeSharedPreferences()
            val localStore = RecordStore(prefs, server.url("").toString().removeSuffix("/"))
            localStore.saveEnrollment(mapOf("v" to 1, "record_id" to "12345678-1234-1234-1234-123456789abc",
                "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
                "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI", "inbox" to "test@pux.xyz"))
            val dispatcher = UnconfinedTestDispatcher(testScheduler)
            val controller = DeliveryController(localStore, ApiClient(localStore, ioDispatcher = dispatcher),
                TestScope(dispatcher), object : FcmRegistrar { override suspend fun register() {} })
            server.enqueue(response)
            controller.start()
            controller.onRegistered("fid-rejected")
            testScheduler.runCurrent()
            assertFalse(localStore.registrationUncertain())
            server.enqueue(MockResponse().setResponseCode(200).setBody("""{"device_id":"confirmed"}"""))
            controller.start()
            controller.onRegistered("fid-rejected")
            testScheduler.runCurrent()
            assertEquals("confirmed", localStore.deviceId())
            assertFalse(localStore.registrationUncertain())
            controller.stop()
        }
    }

    @Test
    fun definitiveRejectionDoesNotErasePriorAmbiguity() = runTest {
        enrollStore()
        store.beginDeviceRegistration() // Simulate a previous request whose response was lost.
        val dispatcher = UnconfinedTestDispatcher(testScheduler)
        val controller = DeliveryController(store, ApiClient(store, ioDispatcher = dispatcher), TestScope(dispatcher),
            object : FcmRegistrar { override suspend fun register() {} })
        server.enqueue(MockResponse().setResponseCode(429))
        controller.start()
        controller.onRegistered("fid")
        testScheduler.runCurrent()
        assertTrue(store.registrationUncertain())
        controller.stop()
    }

}
