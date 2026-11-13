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
class MigrationRecoveryTest {
    private lateinit var testContext: Context

    @Before fun setUp() {
        val migrationPrefs = FakeSharedPreferences()
        val base = ApplicationProvider.getApplicationContext<Context>()
        testContext = object : ContextWrapper(base) {
            override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences = when (name) {
                FlutterSecureStorageMigrator.MIGRATION_PREFS_NAME -> migrationPrefs
                else -> super.getSharedPreferences(name, mode)
            }
        }
    }

    @Test fun metadataOnlyNotNeededCountsAsRecoveredWhenTombstoneSet() {
        FlutterSecureStorageMigrator.setMigrationCompleted(testContext)
        assertTrue(
            MigrationRecovery.succeeded(
                testContext,
                FlutterSecureStorageMigrator.MigrationResult.NotNeeded
            )
        )
    }

    @Test fun failedResultIsNotRecovered() {
        assertFalse(
            MigrationRecovery.succeeded(
                testContext,
                FlutterSecureStorageMigrator.MigrationResult.Failed("boom")
            )
        )
    }
}
