package xyz.vidur.pux

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.os.SystemClock
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
    }
}
