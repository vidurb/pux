package xyz.vidur.pux.service

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.api.ApiClient
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.testutil.FakeSharedPreferences
import xyz.vidur.pux.testutil.RecordStoreTestIsolation
import xyz.vidur.pux.ui.screens.RemovalAction

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], application = Application::class)
class RemovalControllerUnreachablePersistFailureTest {
    private lateinit var prefs: FakeSharedPreferences
    private lateinit var store: RecordStore
    private lateinit var controller: RemovalController

    @Before fun setUp() {
        RecordStoreTestIsolation.reset()
        prefs = FakeSharedPreferences()
        store = RecordStore(prefs, "https://no.dns.example.invalid")
        store.saveEnrollment(
            mapOf(
                "v" to 1,
                "record_id" to "12345678-1234-1234-1234-123456789abc",
                "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
                "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
                "inbox" to "test@pux.xyz"
            )
        )
        prefs.resetCommitInstrumentation()
        prefs.failCommitNumber = 2
        val delivery = DeliveryController(store, ApiClient(store))
        controller = RemovalController(
            ApplicationProvider.getApplicationContext(),
            store,
            ApiClient(store),
            delivery,
            CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        )
    }

    @Test fun storageFailureWhileMarkingUnreachablePresentsFailedWithoutCrashing() = runBlocking {
        controller.run(RemovalAction.DELETE_RELAY)
        withTimeout(5_000) {
            while (controller.state.value !is RemovalState.Failed) {
                kotlinx.coroutines.delay(10)
            }
        }
        assertNotEquals(RemovalState.Running, controller.state.value)
        val failure = (controller.state.value as RemovalState.Failed).failure
        assertEquals(RemovalAction.DELETE_RELAY, failure.action)
        assertFalse(failure.serverUnreachable)
        assertTrue(
            failure.error.contains("reachability", ignoreCase = true) ||
                failure.error.contains("Could not", ignoreCase = true)
        )
        assertEquals("delete_relay", store.pendingRemoteRemoval())
        assertFalse(store.pendingRemovalServerUnreachable())
    }
}
