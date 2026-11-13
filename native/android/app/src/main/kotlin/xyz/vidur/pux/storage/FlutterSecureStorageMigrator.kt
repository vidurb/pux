package xyz.vidur.pux.storage

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import android.util.Log
import java.nio.charset.StandardCharsets
import java.security.Key
import java.security.KeyStore
import java.security.spec.MGF1ParameterSpec
import java.util.Arrays
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource

/**
 * Migrates stored enrollment data from Flutter secure-storage (legacy flutter_secure_storage format).
 *
 * In flutter_secure_storage 11.2.0:
 * - Data SharedPreferences: "FlutterSecureStorage"
 * - Key Storage SharedPreferences: "FlutterSecureKeyStorage" (fallback: "FlutterSecureStorage")
 * - Wrapped AES key preference: "AESVGhpcyBpcyB0aGUga2V5IGZvciBhIHNlY3VyZSBzdG9yYWdlIEFFUyBLZXkK"
 * - AndroidKeyStore RSA-OAEP alias: "${context.packageName}.FlutterSecureStoragePluginKeyOAEP"
 * - Data key prefix: "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg_"
 * - Cipher: RSA/ECB/OAEPwithSHA-256andMGF1Padding for key unwrap, AES/GCM/NoPadding (12-byte IV) for values.
 *
 * Migration invariants:
 * - Never deletes or overwrites existing native enrollment if already enrolled.
 * - If migration fails (e.g. unwrap fails or Keystore key unavailable), preserves legacy data
 *   intact and returns [MigrationResult.Failed] so the user can be safely prompted.
 * - Migrates existing device ID and notification permission state.
 */
fun interface AesKeyUnwrapper {
    fun unwrapAesKey(context: Context): Key
}

