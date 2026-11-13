package xyz.vidur.pux.push

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class CopyCodeActivityTest {
    private lateinit var context: Context
    private lateinit var clipboard: ClipboardManager

    @Before fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val instanceField = SensitiveClipboard::class.java.getDeclaredField("_instance")
        instanceField.isAccessible = true
        instanceField.set(null, null)
    }

    @Test fun copiesOnWindowFocusAndDismissesNotificationAfterCopy() {
        val controller = Robolectric.buildActivity(
            CopyCodeActivity::class.java,
            CopyCodeActivity.intent(context, "654321", 99)
        )
        val activity = controller.create().start().get() as CopyCodeActivity
        assertFalse(activity.copiedForTests())
        assertFalse(activity.notificationDismissedForTests())
        activity.onWindowFocusChanged(true)
        assertTrue(activity.copiedForTests())
        assertTrue(activity.notificationDismissedForTests())
        assertEquals("654321", clipboard.primaryClip?.getItemAt(0)?.text?.toString())
    }
}
