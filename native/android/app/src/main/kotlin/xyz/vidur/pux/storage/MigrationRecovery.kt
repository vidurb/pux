package xyz.vidur.pux.storage

import android.content.Context

object MigrationRecovery {
    fun succeeded(context: Context, result: FlutterSecureStorageMigrator.MigrationResult): Boolean {
        return when (result) {
            is FlutterSecureStorageMigrator.MigrationResult.Success -> true
            is FlutterSecureStorageMigrator.MigrationResult.NotNeeded ->
                !FlutterSecureStorageMigrator.isLegacyCleanupPending(context) && (
                    FlutterSecureStorageMigrator.isMigrationCompleted(context) ||
                        !FlutterSecureStorageMigrator.hasLegacyMigratableEntries(context)
                )
            is FlutterSecureStorageMigrator.MigrationResult.Failed -> false
        }
    }
}
