package xyz.vidur.pux.storage

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.testutil.FakeSharedPreferences

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class FlutterSecureStorageReconcileErrorsTest {
    private lateinit var targetStore: RecordStore
    private lateinit var targetPrefs: FakeSharedPreferences
    private lateinit var dataPrefs: FakeSharedPreferences
    private lateinit var migrationPrefs: FakeSharedPreferences
    private lateinit var testContext: Context
    private lateinit var aesKey: java.security.Key

    @Before fun setUp() {
        targetPrefs = FakeSharedPreferences()
        dataPrefs = FakeSharedPreferences()
        migrationPrefs = FakeSharedPreferences()
        aesKey = FlutterSecureStorageFixture.generateAesKey()
        targetStore = RecordStore(targetPrefs)
        val baseContext = ApplicationProvider.getApplicationContext<Context>()
        testContext = object : ContextWrapper(baseContext) {
            override fun getPackageName(): String = "xyz.vidur.pux"
            override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences = when (name) {
                FlutterSecureStorageMigrator.FLUTTER_DATA_PREFS_NAME -> dataPrefs
                FlutterSecureStorageMigrator.MIGRATION_PREFS_NAME -> migrationPrefs
                else -> super.getSharedPreferences(name, mode)
            }
        }
    }

    @Test fun reconcilePersistenceFailureIsDistinctFromIdentityConflict() {
        targetStore.saveEnrollment(
            mapOf(
                "v" to 1,
                "record_id" to "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
                "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
                "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
                "inbox" to "test@pux.xyz",
            )
        )
        dataPrefs.edit()
            .putString(
                FlutterSecureStorageMigrator.FLUTTER_PREFIX + RecordStore.KEY_RECORD_ID,
                FlutterSecureStorageFixture.encrypt("a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d", aesKey)
            )
            .putString(
                FlutterSecureStorageMigrator.FLUTTER_PREFIX + RecordStore.KEY_PUBLIC_KEY,
                FlutterSecureStorageFixture.encrypt("6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw", aesKey)
            )
            .putString(
                FlutterSecureStorageMigrator.FLUTTER_PREFIX + RecordStore.KEY_PRIVATE_KEY,
                FlutterSecureStorageFixture.encrypt("vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI", aesKey)
            )
            .putString(
                FlutterSecureStorageMigrator.FLUTTER_PREFIX + RecordStore.KEY_DISMISSED_RESTRICTIONS,
                FlutterSecureStorageFixture.encrypt("HIBERNATION", aesKey)
            )
            .commit()
        migrationPrefs.failNextCommit = true
        val migrator = FlutterSecureStorageMigrator(testContext, targetStore, AesKeyUnwrapper { aesKey })
        val result = migrator.migrate()
        assertTrue(result is FlutterSecureStorageMigrator.MigrationResult.Failed)
        val failed = result as FlutterSecureStorageMigrator.MigrationResult.Failed
        assertTrue(failed.reason.startsWith(FlutterSecureStorageMigrator.FAILURE_LEGACY_PERSISTENCE_PREFIX))
        assertTrue(
            failed.reason.contains("Could not persist legacy cleanup state") ||
                failed.reason.contains("Could not persist migration marker")
        )
    }
}
