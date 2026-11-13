package xyz.vidur.pux.storage

import android.content.Context
import android.content.ContextWrapper
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.testutil.FakeSharedPreferences

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class RemovalNoticeStoreTest {
    private lateinit var removalPrefs: FakeSharedPreferences
    private lateinit var context: Context

    @Before fun setup() {
        removalPrefs = FakeSharedPreferences()
        val base = ApplicationProvider.getApplicationContext<Context>()
        context = object : ContextWrapper(base) {
            override fun getSharedPreferences(name: String?, mode: Int) =
                if (name == "pux_removal_state") removalPrefs else super.getSharedPreferences(name, mode)
        }
    }

    @Test fun persistsAcrossProcessRestartSemantics() {
        val message = "Registration may still be active"
        RemovalNoticeStore.save(context, message)
        assertEquals(message, RemovalNoticeStore.peek(context))
        RemovalNoticeStore.clear(context)
        assertNull(RemovalNoticeStore.peek(context))
    }
}
