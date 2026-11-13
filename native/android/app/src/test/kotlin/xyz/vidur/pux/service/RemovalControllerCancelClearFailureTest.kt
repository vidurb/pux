package xyz.vidur.pux.service

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
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
import xyz.vidur.pux.ui.screens.RemovalFailure

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], application = Application::class)
class RemovalControllerCancelClearFailureTest {
    private lateinit var prefs: FakeSharedPreferences
    private lateinit var store: RecordStore
    private lateinit var controller: RemovalController

    @Before fun setUp() {
        RecordStoreTestIsolation.reset()
        prefs = FakeSharedPreferences()
        store = RecordStore(prefs)
        store.saveEnrollment(enrollment())
        store.beginRemoteRemoval("delete_relay")
        prefs.failNextCommit = true
        val delivery = DeliveryController(store, ApiClient(store))
        controller = RemovalController(
            ApplicationProvider.getApplicationContext(),
            store,
            ApiClient(store),
            delivery
        )
        setFailed(
            controller,
            RemovalFailure(
                RemovalAction.DELETE_RELAY,
                "Couldn't delete the relay",
                "offline",
                "warn",
                serverUnreachable = true,
                keepRemovalIntentOnCancel = false
            )
        )
    }

    @Test fun cancelClearPendingCommitFailureKeepsFailedState() {
        controller.cancelFailure(clearPendingRemoval = true)
        assertTrue(controller.state.value is RemovalState.Failed)
        assertEquals("delete_relay", store.pendingRemoteRemoval())
    }

    private fun setFailed(controller: RemovalController, failure: RemovalFailure) {
        val field = RemovalController::class.java.getDeclaredField("_state")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val flow = field.get(controller) as kotlinx.coroutines.flow.MutableStateFlow<RemovalState>
        flow.value = RemovalState.Failed(failure)
    }

    private fun enrollment() = mapOf(
        "v" to 1,
        "record_id" to "12345678-1234-1234-1234-123456789abc",
        "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
        "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
        "inbox" to "test@pux.xyz"
    )
}
