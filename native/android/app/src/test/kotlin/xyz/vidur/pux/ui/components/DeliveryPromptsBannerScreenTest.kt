package xyz.vidur.pux.ui.components

import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.ui.theme.ContrastRatio
import xyz.vidur.pux.ui.theme.LightSurfaceVariant
import xyz.vidur.pux.ui.theme.PuxTheme
import xyz.vidur.pux.ui.theme.puxSemantic

/**
 * DeliveryPromptsBanner border/text colors use [MaterialTheme.puxSemantic.warningOnSurfaceVariant]
 * and [MaterialTheme.colorScheme.error] (see component source). Compose here captures those roles.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class DeliveryPromptsBannerScreenTest {
    @get:Rule val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun promptRolesUseThemeSemanticsWithAaContrastOnSurfaceVariant() {
        val holder = object {
            var warning: Color = Color.Unspecified
            var error: Color = Color.Unspecified
        }
        composeRule.setContent {
            PuxTheme {
                holder.warning = MaterialTheme.puxSemantic.warningOnSurfaceVariant
                holder.error = MaterialTheme.puxSemantic.errorOnSurface
            }
        }
        composeRule.waitForIdle()
        assertNotEquals(Color(0xFFE65100), holder.warning)
        assertNotEquals(Color(0xFFEF4444), holder.error)
        assertTrue(ContrastRatio.ratio(holder.warning, LightSurfaceVariant) >= 4.5)
    }
}
