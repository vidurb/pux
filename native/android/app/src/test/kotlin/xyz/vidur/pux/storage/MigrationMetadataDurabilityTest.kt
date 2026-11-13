package xyz.vidur.pux.storage

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.testutil.FakeSharedPreferences
import java.security.Key

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class MigrationMetadataDurabilityTest {
    private lateinit var targetStore: RecordStore
    private lateinit var targetPrefs: FakeSharedPreferences
    private lateinit var dataPrefs: FakeSharedPreferences
    private lateinit var migrationPrefs: FakeSharedPreferences
    private lateinit var testContext: Context
    private lateinit var aesKey: Key

    @Before fun setUp() {
        targetPrefs = FakeSharedPreferences()
        dataPrefs = FakeSharedPreferences()
        migrationPrefs = FakeSharedPreferences()
        aesKey = FlutterSecureStorageFixture.generateAesKey()
        targetStore = RecordStore(targetPrefs, defaultServerUrl = "https://pux.vidur.xyz")
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

    @Test fun metadataPersistsWhenMigrationTombstoneFails() {
        dataPrefs.edit()
            .putString(
                FlutterSecureStorageMigrator.FLUTTER_PREFIX + RecordStore.KEY_DISMISSED_RESTRICTIONS,
                FlutterSecureStorageFixture.encrypt("HIBERNATION", aesKey)
            )
            .commit()
        dataPrefs.failNextCommit = true
        val migrator = FlutterSecureStorageMigrator(
            testContext,
            targetStore,
            AesKeyUnwrapper { aesKey }
        )
        val result = migrator.migrate()
        assertTrue(result is FlutterSecureStorageMigrator.MigrationResult.Failed)
        assertEquals(setOf("HIBERNATION"), targetStore.dismissedRestrictionPrompts())
        assertTrue(FlutterSecureStorageMigrator.isLegacyCleanupPending(testContext))
        assertFalse(FlutterSecureStorageMigrator.isMigrationCompleted(testContext))
        assertFalse(MigrationRecovery.succeeded(testContext, result))
        assertTrue(
            dataPrefs.contains(FlutterSecureStorageMigrator.FLUTTER_PREFIX + RecordStore.KEY_DISMISSED_RESTRICTIONS)
        )
    }

    @Test fun reconcileRollsBackWhenTombstoneFailsAfterMetadataWrite() {
        targetStore.saveDismissedRestrictionPrompts(setOf("BATTERY_SAVER"))
        targetStore.saveEnrollment(
            mapOf(
                "v" to 1,
                "record_id" to "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
                "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
                "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
                "inbox" to "test@pux.xyz",
            )
        )
        val recordId = "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d"
        dataPrefs.edit()
            .putString(
                FlutterSecureStorageMigrator.FLUTTER_PREFIX + RecordStore.KEY_RECORD_ID,
                FlutterSecureStorageFixture.encrypt(recordId, aesKey)
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
        assertEquals(setOf("BATTERY_SAVER", "HIBERNATION"), targetStore.dismissedRestrictionPrompts())
        assertFalse(FlutterSecureStorageMigrator.isMigrationCompleted(testContext))
    }

    @Test fun destinationDismissedCommitFailureLeavesLegacyIntact() {
        dataPrefs.edit()
            .putString(
                FlutterSecureStorageMigrator.FLUTTER_PREFIX + RecordStore.KEY_DISMISSED_RESTRICTIONS,
                FlutterSecureStorageFixture.encrypt("HIBERNATION", aesKey)
            )
            .commit()
        targetPrefs.failNextCommit = true
        val migrator = FlutterSecureStorageMigrator(testContext, targetStore, AesKeyUnwrapper { aesKey })
        val result = migrator.migrate()
        assertTrue(result is FlutterSecureStorageMigrator.MigrationResult.Failed)
        assertTrue(targetStore.dismissedRestrictionPrompts().isEmpty())
        assertFalse(FlutterSecureStorageMigrator.isMigrationCompleted(testContext))
    }
}
