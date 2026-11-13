package xyz.vidur.pux

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.api.ApiClient
import xyz.vidur.pux.model.DeliveryState
import xyz.vidur.pux.service.DeliveryController
import xyz.vidur.pux.service.DeliveryStartGate
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.testutil.FakeSharedPreferences
import xyz.vidur.pux.testutil.RecordStoreTestIsolation

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34])
class PuxApplicationMigrationRetryTest {
    private lateinit var store: RecordStore
    private lateinit var delivery: DeliveryController

    @Before
    fun setUp() {
        RecordStoreTestIsolation.reset()
        store = RecordStore(FakeSharedPreferences())
        store.saveEnrollment(enrollment())
        delivery = DeliveryController(store, ApiClient(store))
    }

    @Test
    fun migrationRetryMustNotResumeDeliveryWhileRemoteRemovalPending() {
        store.beginRemoteRemoval("delete_relay")
        assertFalse(store.pendingRemoteRemoval() == null)
        delivery.start()
        assertEquals(DeliveryState.IDLE, delivery.status.value.state)
    }

    @Test
    fun migrationRetryMayStartDeliveryOnlyWithoutPendingRemoval() {
        assertEquals(null, store.pendingRemoteRemoval())
        delivery.start()
        assertFalse(delivery.status.value.state == DeliveryState.IDLE)
    }

    @Test
    fun migrationRetryMustNotResumeWhileForgetCleanupPending() {
        RecordStore.enrollmentBlocked = true
        assertFalse(
            DeliveryStartGate.mayStart(
                store = store,
                forgetCleanupPending = true,
                storageUnavailable = false,
            )
        )
        delivery.start()
        assertEquals(DeliveryState.IDLE, delivery.status.value.state)
    }

    private fun enrollment() = mapOf(
        "v" to 1,
        "record_id" to "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
        "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
        "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
        "inbox" to "test@pux.xyz"
    )
}
