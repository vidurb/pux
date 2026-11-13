package xyz.vidur.pux

import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AndroidManifestLocalizationTest {
    @Test
    fun manifestDeclaresRtlAndCanonicalAppName() {
        val app = ApplicationProvider.getApplicationContext<android.app.Application>()
        val info = app.packageManager.getApplicationInfo(app.packageName, 0)
        assertTrue((info.flags and android.content.pm.ApplicationInfo.FLAG_SUPPORTS_RTL) != 0)
        assertEquals("pux", app.getString(R.string.app_name))
    }
}
