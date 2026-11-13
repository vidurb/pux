package xyz.vidur.pux.push

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.os.SystemClock
import android.util.Log

/**
 * Copies secrets (OTPs, enrollment JSON) to the Android clipboard.
 *
 * Implements Android sensitive clipboard best practices matching pux specifications:
 * - Marks the clip sensitive with [ClipDescription.EXTRA_IS_SENSITIVE] (Android 13+) or
 *   "android.content.extra.IS_SENSITIVE" (Android 7+), hiding it from clipboard history and overlays.
 * - Schedules automatic clearing after 60 seconds if the clipboard still holds our text.
 *   The timer may fire while backgrounded, but [clearIfStillOurs] does nothing until
 *   [onWindowFocusChanged] reports focus (wired from [xyz.vidur.pux.MainActivity]).
 * - Focus is false until [onWindowFocusChanged] reports true from an Activity window.
 * - Copy itself runs in the foreground caller; only clearing is focus-gated.
 */
class SensitiveClipboard(private val context: Context) {

    private val handler = Handler(Looper.getMainLooper())
    private var pendingClear: String? = null
    private var clearAt = 0L
    private var hasFocus = false

    fun onWindowFocusChanged(focused: Boolean) {
        hasFocus = focused
        if (focused) {
            clearIfStillOurs()
        }
    }

    fun copy(text: String, clearAfterMs: Long = DEFAULT_CLEAR_AFTER_MS) {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return

        val clip = ClipData.newPlainText("pux", text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            clip.description.extras = PersistableBundle().apply {
                putBoolean(sensitiveExtraKey(), true)
            }
        }
        clipboard.setPrimaryClip(clip)

        handler.removeCallbacksAndMessages(null)
        if (clearAfterMs > 0) {
            pendingClear = text
            clearAt = SystemClock.elapsedRealtime() + clearAfterMs
            handler.postDelayed({ clearIfStillOurs() }, clearAfterMs)
        }
    }

    fun clearIfStillOurs() {
        val text = pendingClear ?: return
        if (SystemClock.elapsedRealtime() < clearAt) return
        if (!hasFocus) return

        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return

        try {
            if (forceClipReadFailureForTests) {
                throw SecurityException("Clipboard access denied")
            }
            val primaryClip = clipboard.primaryClip
            val currentText = if (primaryClip != null && primaryClip.itemCount > 0) {
                primaryClip.getItemAt(0).text?.toString()
            } else {
                null
            }

            if (currentText == text) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    clipboard.clearPrimaryClip()
                } else {
                    clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
                }
                pendingClear = null
                Log.d(TAG, "Sensitive clipboard contents cleared.")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to clear sensitive clipboard: ${e.message}")
        }
    }

    internal fun pendingClearTextForTests(): String? = pendingClear

    internal fun hasFocusForTests(): Boolean = hasFocus

    @Volatile
    internal var forceClipReadFailureForTests: Boolean = false

    private fun sensitiveExtraKey(): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ClipDescription.EXTRA_IS_SENSITIVE
        } else {
            "android.content.extra.IS_SENSITIVE"
        }
    }

    companion object {
        private const val TAG = "SensitiveClipboard"
        const val DEFAULT_CLEAR_AFTER_MS = 60_000L

        @Volatile
        private var _instance: SensitiveClipboard? = null

        val instance: SensitiveClipboard
            get() = requireNotNull(_instance) { "SensitiveClipboard not initialized" }

        fun getInstance(context: Context): SensitiveClipboard {
            return _instance ?: synchronized(this) {
                _instance ?: SensitiveClipboard(context.applicationContext).also { _instance = it }
            }
        }
    }
}
