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
class FlutterSecureStorageMigratorFixtureTest {

    private lateinit var targetStore: RecordStore
    private lateinit var targetPrefs: FakeSharedPreferences
    private lateinit var dataPrefs: FakeSharedPreferences
    private lateinit var migrationPrefs: FakeSharedPreferences
    private lateinit var testContext: Context
    private lateinit var aesKey: Key

  private val enrollmentValues = mapOf(
        RecordStore.KEY_RECORD_ID to "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
        RecordStore.KEY_PRIVATE_KEY to "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
        RecordStore.KEY_PUBLIC_KEY to "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
        RecordStore.KEY_INBOX to "inbox@vidur.xyz",
        RecordStore.KEY_SERVER_URL to "https://pux.vidur.xyz",
        RecordStore.KEY_DEVICE_ID to "dev-flutter-42",
        RecordStore.KEY_NOTIFICATION_PERMISSION_ASKED to "true",
        RecordStore.KEY_NOTIFICATION_EXPLAINER_SKIPPED to "true",
        RecordStore.KEY_DISMISSED_RESTRICTIONS to "HIBERNATION",
    )

    @Before
    fun setUp() {
        targetPrefs = FakeSharedPreferences()
        dataPrefs = FakeSharedPreferences()
        migrationPrefs = FakeSharedPreferences()
        aesKey = FlutterSecureStorageFixture.generateAesKey()
        targetStore = RecordStore(targetPrefs, defaultServerUrl = "https://pux.vidur.xyz")

        val editor = dataPrefs.edit()
        for ((key, value) in enrollmentValues) {
            editor.putString(
                FlutterSecureStorageMigrator.FLUTTER_PREFIX + key,
                FlutterSecureStorageFixture.encrypt(value, aesKey)
            )
        }
        editor.commit()

        val baseContext = ApplicationProvider.getApplicationContext<Context>()
        testContext = object : ContextWrapper(baseContext) {
            override fun getPackageName(): String = "xyz.vidur.pux"
            override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences {
                return when (name) {
                    FlutterSecureStorageMigrator.FLUTTER_DATA_PREFS_NAME -> dataPrefs
                    FlutterSecureStorageMigrator.MIGRATION_PREFS_NAME -> migrationPrefs
                    else -> super.getSharedPreferences(name, mode)
                }
            }
        }
    }

    @Test
    fun migratesAllFlutterRecordStoreKeysFromFixture() {
        assertFalse(targetStore.isEnrolled())
        val unwrap: AesKeyUnwrapper = AesKeyUnwrapper { aesKey }
        val migrator = FlutterSecureStorageMigrator(testContext, targetStore, unwrap)
        val result = migrator.migrate()

        assertTrue(result is FlutterSecureStorageMigrator.MigrationResult.Success)
        assertEquals(enrollmentValues.keys, (result as FlutterSecureStorageMigrator.MigrationResult.Success).migratedKeys)
        assertTrue(targetStore.isEnrolled())
        assertEquals(enrollmentValues[RecordStore.KEY_RECORD_ID], targetStore.recordId())
        assertEquals(enrollmentValues[RecordStore.KEY_PRIVATE_KEY], targetStore.privateKey())
        assertEquals(enrollmentValues[RecordStore.KEY_PUBLIC_KEY], targetStore.publicKey())
        assertEquals(enrollmentValues[RecordStore.KEY_INBOX], targetStore.inbox())
        assertEquals(enrollmentValues[RecordStore.KEY_DEVICE_ID], targetStore.deviceId())
        assertEquals(enrollmentValues[RecordStore.KEY_SERVER_URL], targetPrefs.getString(RecordStore.KEY_SERVER_URL, null))
        assertTrue(targetStore.notificationPermissionAsked())
        assertTrue(targetStore.notificationExplainerSkipped())
        assertEquals(setOf("HIBERNATION"), targetStore.dismissedRestrictionPrompts())
    }

    @Test
    fun metadataOnlyLegacyRunsThroughMigrate() {
        dataPrefs.edit().clear().commit()
        dataPrefs.edit()
            .putString(
                FlutterSecureStorageMigrator.FLUTTER_PREFIX + RecordStore.KEY_NOTIFICATION_PERMISSION_ASKED,
                FlutterSecureStorageFixture.encrypt("true", aesKey)
            )
            .commit()
        assertFalse(FlutterSecureStorageMigrator.hasLegacyEnrollmentEntries(testContext))
        assertTrue(FlutterSecureStorageMigrator.hasLegacyMigratableEntries(testContext))

        val unwrap: AesKeyUnwrapper = AesKeyUnwrapper { aesKey }
        val migrator = FlutterSecureStorageMigrator(testContext, targetStore, unwrap)
        val result = migrator.migrate()

        assertTrue(result is FlutterSecureStorageMigrator.MigrationResult.NotNeeded)
        assertTrue(targetStore.notificationPermissionAsked())
        assertTrue(FlutterSecureStorageMigrator.isMigrationCompleted(testContext))
        assertFalse(FlutterSecureStorageMigrator.hasLegacyMigratableEntries(testContext))
    }

