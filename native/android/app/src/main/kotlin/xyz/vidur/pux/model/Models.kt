package xyz.vidur.pux.model

import org.json.JSONObject
import java.net.URI

/**
 * What a decrypted payload asks us to show.
 *
 * Types:
 * - "otp": {"type": "otp", "otp": "...", "sender": "...", "verified": bool}
 *   Title: "OTP from $sender$marker" (marker is " (unverified)" if verified == false)
 *   Body: otp
 *   Code: otp
 * - "forward_confirm": {"type": "forward_confirm", "code": "...", "url": "...", "sender": "...", "forwarding_from": "..."}
 *   Title: "Email forwarding confirmation"
 *   Body: combination of "Forwarding from $from", "Code: $code", "$url", "From $sender"
 *   Code: code (if non-null)
 *   Url: confirmationUri(url) (if non-null and valid Gmail forwarding link)
 * - Payloads without "type" default to OTP.
 */
data class RelayNotification(
    val title: String,
    val body: String,
    val code: String? = null,
    val url: URI? = null
) {
    val urlString: String? get() = url?.toString()

    companion object {
        val CONFIRMATION_HOSTS = setOf(
            "mail.google.com",
            "mail-settings.google.com"
        )

        fun fromPayload(json: JSONObject): RelayNotification {
            val type = json.optStringOrDefault("type", "otp")
            val sender = json.optStringOrDefault("sender", "Unknown sender")

            return when (type) {
                "forward_confirm" -> {
                    val code = json.optNullableString("code")
                    val rawUrl = json.optNullableString("url")
                    val from = json.optNullableString("forwarding_from")
                    val validatedUri = confirmationUri(rawUrl)

                    val bodyLines = mutableListOf<String>()
                    if (from != null) bodyLines.add("Forwarding from $from")
                    if (code != null) bodyLines.add("Code: $code")
                    if (rawUrl != null) bodyLines.add(rawUrl)
                    if (from == null) bodyLines.add("From $sender")

                    RelayNotification(
                        title = "Email forwarding confirmation",
                        body = bodyLines.joinToString("\n"),
                        code = code,
                        url = validatedUri
                    )
                }
                "otp" -> {
                    val otp = json.optStringOrDefault("otp", "??????")
                    val verified = json.optBooleanWhenPresent("verified")
                    val marker = if (verified == false) " (unverified)" else ""
                    RelayNotification(
                        title = "OTP from $sender$marker",
                        body = otp,
                        code = otp
                    )
                }
                else -> {
                    val otp = json.optStringOrDefault("otp", "??????")
                    val marker = " (unverified)"
                    RelayNotification(
                        title = "OTP from $sender$marker",
                        body = otp,
                        code = otp
                    )
                }
            }
        }

        fun confirmationUri(url: String?): URI? {
            if (url.isNullOrBlank()) return null
            val uri = try {
                URI(url.trim())
            } catch (_: Exception) {
                return null
            }
            if (uri.scheme != "https") return null
            if (!uri.userInfo.isNullOrEmpty()) return null
            if (uri.port != -1) return null
            val host = uri.host ?: return null
            if (!CONFIRMATION_HOSTS.contains(host)) return null
            return uri
        }
    }
}

data class TestCode(
    val otp: String,
    val devices: Int
)

enum class ServerHealthState {
    REACHABLE,
    UNREACHABLE,
    SERVER_ERROR
}

data class ServerHealth(
    val state: ServerHealthState,
    val reason: String? = null
)

enum class DeliveryRestriction {
    HIBERNATION,
    BACKGROUND_USE,
    QUIET_CHANNEL
}

data class DeliveryRestrictionStatus(
    val active: Set<DeliveryRestriction> = emptySet(),
    val clear: Set<DeliveryRestriction> = emptySet()
)

enum class NotificationAccess {
    ALLOWED,
    OFF,
    NOT_ASKED,
    CHANNEL_OFF,
    QUIET
}

enum class DeliveryState {
    IDLE,
    CONNECTING,
    READY,
    RETRYING,
    FIREBASE_UNCONFIGURED,
    RECORD_UNKNOWN,
    TOO_MANY_DEVICES
}

data class DeliveryStatus(
    val state: DeliveryState = DeliveryState.IDLE,
    val message: String? = null,
    val undecryptable: Int = 0
)
