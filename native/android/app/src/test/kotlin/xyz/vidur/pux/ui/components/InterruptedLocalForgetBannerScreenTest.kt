package xyz.vidur.pux.ui.components

import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.ui.theme.ContrastRatio
import xyz.vidur.pux.ui.theme.LightSurface
import xyz.vidur.pux.ui.theme.PuxTheme
import xyz.vidur.pux.ui.theme.PuxError
import xyz.vidur.pux.ui.theme.puxSemantic

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class InterruptedLocalForgetBannerScreenTest {
    @get:Rule val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun showsRetryAndUsesErrorOnSurfaceContrast() {
        var retries = 0
        val holder = object { var errorOnSurface: Color = Color.Unspecified }
        composeRule.setContent {
            PuxTheme {
                holder.errorOnSurface = MaterialTheme.puxSemantic.errorOnSurface
                InterruptedLocalForgetBanner(onRetry = { retries++ })
            }
        }
        composeRule.onNodeWithText("Retry forget", substring = true).performClick()
        assertEquals(1, retries)
        assertNotEquals(PuxError, holder.errorOnSurface)
        assertTrue(ContrastRatio.ratio(holder.errorOnSurface, LightSurface) >= 4.5)
    }
}