class FlutterSecureStorageMigrator(
    private val context: Context,
    private val targetStore: RecordStore,
    private val aesKeyUnwrapper: AesKeyUnwrapper? = null
) {
    sealed class MigrationResult {
        data object NotNeeded : MigrationResult()
        data class Success(val migratedKeys: Set<String>) : MigrationResult()
        data class Failed(val reason: String, val cause: Throwable? = null) : MigrationResult()
    }

    fun migrate(): MigrationResult {
        if (isLegacyCleanupPending(context)) {
            return resumeLegacyCleanup()
        }
        if (isMigrationCompleted(context)) {
            return MigrationResult.NotNeeded
        }
        if (!hasLegacyMigratableEntries(context)) {
            return MigrationResult.NotNeeded
        }
        if (targetStore.isEnrolled()) {
            return when (val outcome = reconcileLegacyWithCurrentEnrollment()) {
                ReconcileOutcome.Reconciled ->
                    MigrationResult.Success(setOf("reconciled_legacy"))
                ReconcileOutcome.NoLegacyRemaining ->
                    MigrationResult.NotNeeded
                ReconcileOutcome.IncompleteLegacyEnrollment ->
                    MigrationResult.Failed(FAILURE_INCOMPLETE_LEGACY)
                ReconcileOutcome.RecordIdMismatch ->
                    MigrationResult.Failed(FAILURE_RECORD_ID_MISMATCH)
                ReconcileOutcome.PublicKeyMismatch ->
                    MigrationResult.Failed(FAILURE_PUBLIC_KEY_MISMATCH)
                ReconcileOutcome.PrivateKeyMismatch ->
                    MigrationResult.Failed(FAILURE_PRIVATE_KEY_MISMATCH)
                is ReconcileOutcome.PersistenceFailure ->
                    MigrationResult.Failed(
                        "$FAILURE_LEGACY_PERSISTENCE_PREFIX${outcome.cause.message}",
                        outcome.cause
                    )
            }
        }

        val dataPrefs = context.getSharedPreferences(FLUTTER_DATA_PREFS_NAME, Context.MODE_PRIVATE)
        val allEntries = dataPrefs.all
        val matchingEntries = allEntries.filterKeys { it.startsWith(FLUTTER_PREFIX) }

        Log.i(TAG, "Found legacy FlutterSecureStorage data with ${matchingEntries.size} entries. Attempting migration...")

        return try {
            val decryptedData = try {
                decryptAllFlutterEntries(dataPrefs, matchingEntries)
            } catch (e: Exception) {
                return MigrationResult.Failed("$FAILURE_DECRYPT_PREFIX${e.message}", e)
            }
            val enrollmentKeys = setOf(
                RecordStore.KEY_RECORD_ID,
                RecordStore.KEY_PRIVATE_KEY,
                RecordStore.KEY_PUBLIC_KEY
            )
            val hasFullEnrollment = enrollmentKeys.all { decryptedData.containsKey(it) }
            if (!hasFullEnrollment) {
                if (decryptedData.keys.any { it in enrollmentKeys }) {
                    return MigrationResult.Failed("Incomplete legacy enrollment found in FlutterSecureStorage")
                }
                if (applyMetadataOnlyMigration(decryptedData)) {
                    return MigrationResult.NotNeeded
                }
                return MigrationResult.Failed("Incomplete legacy enrollment found in FlutterSecureStorage")
            }

            val payload = mutableMapOf<String, Any?>(
                "v" to 1,
                "record_id" to decryptedData[RecordStore.KEY_RECORD_ID],
                "private_key" to decryptedData[RecordStore.KEY_PRIVATE_KEY],
                "public_key" to decryptedData[RecordStore.KEY_PUBLIC_KEY],
                "inbox" to (decryptedData[RecordStore.KEY_INBOX] ?: "unknown@pux"),
                "server" to (decryptedData[RecordStore.KEY_SERVER_URL] ?: targetStore.defaultServerUrl)
            )
            decryptedData[RecordStore.KEY_DEVICE_ID]?.let { payload["device_id"] = it }
            payload["notification_permission_asked"] = decryptedData[RecordStore.KEY_NOTIFICATION_PERMISSION_ASKED] == "true"

            targetStore.saveEnrollment(payload)
            persistLegacyMetadataThenClear(decryptedData)

            // Durably purge legacy storage entries and mark migration completed to prevent resurrection

            Log.i(TAG, "Successfully migrated FlutterSecureStorage enrollment to native Keystore storage.")
            MigrationResult.Success(decryptedData.keys)
        } catch (e: Exception) {
            Log.e(TAG, "FlutterSecureStorage migration failed: ${e.message}", e)
            MigrationResult.Failed("$FAILURE_LEGACY_PERSISTENCE_PREFIX${e.message}", e)
        }
    }

    private fun resumeLegacyCleanup(): MigrationResult {
        return try {
            if (hasLegacyMigratableEntries(context)) {
                clearLegacyFlutterEntries(context)
            }
            finishMigration(context)
            MigrationResult.Success(setOf("legacy_cleanup_resumed"))
        } catch (e: Exception) {
            MigrationResult.Failed("$FAILURE_LEGACY_PERSISTENCE_PREFIX${e.message}", e)
        }
    }

    /**
     * When legacy storage only has non-enrollment flags (e.g. notification_permission_asked),
     * migrate those flags and clear legacy data without treating the outcome as a migration failure.
     */
    private sealed class ReconcileOutcome {
        data object Reconciled : ReconcileOutcome()
        data object NoLegacyRemaining : ReconcileOutcome()
        data object IncompleteLegacyEnrollment : ReconcileOutcome()
        data object RecordIdMismatch : ReconcileOutcome()
        data object PublicKeyMismatch : ReconcileOutcome()
        data object PrivateKeyMismatch : ReconcileOutcome()
        data class PersistenceFailure(val cause: Exception) : ReconcileOutcome()
    }

    /** Native enrollment already saved but legacy Flutter ciphertext remained (interrupted migration). */
    private fun reconcileLegacyWithCurrentEnrollment(): ReconcileOutcome {
        val recordId = targetStore.recordId() ?: return ReconcileOutcome.NoLegacyRemaining
        val dataPrefs = context.getSharedPreferences(FLUTTER_DATA_PREFS_NAME, Context.MODE_PRIVATE)
        val matchingEntries = dataPrefs.all.filterKeys { it.startsWith(FLUTTER_PREFIX) }
        if (matchingEntries.isEmpty()) return ReconcileOutcome.NoLegacyRemaining
        return try {
            val decrypted = decryptAllFlutterEntries(dataPrefs, matchingEntries)
            val enrollmentKeys = setOf(
                RecordStore.KEY_RECORD_ID,
                RecordStore.KEY_PRIVATE_KEY,
                RecordStore.KEY_PUBLIC_KEY
            )
            val legacyEnrollmentPresent = decrypted.keys.any { it in enrollmentKeys }
            if (legacyEnrollmentPresent) {
                if (!enrollmentKeys.all { decrypted.containsKey(it) }) {
                    return ReconcileOutcome.IncompleteLegacyEnrollment
                }
                if (decrypted[RecordStore.KEY_RECORD_ID] != recordId) {
                    return ReconcileOutcome.RecordIdMismatch
                }
                val nativePublic = targetStore.publicKey()
                val nativePrivate = targetStore.privateKey()
                if (nativePublic != null && decrypted[RecordStore.KEY_PUBLIC_KEY] != nativePublic) {
                    return ReconcileOutcome.PublicKeyMismatch
                }
                if (nativePrivate != null && decrypted[RecordStore.KEY_PRIVATE_KEY] != nativePrivate) {
                    return ReconcileOutcome.PrivateKeyMismatch
                }
            }
            persistLegacyMetadataThenClear(decrypted)
            ReconcileOutcome.Reconciled
        } catch (e: Exception) {
            ReconcileOutcome.PersistenceFailure(e)
        }
    }

    internal fun applyLegacyMetadata(decryptedData: Map<String, String>) {
        if (decryptedData[RecordStore.KEY_NOTIFICATION_PERMISSION_ASKED] == "true") {
            targetStore.saveNotificationPermissionAsked()
        }
        if (decryptedData[RecordStore.KEY_NOTIFICATION_EXPLAINER_SKIPPED] == "true") {
            targetStore.saveNotificationExplainerSkipped()
        }
        decryptedData[RecordStore.KEY_DISMISSED_RESTRICTIONS]?.takeIf { it.isNotEmpty() }?.let { stored ->
            val merged = targetStore.dismissedRestrictionPrompts() +
                stored.split(",").filter { it.isNotEmpty() }
            targetStore.saveDismissedRestrictionPrompts(merged)
        }
    }

    internal fun applyMetadataOnlyMigration(decryptedData: Map<String, String>): Boolean {
        if (decryptedData.isEmpty()) return false
        val allowed = setOf(
            RecordStore.KEY_NOTIFICATION_PERMISSION_ASKED,
            RecordStore.KEY_NOTIFICATION_EXPLAINER_SKIPPED,
            RecordStore.KEY_DISMISSED_RESTRICTIONS
        )
        if (!decryptedData.keys.all { it in allowed }) return false

        persistLegacyMetadataThenClear(decryptedData)
        Log.i(TAG, "Migrated legacy Flutter metadata only (no enrollment).")
        return true
    }

    internal fun persistLegacyMetadataThenClear(decryptedData: Map<String, String>) {
        applyLegacyMetadata(decryptedData)
        markLegacyCleanupPending(context)
        clearLegacyFlutterEntries(context)
        finishMigration(context)
    }

    private fun decryptAllFlutterEntries(
        dataPrefs: SharedPreferences,
        matchingEntries: Map<String, *>
    ): Map<String, String> {
        val aesKey = unwrapAesKey()
        val results = mutableMapOf<String, String>()

        for ((prefixedKey, rawVal) in matchingEntries) {
            if (rawVal !is String) continue
            val realKey = prefixedKey.removePrefix(FLUTTER_PREFIX)
            val decrypted = decryptValue(rawVal, aesKey)
            results[realKey] = decrypted
        }
        return results
    }

    private fun unwrapAesKey(): Key {
        aesKeyUnwrapper?.let { return it.unwrapAesKey(context) }
        // flutter_secure_storage 11 stores wrapped key in FlutterSecureKeyStorage (or FlutterSecureStorage fallback)
        val keyPrefs = context.getSharedPreferences(FLUTTER_KEY_PREFS_NAME, Context.MODE_PRIVATE)
        var wrappedKeyB64 = keyPrefs.getString(FLUTTER_WRAPPED_KEY_PREF, null)

        if (wrappedKeyB64 == null) {
            val fallbackPrefs = context.getSharedPreferences(FLUTTER_DATA_PREFS_NAME, Context.MODE_PRIVATE)
            wrappedKeyB64 = fallbackPrefs.getString(FLUTTER_WRAPPED_KEY_PREF, null)
        }

        if (wrappedKeyB64 == null) {
            throw IllegalStateException("Missing wrapped AES key in Flutter secure storage preferences")
        }

        val wrappedBytes = Base64.decode(wrappedKeyB64, Base64.DEFAULT)

        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val rsaAlias = "${context.packageName}.$FLUTTER_KEYSTORE_ALIAS_SUFFIX"
        val fallbackAlias = "${context.packageName}.$FLUTTER_KEYSTORE_LEGACY_SUFFIX"

        val rsaPrivateKey = (keyStore.getKey(rsaAlias, null)
            ?: keyStore.getKey(fallbackAlias, null)
            ?: keyStore.getKey(FLUTTER_KEYSTORE_ALIAS_SUFFIX, null)
            ?: keyStore.getKey(FLUTTER_WRAPPED_KEY_PREF, null))
            ?: throw IllegalStateException("AndroidKeyStore entry '$rsaAlias' not found")

        val rsaCipher = Cipher.getInstance("RSA/ECB/OAEPwithSHA-256andMGF1Padding")
        val oaepSpec = OAEPParameterSpec(
            "SHA-256",
            "MGF1",
            MGF1ParameterSpec.SHA1,
            PSource.PSpecified.DEFAULT
        )
        rsaCipher.init(Cipher.UNWRAP_MODE, rsaPrivateKey, oaepSpec)
        return rsaCipher.unwrap(wrappedBytes, "AES", Cipher.SECRET_KEY)
    }

    private fun decryptValue(b64Value: String, aesKey: Key): String {
        val encrypted = Base64.decode(b64Value, Base64.DEFAULT)
        if (encrypted.size < GCM_IV_SIZE + 16) {
            throw IllegalArgumentException("Encrypted value too short for AES-GCM")
        }

        val iv = Arrays.copyOfRange(encrypted, 0, GCM_IV_SIZE)
        val ciphertext = Arrays.copyOfRange(encrypted, GCM_IV_SIZE, encrypted.size)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val spec = GCMParameterSpec(GCM_TAG_SIZE, iv)
        cipher.init(Cipher.DECRYPT_MODE, aesKey, spec)
        val plaintext = cipher.doFinal(ciphertext)
        return String(plaintext, StandardCharsets.UTF_8)
    }

    companion object {
        const val FAILURE_INCOMPLETE_LEGACY =
            "Incomplete legacy enrollment remains in Flutter secure storage."
        const val FAILURE_RECORD_ID_MISMATCH =
            "Legacy Flutter data belongs to a different relay than the enrollment on this phone."
        const val FAILURE_PUBLIC_KEY_MISMATCH =
            "Legacy Flutter public key does not match the enrollment saved on this phone."
        const val FAILURE_PRIVATE_KEY_MISMATCH =
            "Legacy Flutter private key does not match the enrollment saved on this phone."
        const val FAILURE_LEGACY_PERSISTENCE_PREFIX =
            "Could not finish migrating legacy preferences: "
        const val FAILURE_DECRYPT_PREFIX =
            "Could not decrypt legacy Flutter secure storage: "
        const val KEY_LEGACY_CLEANUP_PENDING = "legacy_cleanup_pending"
        private const val TAG = "FSSMigrator"
        const val FLUTTER_DATA_PREFS_NAME = "FlutterSecureStorage"
        const val FLUTTER_KEY_PREFS_NAME = "FlutterSecureKeyStorage"
        const val MIGRATION_PREFS_NAME = "pux_migration_state"
        const val KEY_MIGRATION_COMPLETED = "migration_completed"
        const val KEY_FORGET_PENDING = "forget_pending"
        const val FLUTTER_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg_"
        const val FLUTTER_WRAPPED_KEY_PREF = "AESVGhpcyBpcyB0aGUga2V5IGZvciBhIHNlY3VyZSBzdG9yYWdlIEFFUyBLZXkK"
        const val FLUTTER_KEYSTORE_ALIAS_SUFFIX = "FlutterSecureStoragePluginKeyOAEP"
        const val FLUTTER_KEYSTORE_LEGACY_SUFFIX = "FlutterSecureStoragePluginKey"
        const val GCM_IV_SIZE = 12
        const val GCM_TAG_SIZE = 128

        fun hasLegacyEnrollmentEntries(context: Context): Boolean {
            val dataPrefs = context.getSharedPreferences(FLUTTER_DATA_PREFS_NAME, Context.MODE_PRIVATE)
            val enrollmentKeys = listOf(
                RecordStore.KEY_RECORD_ID,
                RecordStore.KEY_PRIVATE_KEY,
                RecordStore.KEY_PUBLIC_KEY
            )
            return enrollmentKeys.any { dataPrefs.contains(FLUTTER_PREFIX + it) }
        }

        /** Legacy Flutter prefs with enrollment and/or migrate-able metadata flags. */
        fun hasLegacyMigratableEntries(context: Context): Boolean {
            val dataPrefs = context.getSharedPreferences(FLUTTER_DATA_PREFS_NAME, Context.MODE_PRIVATE)
            val keys = listOf(
                RecordStore.KEY_RECORD_ID,
                RecordStore.KEY_PRIVATE_KEY,
                RecordStore.KEY_PUBLIC_KEY,
                RecordStore.KEY_INBOX,
                RecordStore.KEY_SERVER_URL,
                RecordStore.KEY_DEVICE_ID,
                RecordStore.KEY_NOTIFICATION_PERMISSION_ASKED,
                RecordStore.KEY_NOTIFICATION_EXPLAINER_SKIPPED,
                RecordStore.KEY_DISMISSED_RESTRICTIONS
            )
            return keys.any { dataPrefs.contains(FLUTTER_PREFIX + it) }
        }

        fun isMigrationCompleted(context: Context): Boolean {
            return context.getSharedPreferences(MIGRATION_PREFS_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_MIGRATION_COMPLETED, false)
        }

        fun setMigrationCompleted(context: Context): Boolean {
            return context.getSharedPreferences(MIGRATION_PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_MIGRATION_COMPLETED, true)
                .commit()
        }

        fun beginForget(context: Context) {
            check(context.getSharedPreferences(MIGRATION_PREFS_NAME, Context.MODE_PRIVATE).edit()
                .putBoolean(KEY_MIGRATION_COMPLETED, true)
                .putBoolean(KEY_FORGET_PENDING, true).commit()) { "Could not persist forget request" }
            RecordStore.enrollmentBlocked = true
        }

        fun isForgetPending(context: Context): Boolean =
            context.getSharedPreferences(MIGRATION_PREFS_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_FORGET_PENDING, false)

        fun finishForget(context: Context) {
            check(context.getSharedPreferences(MIGRATION_PREFS_NAME, Context.MODE_PRIVATE).edit()
                .remove(KEY_FORGET_PENDING).commit()) { "Could not complete forget request" }
            RecordStore.enrollmentBlocked = false
        }

        fun isLegacyCleanupPending(context: Context): Boolean =
            context.getSharedPreferences(MIGRATION_PREFS_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_LEGACY_CLEANUP_PENDING, false)

        fun markLegacyCleanupPending(context: Context) {
            check(
                context.getSharedPreferences(MIGRATION_PREFS_NAME, Context.MODE_PRIVATE).edit()
                    .putBoolean(KEY_LEGACY_CLEANUP_PENDING, true)
                    .commit()
            ) { "Could not persist legacy cleanup state" }
        }

        fun clearLegacyFlutterEntries(context: Context) {
            val editor = context.getSharedPreferences(FLUTTER_DATA_PREFS_NAME, Context.MODE_PRIVATE).edit()
            listOf(
                RecordStore.KEY_RECORD_ID, RecordStore.KEY_PRIVATE_KEY, RecordStore.KEY_PUBLIC_KEY,
                RecordStore.KEY_INBOX, RecordStore.KEY_SERVER_URL, RecordStore.KEY_DEVICE_ID,
                RecordStore.KEY_NOTIFICATION_PERMISSION_ASKED, RecordStore.KEY_NOTIFICATION_EXPLAINER_SKIPPED,
                RecordStore.KEY_DISMISSED_RESTRICTIONS
            ).forEach { editor.remove(FLUTTER_PREFIX + it) }
            check(editor.commit()) { "Could not clear legacy enrollment" }
        }

        fun finishMigration(context: Context) {
            check(
                context.getSharedPreferences(MIGRATION_PREFS_NAME, Context.MODE_PRIVATE).edit()
                    .remove(KEY_LEGACY_CLEANUP_PENDING)
                    .putBoolean(KEY_MIGRATION_COMPLETED, true)
                    .commit()
            ) { "Could not persist migration marker" }
        }

        fun clearLegacyData(context: Context): Boolean {
            if (hasLegacyMigratableEntries(context)) {
                clearLegacyFlutterEntries(context)
            }
            if (isLegacyCleanupPending(context) || hasLegacyMigratableEntries(context)) {
                finishMigration(context)
            } else {
                check(setMigrationCompleted(context)) { "Could not persist migration marker" }
            }
            return true
        }
    }
}
