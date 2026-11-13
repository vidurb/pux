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

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class FlutterSecureStorageMigratorTest {

    private lateinit var targetStore: RecordStore
    private lateinit var targetPrefs: FakeSharedPreferences
    private lateinit var dataPrefs: FakeSharedPreferences
    private lateinit var keyPrefs: FakeSharedPreferences
    private lateinit var migrationPrefs: FakeSharedPreferences
    private lateinit var testContext: Context

    @Before
    fun setUp() {
        targetPrefs = FakeSharedPreferences()
        dataPrefs = FakeSharedPreferences()
        keyPrefs = FakeSharedPreferences()
        migrationPrefs = FakeSharedPreferences()
        targetStore = RecordStore(targetPrefs, defaultServerUrl = "https://pux.vidur.xyz")

        val baseContext = ApplicationProvider.getApplicationContext<Context>()
        testContext = object : ContextWrapper(baseContext) {
            override fun getPackageName(): String = "xyz.vidur.pux"

            override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences {
                return when (name) {
                    FlutterSecureStorageMigrator.FLUTTER_DATA_PREFS_NAME -> dataPrefs
                    FlutterSecureStorageMigrator.FLUTTER_KEY_PREFS_NAME -> keyPrefs
                    FlutterSecureStorageMigrator.MIGRATION_PREFS_NAME -> migrationPrefs
                    else -> super.getSharedPreferences(name, mode)
                }
            }
        }
    }

    @Test
    fun returnsNotNeededIfTargetStoreIsAlreadyEnrolledWithoutLegacy() {
        targetStore.saveEnrollment(mapOf(
            "v" to 1,
            "record_id" to "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
            "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
            "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
            "inbox" to "existing@pux.xyz"
        ))
        assertTrue(targetStore.isEnrolled())

        val migrator = FlutterSecureStorageMigrator(testContext, targetStore)
        val result = migrator.migrate()

        assertTrue(result is FlutterSecureStorageMigrator.MigrationResult.NotNeeded)
    }

    @Test
    fun returnsFailedWhenEnrolledWhileLegacyEnrollmentRemains() {
        targetStore.saveEnrollment(enrollment())
        dataPrefs.edit()
            .putString(FlutterSecureStorageMigrator.FLUTTER_PREFIX + RecordStore.KEY_RECORD_ID, "legacy")
            .putString(FlutterSecureStorageMigrator.FLUTTER_PREFIX + RecordStore.KEY_PRIVATE_KEY, "legacy")
            .putString(FlutterSecureStorageMigrator.FLUTTER_PREFIX + RecordStore.KEY_PUBLIC_KEY, "legacy")
            .commit()
        assertTrue(FlutterSecureStorageMigrator.hasLegacyEnrollmentEntries(testContext))

        val migrator = FlutterSecureStorageMigrator(testContext, targetStore)
        val result = migrator.migrate()

        assertTrue(result is FlutterSecureStorageMigrator.MigrationResult.Failed)
    }

    @Test
    fun returnsNotNeededIfNoLegacyEntriesFound() {
        assertFalse(targetStore.isEnrolled())
        val migrator = FlutterSecureStorageMigrator(testContext, targetStore)
        val result = migrator.migrate()

        assertTrue(result is FlutterSecureStorageMigrator.MigrationResult.NotNeeded)
        assertFalse(targetStore.isEnrolled())
    }

    @Test
    fun metadataOnlyNotificationFlagMigratesAsNotNeeded() {
        assertFalse(targetStore.isEnrolled())
        val migrator = FlutterSecureStorageMigrator(testContext, targetStore)
        assertTrue(
            migrator.applyMetadataOnlyMigration(
                mapOf(RecordStore.KEY_NOTIFICATION_PERMISSION_ASKED to "true")
            )
        )
        assertFalse(targetStore.isEnrolled())
        assertTrue(targetStore.notificationPermissionAsked())
        assertTrue(FlutterSecureStorageMigrator.isMigrationCompleted(testContext))
    }

    @Test
    fun returnsFailedAndLeavesTargetUntouchedIfWrappedKeyMissing() {
        assertFalse(targetStore.isEnrolled())
        // Legacy data has prefixed keys, but no wrapped AES key in keyPrefs
        dataPrefs.edit().putString(
            "${FlutterSecureStorageMigrator.FLUTTER_PREFIX}record_id",
            "dummy-encrypted-data"
        ).apply()

        val migrator = FlutterSecureStorageMigrator(testContext, targetStore)
        val result = migrator.migrate()

        assertTrue(result is FlutterSecureStorageMigrator.MigrationResult.Failed)
        assertFalse(targetStore.isEnrolled())
    }

    @Test
    fun returnsNotNeededIfMigrationAlreadyCompleted() {
        assertFalse(targetStore.isEnrolled())
        FlutterSecureStorageMigrator.setMigrationCompleted(testContext)
        assertTrue(FlutterSecureStorageMigrator.isMigrationCompleted(testContext))

        // Even with legacy entries present, completed migration tombstone halts migration
        dataPrefs.edit().putString(
            "${FlutterSecureStorageMigrator.FLUTTER_PREFIX}record_id",
            "dummy"
        ).apply()

        val migrator = FlutterSecureStorageMigrator(testContext, targetStore)
        val result = migrator.migrate()

        assertTrue(result is FlutterSecureStorageMigrator.MigrationResult.NotNeeded)
        assertFalse(targetStore.isEnrolled())
    }

    @Test
    fun clearLegacyDataPreservesUnrelatedPrefsAndSetsTombstone() {
        dataPrefs.edit().putString("some_key", "value").apply()
        keyPrefs.edit().putString("key_entry", "secret").apply()
        assertFalse(FlutterSecureStorageMigrator.isMigrationCompleted(testContext))

        FlutterSecureStorageMigrator.clearLegacyData(testContext)

        assertEquals("value", dataPrefs.getString("some_key", null))
        assertEquals("secret", keyPrefs.getString("key_entry", null))
        assertTrue(FlutterSecureStorageMigrator.isMigrationCompleted(testContext))
    }

    @Test
    fun recordStoreClearWithContextPreventsEnrollmentResurrection() {
        // 1. Initial enrolled state
        targetStore.saveEnrollment(mapOf(
            "v" to 1,
            "record_id" to "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
            "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
            "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
            "inbox" to "existing@pux.xyz"
        ))
        assertTrue(targetStore.isEnrolled())

        // Legacy prefs had old keys
        dataPrefs.edit().putString("${FlutterSecureStorageMigrator.FLUTTER_PREFIX}record_id", "old-id").apply()

        // 2. User removes device or deletes relay
        targetStore.clear(testContext)
        assertFalse(targetStore.isEnrolled())
        assertTrue(dataPrefs.all.isEmpty())
        assertTrue(FlutterSecureStorageMigrator.isMigrationCompleted(testContext))

        // 3. App restarts: migrator runs on next startup
        val migrator = FlutterSecureStorageMigrator(testContext, targetStore)
        val result = migrator.migrate()

        // 4. Must not resurrect old credentials
        assertTrue(result is FlutterSecureStorageMigrator.MigrationResult.NotNeeded)
        assertFalse(targetStore.isEnrolled())
    }

    @Test
    fun saveEnrollmentWithDeviceIdAtomicallyPersistsBoth() {
        targetStore.saveEnrollment(mapOf(
            "v" to 1,
            "record_id" to "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
            "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
            "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
            "inbox" to "existing@pux.xyz",
            "device_id" to "dev-migrated-999"
        ))
        assertTrue(targetStore.isEnrolled())
        assertEquals("dev-migrated-999", targetStore.deviceId())
    }

    @Test
    fun interruptedClearPreservesTombstoneBeforeNativeWipe() {
        targetStore.saveEnrollment(mapOf(
            "v" to 1,
            "record_id" to "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
            "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
            "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
            "inbox" to "existing@pux.xyz"
        ))
        dataPrefs.edit().putString("${FlutterSecureStorageMigrator.FLUTTER_PREFIX}record_id", "old-id").apply()

        targetStore.clear(testContext)

        assertTrue(FlutterSecureStorageMigrator.isMigrationCompleted(testContext))
        assertTrue(dataPrefs.all.isEmpty())
        assertFalse(targetStore.isEnrolled())
    }
    @Test
    fun failedTombstoneWritePreservesNativeAndLegacyEnrollment() {
        targetStore.saveEnrollment(enrollment())
        dataPrefs.edit().putString(FlutterSecureStorageMigrator.FLUTTER_PREFIX + "record_id", "preserved").commit()
        migrationPrefs.failNextCommit = true
        try { targetStore.clear(testContext); org.junit.Assert.fail("forget must fail") } catch (_: IllegalStateException) { }
        assertTrue(targetStore.isEnrolled())
        assertEquals("preserved", dataPrefs.getString(FlutterSecureStorageMigrator.FLUTTER_PREFIX + "record_id", null))
    }

    @Test
    fun interruptedForgetIsCompletedOnRestart() {
        targetStore.saveEnrollment(enrollment())
        dataPrefs.edit().putString(FlutterSecureStorageMigrator.FLUTTER_PREFIX + "record_id", "preserved").commit()
        FlutterSecureStorageMigrator.beginForget(testContext)
        assertTrue(targetStore.isEnrolled())
        assertTrue(FlutterSecureStorageMigrator.isForgetPending(testContext))
        RecordStore(targetPrefs).completeForget(testContext)
        assertFalse(targetStore.isEnrolled())
        assertTrue(dataPrefs.all.isEmpty())
        assertFalse(FlutterSecureStorageMigrator.isForgetPending(testContext))
        assertTrue(FlutterSecureStorageMigrator.isMigrationCompleted(testContext))
    }

    @Test
    fun failedNativeClearLeavesPendingForgetForRetry() {
        targetStore.saveEnrollment(enrollment())
        dataPrefs.edit().putString(FlutterSecureStorageMigrator.FLUTTER_PREFIX + "record_id", "preserved").commit()
        targetPrefs.failNextCommit = true
        try { targetStore.clear(testContext); org.junit.Assert.fail("forget must fail") } catch (_: IllegalStateException) { }
        assertTrue(FlutterSecureStorageMigrator.isForgetPending(testContext))
        assertTrue(targetStore.isEnrolled())
        assertEquals("preserved", dataPrefs.getString(FlutterSecureStorageMigrator.FLUTTER_PREFIX + "record_id", null))
        RecordStore(targetPrefs).completeForget(testContext)
        assertFalse(targetStore.isEnrolled())
    }

    private fun enrollment() = mapOf(
        "v" to 1, "record_id" to "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
        "public_key" to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
        "private_key" to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI", "inbox" to "existing@pux.xyz"
    )

}
