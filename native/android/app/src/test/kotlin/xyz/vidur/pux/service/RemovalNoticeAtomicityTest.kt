package xyz.vidur.pux.service

import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import androidx.test.core.app.ApplicationProvider
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

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], application = Application::class)
class RemovalNoticeAtomicityTest {
    @Before fun resetGate() {
        RecordStoreTestIsolation.reset()
    }

    @Test fun staleMarkerSurvivesUntilNoticePersisted() {
        val prefs = FakeSharedPreferences()
        val store = RecordStore(prefs)
        store.saveEnrollment(
            mapOf(
                "v" to 1,
                "record_id" to "12345678-1234-1234-1234-123456789abc",
                "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
                "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
                "inbox" to "test@pux.xyz"
            )
        )
        store.beginDeviceRegistration()
        val wasUncertain = store.beginDeviceRegistration()
        store.finishDeviceRegistration("device", wasUncertain)
        assertTrue(store.staleRegistrationPossible())
        val context = ApplicationProvider.getApplicationContext<Application>()
        val api = ApiClient(store)
        val controller = RemovalController(context, store, api, DeliveryController(store, api))
        val message = controller.staleRegistrationNoticeAfterRemoval()
        assertTrue(message != null)
        assertTrue(store.staleRegistrationPossible())
        RemovalNoticeStore.save(context, message!!)
        store.clearStaleRegistrationPossible()
        org.junit.Assert.assertFalse(store.staleRegistrationPossible())
    }
}
