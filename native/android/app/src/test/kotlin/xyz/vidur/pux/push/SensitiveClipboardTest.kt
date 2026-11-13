package xyz.vidur.pux.push

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import android.os.Looper
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], application = Application::class)
class SensitiveClipboardTest {
    private lateinit var context: Context
    private lateinit var clipboard: ClipboardManager

    @Before fun setup() {
        context = ApplicationProvider.getApplicationContext()
        clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val instanceField = SensitiveClipboard::class.java.getDeclaredField("_instance")
        instanceField.isAccessible = true
        instanceField.set(null, null)
    }

    @Test fun startsWithoutFocusUntilWindowReports() {
        val sensitive = SensitiveClipboard.getInstance(context)
        assertFalse(sensitive.hasFocusForTests())
        sensitive.onWindowFocusChanged(true)
        assertTrue(sensitive.hasFocusForTests())
    }

    @Test
    fun clearWaitsUntilWindowFocusedWhenBackgrounded() {
        val sensitive = SensitiveClipboard.getInstance(context)
        sensitive.onWindowFocusChanged(false)
        sensitive.copy("otp-123", clearAfterMs = 1)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(50))
        assertEquals("otp-123", clipboard.primaryClip?.getItemAt(0)?.text?.toString())
        sensitive.onWindowFocusChanged(true)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(50))
        val after = clipboard.primaryClip?.getItemAt(0)?.text?.toString().orEmpty()
        assertNotEquals("otp-123", after)
    }

    @Test
    fun retainsPendingClearUntilOurClipIsGone() {
        val sensitive = SensitiveClipboard.getInstance(context)
        sensitive.onWindowFocusChanged(true)
        sensitive.copy("otp-123", clearAfterMs = 1)
        clipboard.setPrimaryClip(ClipData.newPlainText("other", "replaced"))
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(50))
        sensitive.onWindowFocusChanged(true)
        assertEquals("otp-123", sensitive.pendingClearTextForTests())
        assertEquals("otp-123", sensitive.pendingClearTextForTests())
    }

    @Test
    fun clearKeepsPendingWhenClipReadDenied() {
        val sensitive = SensitiveClipboard.getInstance(context)
        sensitive.onWindowFocusChanged(true)
        sensitive.copy("otp-123", clearAfterMs = 1)
        sensitive.forceClipReadFailureForTests = true
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(50))
        assertEquals("otp-123", sensitive.pendingClearTextForTests())
        sensitive.forceClipReadFailureForTests = false
    }
}
