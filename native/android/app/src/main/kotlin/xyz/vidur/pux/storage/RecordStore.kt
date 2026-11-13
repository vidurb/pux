package xyz.vidur.pux.storage

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONObject
import xyz.vidur.pux.crypto.PuxCrypto
import java.util.Locale
import java.util.regex.Pattern

/**
 * Android Keystore-backed secure storage for relay credentials, keys, and device state.
 *
 * Preserves exact wire and storage semantics from the Flutter client's RecordStore:
 * - Atomic write order: inbox, server_url, public_key, private_key, record_id last.
 * - Cleanup rollback on partial write failure.
 * - [clear] forgets relay keys and prompts, but preserves [notificationPermissionAsked].
 * - Rigorous validation of UUIDs, 32-byte base64url keys, and HTTPS server URLs.
 */
open class RecordStore(
    private val preferences: SharedPreferences?,
    var defaultServerUrl: String = DEFAULT_SERVER_URL,
    val failureReason: Exception? = null
) {
    var serverUrl: String = defaultServerUrl
        private set

    init {
        val stored = preferences?.getString(KEY_SERVER_URL, null)
        serverUrl = if (!stored.isNullOrEmpty()) stored else defaultServerUrl
    }

    open fun isEnrolled(): Boolean {
        if (failureReason != null) return false
        val recordId = recordId()
        val privateKey = privateKey()
        val publicKey = publicKey()
        return !recordId.isNullOrEmpty() && !privateKey.isNullOrEmpty() && !publicKey.isNullOrEmpty()
    }

    fun recordId(): String? = preferences?.getString(KEY_RECORD_ID, null)
    fun privateKey(): String? = preferences?.getString(KEY_PRIVATE_KEY, null)
    fun publicKey(): String? = preferences?.getString(KEY_PUBLIC_KEY, null)
    fun inbox(): String? = preferences?.getString(KEY_INBOX, null)
    fun deviceId(): String? = preferences?.getString(KEY_DEVICE_ID, null)

    fun saveDeviceId(deviceId: String?) {
        if (deviceId.isNullOrEmpty()) return
        val prefs = requireNotNull(preferences) { "Encrypted storage unavailable" }
        check(prefs.edit().putString(KEY_DEVICE_ID, deviceId).commit()) { "Could not save device registration" }
    }

    /** Persist before sending, so a crash or lost response cannot be mistaken for no registration. */
    fun beginDeviceRegistration(): Boolean {
        val prefs = requireNotNull(preferences) { "Encrypted storage unavailable" }
        val alreadyUncertain = prefs.getBoolean(KEY_REGISTRATION_UNCERTAIN, false)
        check(prefs.edit().putBoolean(KEY_REGISTRATION_UNCERTAIN, true).commit()) {
            "Could not persist registration state"
        }
        return alreadyUncertain
    }

    fun finishDeviceRegistration(deviceId: String?, alreadyUncertain: Boolean) {
        require(!deviceId.isNullOrEmpty()) { "Server returned no device ID" }
        val prefs = requireNotNull(preferences) { "Encrypted storage unavailable" }
        val editor = prefs.edit()
            .putString(KEY_DEVICE_ID, deviceId)
            .remove(KEY_REGISTRATION_UNCERTAIN)
        if (alreadyUncertain) {
            editor.putBoolean(KEY_STALE_REGISTRATION_POSSIBLE, true)
        }
        check(editor.commit()) { "Could not save device registration" }
    }

    fun rejectDeviceRegistration(alreadyUncertain: Boolean) {
        if (alreadyUncertain) return
        val prefs = requireNotNull(preferences) { "Encrypted storage unavailable" }
        check(prefs.edit().remove(KEY_REGISTRATION_UNCERTAIN).commit()) {
            "Could not persist rejected registration state"
        }
    }

    fun registrationUncertain(): Boolean = preferences?.getBoolean(KEY_REGISTRATION_UNCERTAIN, false) ?: true

    fun staleRegistrationPossible(): Boolean =
        preferences?.getBoolean(KEY_STALE_REGISTRATION_POSSIBLE, false) ?: false

    fun clearStaleRegistrationPossible() {
        val prefs = requireNotNull(preferences) { "Encrypted storage unavailable" }
        check(prefs.edit().remove(KEY_STALE_REGISTRATION_POSSIBLE).commit()) {
            "Could not clear stale registration marker"
        }
    }

    fun pendingRemoteRemoval(): String? = preferences?.getString(KEY_PENDING_REMOTE_REMOVAL, null)

    fun beginRemoteRemoval(action: String) {
        require(action == "remove_device" || action == "delete_relay")
        val prefs = requireNotNull(preferences) { "Encrypted storage unavailable" }
        val existing = pendingRemoteRemoval()
        check(existing == null || existing == action) { "Another removal is already pending" }
        check(
            prefs.edit()
                .putString(KEY_PENDING_REMOTE_REMOVAL, action)
                .remove(KEY_PENDING_REMOVAL_SERVER_UNREACHABLE)
                .commit()
        ) {
            "Could not persist removal request"
        }
    }

    fun markPendingRemovalServerUnreachable() {
        val prefs = requireNotNull(preferences) { "Encrypted storage unavailable" }
        check(prefs.edit().putBoolean(KEY_PENDING_REMOVAL_SERVER_UNREACHABLE, true).commit()) {
            "Could not persist pending removal reachability"
        }
    }

    fun pendingRemovalServerUnreachable(): Boolean =
        preferences?.getBoolean(KEY_PENDING_REMOVAL_SERVER_UNREACHABLE, false) ?: false

    fun clearPendingRemoteRemoval() {
        val prefs = requireNotNull(preferences) { "Encrypted storage unavailable" }
        check(
            prefs.edit()
                .remove(KEY_PENDING_REMOTE_REMOVAL)
                .remove(KEY_PENDING_REMOVAL_SERVER_UNREACHABLE)
                .commit()
        ) {
            "Could not clear pending removal"
        }
    }

    fun dismissedRestrictionPrompts(): Set<String> {
        val stored = preferences?.getString(KEY_DISMISSED_RESTRICTIONS, null)
        if (stored.isNullOrEmpty()) return emptySet()
        return stored.split(",").filter { it.isNotEmpty() }.toSet()
    }

    fun saveDismissedRestrictionPrompts(names: Set<String>) {
        val prefs = requireNotNull(preferences) { "Encrypted storage unavailable" }
        check(prefs.edit().putString(KEY_DISMISSED_RESTRICTIONS, names.joinToString(",")).commit()) {
            "Could not save dismissed restriction prompts"
        }
    }

    fun notificationPermissionAsked(): Boolean {
        return preferences?.getString(KEY_NOTIFICATION_PERMISSION_ASKED, null) == "true"
    }

    fun saveNotificationPermissionAsked() {
        val prefs = requireNotNull(preferences) { "Encrypted storage unavailable" }
        check(prefs.edit().putString(KEY_NOTIFICATION_PERMISSION_ASKED, "true").commit()) {
            "Could not save notification permission preference"
        }
    }

    fun notificationExplainerSkipped(): Boolean {
        return preferences?.getString(KEY_NOTIFICATION_EXPLAINER_SKIPPED, null) == "true"
    }

    fun saveNotificationExplainerSkipped() {
        val prefs = requireNotNull(preferences) { "Encrypted storage unavailable" }
        check(prefs.edit().putString(KEY_NOTIFICATION_EXPLAINER_SKIPPED, "true").commit()) {
            "Could not save notification explainer preference"
        }
    }

    /**
     * Atomically saves an enrollment payload.
     * The record ID is written last to ensure partial writes never appear enrolled.
     * If write fails, cleans up written keys and rethrows.
     */
    open fun saveEnrollment(payload: Map<String, Any?>) {
        if (failureReason != null) {
            throw IllegalStateException("Encrypted storage unavailable: ${failureReason.message}", failureReason)
        }
        if (enrollmentBlocked) {
            throw IllegalStateException("Cannot enroll until local forget cleanup finishes")
        }
        val prefs = requireNotNull(preferences) { "Preferences unavailable" }
        validateEnrollmentPayload(payload)
        val effectiveServer = enrollmentServer(payload)

        val inbox = payload["inbox"] as String
        val publicKey = payload["public_key"] as String
        val privateKey = payload["private_key"] as String
        val recordId = payload["record_id"] as String

        val deviceId = payload["device_id"] as? String

        val editor = prefs.edit()
        try {
            editor.putString(KEY_INBOX, inbox)
            editor.putString(KEY_SERVER_URL, effectiveServer)
            editor.putString(KEY_PUBLIC_KEY, publicKey)
            editor.putString(KEY_PRIVATE_KEY, privateKey)
            if (!deviceId.isNullOrEmpty()) {
                editor.putString(KEY_DEVICE_ID, deviceId)
            }
            if (payload["notification_permission_asked"] == true) {
                editor.putString(KEY_NOTIFICATION_PERMISSION_ASKED, "true")
            }
            editor.putString(KEY_RECORD_ID, recordId)
            val success = editor.commit()
            if (!success) {
                throw IllegalStateException("Failed to commit enrollment to secure storage")
            }
            serverUrl = effectiveServer
        } catch (e: Exception) {
            // Clean up partial keys on failure
            prefs.edit()
                .remove(KEY_INBOX)
                .remove(KEY_SERVER_URL)
                .remove(KEY_PUBLIC_KEY)
                .remove(KEY_PRIVATE_KEY)
                .remove(KEY_DEVICE_ID)
                .remove(KEY_RECORD_ID)
                .commit()
            throw e
        }
    }

    /**
     * Clears enrollment keys and dismissed prompts on this device.
     * Preserves [notificationPermissionAsked], which describes the OS state.
     * Also clears legacy Flutter secure storage if [context] is provided.
     */
    fun clear(context: Context? = null) {
        if (context != null) {
            FlutterSecureStorageMigrator.beginForget(context)
            enrollmentBlocked = true
        }
        completeForget(context)
    }

    fun completeForget(context: Context?) {
        val prefs = requireNotNull(preferences) { "Encrypted storage unavailable" }
        if (isEnrolled()) {
            val asked = notificationPermissionAsked()
            val editor = prefs.edit().clear()
            if (asked) editor.putString(KEY_NOTIFICATION_PERMISSION_ASKED, "true")
            editor.remove(KEY_PENDING_REMOTE_REMOVAL)
            editor.remove(KEY_PENDING_REMOVAL_SERVER_UNREACHABLE)
            check(editor.commit()) { "Could not clear encrypted enrollment" }
            serverUrl = defaultServerUrl
        }
        if (context != null) {
            FlutterSecureStorageMigrator.clearLegacyData(context)
            FlutterSecureStorageMigrator.finishForget(context)
            enrollmentBlocked = false
        }
    }

    fun enrollmentPayload(): Map<String, Any?> {
        return mapOf(
            "v" to 1,
            "record_id" to recordId(),
            "private_key" to privateKey(),
            "public_key" to publicKey(),
            "inbox" to inbox(),
            "server" to (preferences?.getString(KEY_SERVER_URL, null) ?: serverUrl)
        )
    }

    fun parseQr(raw: String): Map<String, Any?> {
        val json = try {
            JSONObject(raw.trim())
        } catch (e: Exception) {
            throw IllegalArgumentException("Invalid QR payload: not valid JSON", e)
        }
        if (json.optInt("v", -1) != 1) {
            throw IllegalArgumentException("Unsupported QR version: expected v=1")
        }

        val map = mutableMapOf<String, Any?>()
        val keys = listOf("record_id", "private_key", "public_key", "inbox")
        for (key in keys) {
            val value = json.optString(key, "")
            if (value.isEmpty()) {
                throw IllegalArgumentException("Missing $key in QR payload")
            }
            map[key] = value
        }
        if (json.has("server")) {
            map["server"] = json.optString("server")
        }

        validateEnrollmentPayload(map)
        return map
    }

    fun enrollmentServer(payload: Map<String, Any?>): String {
        val server = payload["server"]
        if (server == null || (server is String && server.isEmpty())) {
            return serverUrl
        }
        if (server !is String) {
            throw IllegalArgumentException("Invalid server in enrollment")
        }
        if (server == defaultServerUrl) return server
        return validateServerUrl(server)
    }

    fun validateEnrollmentPayload(payload: Map<String, Any?>) {
        val recordId = payload["record_id"]
        if (recordId !is String || !UUID_PATTERN.matcher(recordId).matches()) {
            throw IllegalArgumentException("Invalid record_id in enrollment: must be a valid UUID")
        }
        val inbox = payload["inbox"]
        if (inbox !is String || inbox.isEmpty()) {
            throw IllegalArgumentException("Invalid inbox in enrollment")
        }

        decodeAndValidateKey(payload["private_key"], "private_key")
        decodeAndValidateKey(payload["public_key"], "public_key")
        enrollmentServer(payload)
    }

    private fun decodeAndValidateKey(value: Any?, field: String): ByteArray {
        if (value !is String || value.isEmpty()) {
            throw IllegalArgumentException("Missing $field")
        }
        return try {
            val decoded = PuxCrypto.decodeBase64Url(value)
            if (decoded.size != PuxCrypto.KEY_BYTES) {
                throw IllegalArgumentException("Invalid $field length: expected 32 bytes")
            }
            decoded
        } catch (e: Exception) {
            if (e is IllegalArgumentException) throw e
            throw IllegalArgumentException("Invalid $field encoding: not valid base64url", e)
        }
    }

    companion object {
        lateinit var instance: RecordStore

        /** While true, [saveEnrollment] fails (interrupted local forget / legacy cleanup). */
        @Volatile
        var enrollmentBlocked: Boolean = false
        const val DEFAULT_SERVER_URL = "https://pux.vidur.xyz"
        const val PREFS_NAME = "pux_secure_storage"

        const val KEY_RECORD_ID = "record_id"
        const val KEY_PRIVATE_KEY = "private_key"
        const val KEY_PUBLIC_KEY = "public_key"
        const val KEY_INBOX = "inbox"
        const val KEY_SERVER_URL = "server_url"
        const val KEY_DEVICE_ID = "device_id"
        const val KEY_REGISTRATION_UNCERTAIN = "registration_uncertain"
        const val KEY_STALE_REGISTRATION_POSSIBLE = "stale_registration_possible"
        const val KEY_PENDING_REMOTE_REMOVAL = "pending_remote_removal"
        const val KEY_PENDING_REMOVAL_SERVER_UNREACHABLE = "pending_remote_removal_server_unreachable"
        const val KEY_DISMISSED_RESTRICTIONS = "dismissed_restriction_prompts"
        const val KEY_NOTIFICATION_PERMISSION_ASKED = "notification_permission_asked"
        const val KEY_NOTIFICATION_EXPLAINER_SKIPPED = "notification_explainer_skipped"

        private val CLEARTEXT_HOSTS = setOf("localhost", "127.0.0.1", "10.0.2.2")
        private val UUID_PATTERN = Pattern.compile(
            "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            Pattern.CASE_INSENSITIVE
        )

        /**
         * Accepts https URLs, and plain http only for local development hosts.
         * Returns the URL without a trailing slash.
         */
        fun validateServerUrl(raw: String): String {
            val uri = try {
                val parsed = java.net.URI(raw.trim())
                val scheme = parsed.scheme ?: throw IllegalArgumentException("missing scheme")
                val normalizedScheme = scheme.lowercase(Locale.ROOT)
                java.net.URI(
                    normalizedScheme,
                    parsed.userInfo,
                    parsed.host,
                    parsed.port,
                    parsed.path,
                    parsed.query,
                    parsed.fragment
                )
            } catch (e: Exception) {
                throw IllegalArgumentException("Invalid server URL in enrollment", e)
            }
            val host = uri.host
            if (host.isNullOrEmpty()) {
                throw IllegalArgumentException("Invalid server URL in enrollment: missing scheme or host")
            }
            val secure = uri.scheme == "https"
            val local = uri.scheme == "http" && CLEARTEXT_HOSTS.contains(host.lowercase(Locale.ROOT))
            if (!secure && !local) {
                throw IllegalArgumentException("Refusing insecure server ${uri.scheme}://$host: https is required")
            }
            if (!uri.userInfo.isNullOrEmpty() || uri.query != null || uri.fragment != null || (uri.path != null && uri.path.length > 1)) {
                throw IllegalArgumentException("Server URL must not have a path, query or credentials")
            }
            return "${uri.scheme}://$host" + if (uri.port != -1) ":${uri.port}" else ""
        }

        /**
         * Creates an Android Keystore-backed EncryptedSharedPreferences instance.
         */
        fun createEncrypted(context: Context, defaultServerUrl: String = DEFAULT_SERVER_URL): RecordStore {
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()

            val prefs = EncryptedSharedPreferences.create(
                context,
                PREFS_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
            return RecordStore(prefs, defaultServerUrl)
        }

        /**
         * Creates a fail-closed instance when Android Keystore is unavailable.
         * Throws on any attempt to read or write credentials, preventing plaintext storage leaks.
         */
        fun createFailing(error: Exception): RecordStore {
            return RecordStore(preferences = null, failureReason = error)
        }
    }
}
