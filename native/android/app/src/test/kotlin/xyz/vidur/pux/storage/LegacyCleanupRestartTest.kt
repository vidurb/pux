package xyz.vidur.pux.storage

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.testutil.FakeSharedPreferences

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class LegacyCleanupRestartTest {
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
        val base = ApplicationProvider.getApplicationContext<Context>()
        testContext = object : ContextWrapper(base) {
            override fun getPackageName(): String = "xyz.vidur.pux"
            override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences = when (name) {
                FlutterSecureStorageMigrator.FLUTTER_DATA_PREFS_NAME -> dataPrefs
                FlutterSecureStorageMigrator.MIGRATION_PREFS_NAME -> migrationPrefs
                else -> super.getSharedPreferences(name, mode)
            }
        }
    }

    @Test fun failedLegacyDeleteLeavesCleanupPendingAndRecoveryFalseUntilRestartFinishes() {
        dataPrefs.edit()
            .putString(
                FlutterSecureStorageMigrator.FLUTTER_PREFIX + RecordStore.KEY_NOTIFICATION_PERMISSION_ASKED,
                FlutterSecureStorageFixture.encrypt("true", aesKey)
            )
            .commit()
        dataPrefs.failNextCommit = true
        val migrator = FlutterSecureStorageMigrator(testContext, targetStore, AesKeyUnwrapper { aesKey })
        val first = migrator.migrate()
        assertTrue(first is FlutterSecureStorageMigrator.MigrationResult.Failed)
        assertTrue(FlutterSecureStorageMigrator.isLegacyCleanupPending(testContext))
        assertFalse(FlutterSecureStorageMigrator.isMigrationCompleted(testContext))
        assertFalse(MigrationRecovery.succeeded(testContext, first))
        assertTrue(
            dataPrefs.contains(FlutterSecureStorageMigrator.FLUTTER_PREFIX + RecordStore.KEY_NOTIFICATION_PERMISSION_ASKED)
        )
        assertTrue(targetStore.notificationPermissionAsked())

        dataPrefs.failNextCommit = false
        val restarted = FlutterSecureStorageMigrator(testContext, targetStore, AesKeyUnwrapper { aesKey }).migrate()
        assertTrue(restarted is FlutterSecureStorageMigrator.MigrationResult.Success)
        assertFalse(FlutterSecureStorageMigrator.isLegacyCleanupPending(testContext))
        assertTrue(FlutterSecureStorageMigrator.isMigrationCompleted(testContext))
        assertFalse(FlutterSecureStorageMigrator.hasLegacyMigratableEntries(testContext))
        assertTrue(MigrationRecovery.succeeded(testContext, FlutterSecureStorageMigrator.MigrationResult.NotNeeded))
    }
}
