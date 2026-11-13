package xyz.vidur.pux.system

import android.app.Activity
import android.app.ActivityManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.content.IntentCompat
import androidx.core.content.PackageManagerCompat
import androidx.core.content.UnusedAppRestrictionsConstants
import kotlinx.coroutines.suspendCancellableCoroutine
import xyz.vidur.pux.model.DeliveryRestriction
import xyz.vidur.pux.model.DeliveryRestrictionStatus
import xyz.vidur.pux.push.NotificationHelper
import kotlin.coroutines.resume

/**
 * Detects Android battery and app hibernation restrictions that could delay or drop push notifications.
 */
object BackgroundRestrictions {

    suspend fun check(context: Context): DeliveryRestrictionStatus {
        val active = mutableSetOf<DeliveryRestriction>()
        val clear = mutableSetOf<DeliveryRestriction>()

        // 1. Hibernation check (Android 12+ API 31)
        val hibernationStatus = getHibernationStatus(context)
        when (hibernationStatus) {
            UnusedAppRestrictionsConstants.API_31 -> active.add(DeliveryRestriction.HIBERNATION)
            UnusedAppRestrictionsConstants.API_30,
            UnusedAppRestrictionsConstants.API_30_BACKPORT,
            UnusedAppRestrictionsConstants.DISABLED,
            UnusedAppRestrictionsConstants.FEATURE_NOT_AVAILABLE -> clear.add(DeliveryRestriction.HIBERNATION)
        }

        // 2. Background battery usage restriction check (API 28+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            val isRestricted = activityManager?.isBackgroundRestricted
            if (isRestricted == true) {
                active.add(DeliveryRestriction.BACKGROUND_USE)
            } else if (isRestricted == false) {
                clear.add(DeliveryRestriction.BACKGROUND_USE)
            }
        }

        // 3. Quiet channel check (OTP category importance < HIGH)
        val notificationManager = NotificationManagerCompat.from(context)
        val channel = notificationManager.getNotificationChannelCompat(NotificationHelper.CHANNEL_ID)
        if (channel != null) {
            val importance = channel.importance
            if (importance != NotificationManagerCompat.IMPORTANCE_NONE) {
                if (importance < NotificationManagerCompat.IMPORTANCE_HIGH) {
                    active.add(DeliveryRestriction.QUIET_CHANNEL)
                } else {
                    clear.add(DeliveryRestriction.QUIET_CHANNEL)
                }
            }
        }

        return DeliveryRestrictionStatus(active = active, clear = clear)
    }

    private suspend fun getHibernationStatus(context: Context): Int =
        suspendCancellableCoroutine { continuation ->
            val future = PackageManagerCompat.getUnusedAppRestrictionsStatus(context)
            future.addListener(
                {
                    val status = try {
                        future.get()
                    } catch (_: Exception) {
                        UnusedAppRestrictionsConstants.ERROR
                    }
                    if (continuation.isActive) {
                        continuation.resume(status)
                    }
                },
                ContextCompat.getMainExecutor(context)
            )
        }

    fun openSettings(context: Context, restriction: DeliveryRestriction): Boolean {
        return when (restriction) {
            DeliveryRestriction.HIBERNATION -> openHibernationSettings(context)
            DeliveryRestriction.BACKGROUND_USE -> openAppSettings(context)
            DeliveryRestriction.QUIET_CHANNEL -> openChannelSettings(context)
        }
    }

    fun openHibernationSettings(context: Context): Boolean {
        return try {
            val intent = IntentCompat.createManageUnusedAppRestrictionsIntent(context, context.packageName)
            if (context !is Activity) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            true
        } catch (_: Exception) {
            openAppSettings(context)
        }
    }

    fun openAppSettings(context: Context): Boolean {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", context.packageName, null)
        ).apply {
            if (context !is Activity) {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }
        return try {
            context.startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    fun openChannelSettings(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return openAppSettings(context)
        }
        val intent = Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).apply {
            putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            putExtra(Settings.EXTRA_CHANNEL_ID, NotificationHelper.CHANNEL_ID)
            if (context !is Activity) {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }
        return try {
            context.startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            openAppSettings(context)
        }
    }
}
