package xyz.vidur.pux

import android.app.ActivityManager
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.os.SystemClock
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.content.IntentCompat
import androidx.core.content.PackageManagerCompat
import androidx.core.content.UnusedAppRestrictionsConstants
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val handler = Handler(Looper.getMainLooper())
    private var pendingClear: String? = null
    private var clearAt = 0L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CLIPBOARD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "copySensitive" -> {
                        val text = call.argument<String>("text")
                        val clearAfterMs = call.argument<Number>("clearAfterMs")?.toLong() ?: 0L
                        if (text == null) {
                            result.error("bad_args", "text is required", null)
                        } else {
                            copySensitive(text, clearAfterMs)
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BACKGROUND_RESTRICTIONS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getStatus" -> reportBackgroundRestrictions(result)
                    "openHibernationSettings" -> result.success(openHibernationSettings())
                    "openAppSettings" -> result.success(openAppSettings())
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIFICATION_PERMISSIONS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getStatus" -> result.success(notificationStatus())
                    "openNotificationSettings" -> result.success(openNotificationSettings())
                    "openChannelSettings" -> result.success(openNotificationSettings(OTP_NOTIFICATION_CHANNEL))
                    else -> result.notImplemented()
                }
            }
    }

    private fun notificationStatus(): Map<String, Boolean?> {
        val notifications = NotificationManagerCompat.from(this)
        return mapOf(
            // Covers the Android 13+ permission and the per-app switch on every version.
            "appEnabled" to notifications.areNotificationsEnabled(),
            // Null before Android 8, and until the first code creates the channel.
            "channelEnabled" to
                notifications.getNotificationChannelCompat(OTP_NOTIFICATION_CHANNEL)?.let {
                    it.importance != NotificationManagerCompat.IMPORTANCE_NONE
                },
        )
    }

    // The channel page is only useful once the app's own notifications are on, so
    // Dart asks for it only then. Android before 8 has neither page.
    private fun openNotificationSettings(channel: String? = null): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return openAppSettings()

        val action =
            if (channel == null) {
                Settings.ACTION_APP_NOTIFICATION_SETTINGS
            } else {
                Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS
            }
        val intent = Intent(action).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        if (channel != null) intent.putExtra(Settings.EXTRA_CHANNEL_ID, channel)
        return try {
            startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            openAppSettings()
        }
    }

    private fun reportBackgroundRestrictions(result: MethodChannel.Result) {
        // The user's Restricted battery setting; can't be read before Android 9.
        val backgroundRestricted =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).isBackgroundRestricted
            } else {
                null
            }

        val future = PackageManagerCompat.getUnusedAppRestrictionsStatus(this)
        future.addListener(
            {
                val status =
                    try {
                        future.get()
                    } catch (_: Exception) {
                        UnusedAppRestrictionsConstants.ERROR
                    }
                result.success(
                    mapOf(
                        "hibernation" to hibernationName(status),
                        "backgroundRestricted" to backgroundRestricted,
                    ),
                )
            },
            ContextCompat.getMainExecutor(this),
        )
    }

    // Only API_31 stops pushes. API_30 and its backport just reset permissions.
    private fun hibernationName(status: Int) =
        when (status) {
            UnusedAppRestrictionsConstants.API_31 -> "hibernation"
            UnusedAppRestrictionsConstants.API_30,
            UnusedAppRestrictionsConstants.API_30_BACKPORT,
            -> "permissionReset"
            UnusedAppRestrictionsConstants.DISABLED -> "off"
            UnusedAppRestrictionsConstants.FEATURE_NOT_AVAILABLE -> "unavailable"
            else -> "unknown"
        }

    private fun openHibernationSettings(): Boolean {
        try {
            val intent = IntentCompat.createManageUnusedAppRestrictionsIntent(this, packageName)
            // The docs require startActivityForResult, even with the result unused.
            startActivityForResult(intent, MANAGE_UNUSED_APP_RESTRICTIONS_REQUEST)
            return true
        } catch (_: ActivityNotFoundException) {
            return openAppSettings()
        } catch (_: UnsupportedOperationException) {
            return openAppSettings()
        }
    }

    private fun openAppSettings(): Boolean {
        val intent =
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
        return try {
            startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    // Android 10+ only lets the focused app read the clipboard, so a clear that
    // comes due while we are in the background waits until we have focus again.
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) clearIfStillOurs()
    }

    private fun copySensitive(text: String, clearAfterMs: Long) {
        val clip = ClipData.newPlainText("pux", text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            // Hides the preview in the Android 13+ clipboard overlay and from keyboards.
            clip.description.extras = PersistableBundle().apply {
                putBoolean(sensitiveExtraKey(), true)
            }
        }
        clipboard().setPrimaryClip(clip)

        handler.removeCallbacksAndMessages(null)
        if (clearAfterMs > 0) {
            pendingClear = text
            clearAt = SystemClock.elapsedRealtime() + clearAfterMs
            handler.postDelayed({ clearIfStillOurs() }, clearAfterMs)
        }
    }

    private fun clearIfStillOurs() {
        val text = pendingClear ?: return
        if (SystemClock.elapsedRealtime() < clearAt || !hasWindowFocus()) return

        pendingClear = null
        val clipboard = clipboard()
        val current = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text
        if (current?.toString() != text) return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            clipboard.clearPrimaryClip()
        } else {
            clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
        }
    }

    private fun clipboard() = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    private fun sensitiveExtraKey() =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ClipDescription.EXTRA_IS_SENSITIVE
        } else {
            "android.content.extra.IS_SENSITIVE"
        }

    private companion object {
        const val CLIPBOARD_CHANNEL = "xyz.vidur.pux/clipboard"
        const val BACKGROUND_RESTRICTIONS_CHANNEL = "xyz.vidur.pux/background_restrictions"
        const val NOTIFICATION_PERMISSIONS_CHANNEL = "xyz.vidur.pux/notification_permissions"

        // The channel NotificationService posts codes to.
        const val OTP_NOTIFICATION_CHANNEL = "pux_otp"
        const val MANAGE_UNUSED_APP_RESTRICTIONS_REQUEST = 0x7078
    }
}