    @Test
    fun metadataOnlyPreservesDismissedRestrictionPrompts() {
        dataPrefs.edit().clear().commit()
        dataPrefs.edit()
            .putString(
                FlutterSecureStorageMigrator.FLUTTER_PREFIX + RecordStore.KEY_DISMISSED_RESTRICTIONS,
                FlutterSecureStorageFixture.encrypt("HIBERNATION,BATTERY_SAVER", aesKey)
            )
            .commit()
        val unwrap: AesKeyUnwrapper = AesKeyUnwrapper { aesKey }
        val migrator = FlutterSecureStorageMigrator(testContext, targetStore, unwrap)
        val result = migrator.migrate()
        assertTrue(result is FlutterSecureStorageMigrator.MigrationResult.NotNeeded)
        assertEquals(setOf("HIBERNATION", "BATTERY_SAVER"), targetStore.dismissedRestrictionPrompts())
    }

    @Test
    fun reconcileMergesDismissedPromptsFromLegacy() {
        targetStore.saveDismissedRestrictionPrompts(setOf("BATTERY_SAVER"))
        targetStore.saveEnrollment(
            mapOf(
                "v" to 1,
                "record_id" to enrollmentValues[RecordStore.KEY_RECORD_ID]!!,
                "public_key" to enrollmentValues[RecordStore.KEY_PUBLIC_KEY]!!,
                "private_key" to enrollmentValues[RecordStore.KEY_PRIVATE_KEY]!!,
                "inbox" to enrollmentValues[RecordStore.KEY_INBOX]!!,
            )
        )
        val unwrap: AesKeyUnwrapper = AesKeyUnwrapper { aesKey }
        val migrator = FlutterSecureStorageMigrator(testContext, targetStore, unwrap)
        val result = migrator.migrate()
        assertTrue(result is FlutterSecureStorageMigrator.MigrationResult.Success)
        assertEquals(setOf("BATTERY_SAVER", "HIBERNATION"), targetStore.dismissedRestrictionPrompts())
    }

    @Test
    fun reconcileFailsWhenLegacyPublicKeyDiffersFromNative() {
        val otherKeys = xyz.vidur.pux.crypto.PuxCrypto.generateKeyPair()
        targetStore.saveEnrollment(
            mapOf(
                "v" to 1,
                "record_id" to enrollmentValues[RecordStore.KEY_RECORD_ID]!!,
                "public_key" to otherKeys.publicKeyB64,
                "private_key" to enrollmentValues[RecordStore.KEY_PRIVATE_KEY]!!,
                "inbox" to enrollmentValues[RecordStore.KEY_INBOX]!!,
            )
        )
        val unwrap: AesKeyUnwrapper = AesKeyUnwrapper { aesKey }
        val migrator = FlutterSecureStorageMigrator(testContext, targetStore, unwrap)
        val result = migrator.migrate()

        assertTrue(result is FlutterSecureStorageMigrator.MigrationResult.Failed)
        val failed = result as FlutterSecureStorageMigrator.MigrationResult.Failed
        assertEquals(FlutterSecureStorageMigrator.FAILURE_PUBLIC_KEY_MISMATCH, failed.reason)
        assertTrue(dataPrefs.contains(FlutterSecureStorageMigrator.FLUTTER_PREFIX + RecordStore.KEY_RECORD_ID))
    }

    @Test
    fun partialLegacyEnrollmentKeyDoesNotTakeMetadataOnlyPath() {
        dataPrefs.edit().clear().commit()
        dataPrefs.edit()
            .putString(
                FlutterSecureStorageMigrator.FLUTTER_PREFIX + RecordStore.KEY_RECORD_ID,
                FlutterSecureStorageFixture.encrypt(
                    enrollmentValues[RecordStore.KEY_RECORD_ID]!!,
                    aesKey
                )
            )
            .commit()
        val unwrap: AesKeyUnwrapper = AesKeyUnwrapper { aesKey }
        val migrator = FlutterSecureStorageMigrator(testContext, targetStore, unwrap)
        val result = migrator.migrate()

        assertTrue(result is FlutterSecureStorageMigrator.MigrationResult.Failed)
        assertFalse(targetStore.isEnrolled())
    }

    @Test
    fun reconcilesInterruptedMigrationWhenNativeAlreadyEnrolled() {
        targetStore.saveEnrollment(
            mapOf(
                "v" to 1,
                "record_id" to enrollmentValues[RecordStore.KEY_RECORD_ID]!!,
                "public_key" to enrollmentValues[RecordStore.KEY_PUBLIC_KEY]!!,
                "private_key" to enrollmentValues[RecordStore.KEY_PRIVATE_KEY]!!,
                "inbox" to enrollmentValues[RecordStore.KEY_INBOX]!!,
            )
        )
        val unwrap: AesKeyUnwrapper = AesKeyUnwrapper { aesKey }
        val migrator = FlutterSecureStorageMigrator(testContext, targetStore, unwrap)
        val result = migrator.migrate()

        assertTrue(result is FlutterSecureStorageMigrator.MigrationResult.Success)
        assertTrue(FlutterSecureStorageMigrator.isMigrationCompleted(testContext))
        assertEquals(setOf("HIBERNATION"), targetStore.dismissedRestrictionPrompts())
        assertTrue(targetStore.notificationExplainerSkipped())
    }
}
