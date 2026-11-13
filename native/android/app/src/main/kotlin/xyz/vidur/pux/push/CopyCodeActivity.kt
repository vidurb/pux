package xyz.vidur.pux.push

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.core.app.NotificationManagerCompat
import xyz.vidur.pux.R

/**
 * Trampoline-free handler for the notification "Copy code" action.
 * Copies on the first [onWindowFocusChanged] while foreground, then finishes.
 */
class CopyCodeActivity : Activity() {

    private var pendingCode: String? = null
    private var copied = false
    private var notificationId: Int = -1
    private var notificationDismissed = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingCode = intent.getStringExtra(EXTRA_CODE)
        notificationId = intent.getIntExtra(EXTRA_NOTIFICATION_ID, -1)

        if (pendingCode.isNullOrEmpty()) {
            dismissNotificationIfNeeded()
            finish()
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        val sensitive = SensitiveClipboard.getInstance(this)
        sensitive.onWindowFocusChanged(hasFocus)
        if (!hasFocus || copied) return
        val code = pendingCode ?: return
        sensitive.copy(code)
        copied = true
        dismissNotificationIfNeeded()
        Toast.makeText(this, getString(R.string.clipboard_code_copied), Toast.LENGTH_SHORT).show()
        finish()
    }

    private fun dismissNotificationIfNeeded() {
        if (notificationDismissed || notificationId == -1) return
        NotificationManagerCompat.from(this).cancel(notificationId)
        notificationDismissed = true
    }

    internal fun notificationDismissedForTests(): Boolean = notificationDismissed

    internal fun copiedForTests(): Boolean = copied

    companion object {
        const val EXTRA_CODE = "code"
        const val EXTRA_NOTIFICATION_ID = "notification_id"

        fun intent(context: android.content.Context, code: String, notificationId: Int): Intent {
            return Intent(context, CopyCodeActivity::class.java).apply {
                putExtra(EXTRA_CODE, code)
                putExtra(EXTRA_NOTIFICATION_ID, notificationId)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
        }
    }
}
