package xyz.vidur.pux.system

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import xyz.vidur.pux.model.NotificationAccess
import xyz.vidur.pux.push.NotificationHelper
import xyz.vidur.pux.storage.RecordStore

/**
 * Checks system-level notification access, category states, and permissions.
 */
object NotificationPermissions {

    fun check(context: Context, recordStore: RecordStore): NotificationAccess {
        val manager = NotificationManagerCompat.from(context)

        // Check if notifications are disabled globally for the app
        if (!manager.areNotificationsEnabled()) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val granted = ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.POST_NOTIFICATIONS
                ) == PackageManager.PERMISSION_GRANTED

                if (!granted) {
                    val askedBefore = recordStore.notificationPermissionAsked()
                    return if (!askedBefore) {
                        NotificationAccess.NOT_ASKED
                    } else {
                        NotificationAccess.OFF
                    }
                }
            }
            return NotificationAccess.OFF
        }

        // Check channel state (Android 8.0+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = manager.getNotificationChannelCompat(NotificationHelper.CHANNEL_ID)
            if (channel != null) {
                val importance = channel.importance
                if (importance == NotificationManagerCompat.IMPORTANCE_NONE) {
                    return NotificationAccess.CHANNEL_OFF
                }
                if (importance < NotificationManagerCompat.IMPORTANCE_HIGH) {
                    return NotificationAccess.QUIET
                }
            }
        }

        return NotificationAccess.ALLOWED
    }

    fun openNotificationSettings(context: Context, channelOff: Boolean = false): Boolean {
        if (channelOff && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            return BackgroundRestrictions.openChannelSettings(context)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                if (context !is Activity) {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            }
            return try {
                context.startActivity(intent)
                true
            } catch (_: ActivityNotFoundException) {
                BackgroundRestrictions.openAppSettings(context)
            }
        }
        return BackgroundRestrictions.openAppSettings(context)
    }
}
