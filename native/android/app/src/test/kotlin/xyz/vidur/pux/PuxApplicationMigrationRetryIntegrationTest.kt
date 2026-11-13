package xyz.vidur.pux

import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.storage.FlutterSecureStorageFixture
import xyz.vidur.pux.storage.FlutterSecureStorageMigrator
import xyz.vidur.pux.storage.MigrationRecovery
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.testutil.FakeSharedPreferences

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34])
class PuxApplicationMigrationRetryIntegrationTest {
    @Test fun retryTreatsCompletedMetadataOnlyAsRecovered() {
        val migrationPrefs = FakeSharedPreferences()
        val dataPrefs = FakeSharedPreferences()
        val aesKey = FlutterSecureStorageFixture.generateAesKey()
        dataPrefs.edit()
            .putString(
                FlutterSecureStorageMigrator.FLUTTER_PREFIX + RecordStore.KEY_NOTIFICATION_PERMISSION_ASKED,
                FlutterSecureStorageFixture.encrypt("true", aesKey)
            )
            .commit()
        val base = ApplicationProvider.getApplicationContext<Context>()
        val wrapped = object : ContextWrapper(base) {
            override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences = when (name) {
                FlutterSecureStorageMigrator.MIGRATION_PREFS_NAME -> migrationPrefs
                FlutterSecureStorageMigrator.FLUTTER_DATA_PREFS_NAME -> dataPrefs
                else -> super.getSharedPreferences(name, mode)
            }
        }
        val store = RecordStore(FakeSharedPreferences())
        val migrator = FlutterSecureStorageMigrator(wrapped, store, { aesKey })
        val result = migrator.migrate()
        assertTrue(result is FlutterSecureStorageMigrator.MigrationResult.NotNeeded)
        assertTrue(MigrationRecovery.succeeded(wrapped, result))
        assertTrue(store.notificationPermissionAsked())
    }
}
