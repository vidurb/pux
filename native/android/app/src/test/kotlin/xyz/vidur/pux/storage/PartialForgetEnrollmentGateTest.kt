package xyz.vidur.pux.storage

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.testutil.FakeSharedPreferences
import xyz.vidur.pux.testutil.RecordStoreTestIsolation

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class PartialForgetEnrollmentGateTest {
    private lateinit var prefs: FakeSharedPreferences
    private lateinit var migrationPrefs: FakeSharedPreferences
    private lateinit var store: RecordStore
    private lateinit var testContext: Context

    @Before fun setUp() {
        RecordStoreTestIsolation.reset()
        prefs = FakeSharedPreferences()
        migrationPrefs = FakeSharedPreferences()
        store = RecordStore(prefs)
        store.saveEnrollment(enrollment())
        val base = ApplicationProvider.getApplicationContext<Context>()
        testContext = object : ContextWrapper(base) {
            override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences = when (name) {
                FlutterSecureStorageMigrator.MIGRATION_PREFS_NAME -> migrationPrefs
                else -> super.getSharedPreferences(name, mode)
            }
        }
    }

    @Test fun nativeWipeThenLegacyFailureBlocksReenrollUntilRestartCompletesForget() {
        FlutterSecureStorageMigrator.beginForget(testContext)
        store.completeForget(null)
        assertFalse(store.isEnrolled())
        RecordStore.enrollmentBlocked = true
        migrationPrefs.failNextCommit = true
        assertThrows(IllegalStateException::class.java) {
            store.completeForget(testContext)
        }
        assertTrue(FlutterSecureStorageMigrator.isForgetPending(testContext))
        assertThrows(IllegalStateException::class.java) { store.saveEnrollment(enrollment()) }
        migrationPrefs.failNextCommit = false
        store.completeForget(testContext)
        assertFalse(FlutterSecureStorageMigrator.isForgetPending(testContext))
        assertFalse(RecordStore.enrollmentBlocked)
        store.saveEnrollment(enrollment())
        assertTrue(store.isEnrolled())
    }

    private fun enrollment() = mapOf(
        "v" to 1,
        "record_id" to "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
        "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
        "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
        "inbox" to "test@pux.xyz"
    )
}
