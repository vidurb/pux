package xyz.vidur.pux.push

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import xyz.vidur.pux.R
import xyz.vidur.pux.model.RelayNotification
import xyz.vidur.pux.MainActivity
import java.util.concurrent.atomic.AtomicInteger

/**
 * Manages notification channels, lock-screen privacy, and posting of decrypted relay notifications.
 */
class NotificationHelper(private val context: Context) {

    private val notificationManager = NotificationManagerCompat.from(context)
    private val idSequence = AtomicInteger((System.currentTimeMillis() and 0x7fffffff).toInt())

    init {
        createNotificationChannel()
    }

    fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = CHANNEL_DESCRIPTION
                lockscreenVisibility = NotificationCompat.VISIBILITY_PRIVATE
                enableVibration(true)
            }

            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            manager?.createNotificationChannel(channel)
        }
    }

    fun showNotification(notification: RelayNotification) {
        val notificationId = idSequence.incrementAndGet()

        // Content intent: open verified forwarding link externally, or open MainActivity
        val contentIntent = if (notification.url != null) {
            val browserIntent = Intent(Intent.ACTION_VIEW, Uri.parse(notification.url.toString())).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            PendingIntent.getActivity(
                context,
                notificationId,
                browserIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else {
            val mainIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            PendingIntent.getActivity(
                context,
                notificationId,
                mainIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_pux)
            .setContentTitle(notification.title)
            .setContentText(notification.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(notification.body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setAutoCancel(true)
            .setContentIntent(contentIntent)

        // Add "Copy code" action if a code is available
        val code = notification.code
        if (!code.isNullOrEmpty()) {
            val copyIntent = CopyCodeActivity.intent(context, code, notificationId)
            val copyPendingIntent = PendingIntent.getActivity(
                context,
                notificationId,
                copyIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            builder.addAction(
                NotificationCompat.Action.Builder(
                    0,
                    "Copy code",
                    copyPendingIntent
                ).build()
            )
        }

        try {
            notificationManager.notify(notificationId, builder.build())
        } catch (e: SecurityException) {
            // Android 13+ POST_NOTIFICATIONS not granted
        }
    }

    companion object {
        const val CHANNEL_ID = "pux_otp"
        const val CHANNEL_NAME = "OTP codes"
        const val CHANNEL_DESCRIPTION = "Decrypted OTP notifications from pux"

        @Volatile
        private var instance: NotificationHelper? = null

        fun getInstance(context: Context): NotificationHelper {
            return instance ?: synchronized(this) {
                instance ?: NotificationHelper(context.applicationContext).also { instance = it }
            }
        }
    }
}
