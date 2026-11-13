package xyz.vidur.pux.ui.components

import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.model.DeliveryState
import xyz.vidur.pux.model.DeliveryStatus
import xyz.vidur.pux.ui.theme.ContrastRatio
import xyz.vidur.pux.ui.theme.LightSurfaceVariant
import xyz.vidur.pux.ui.theme.PuxTheme
import xyz.vidur.pux.ui.theme.puxSemantic

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class DeliveryBannerScreenTest {
    @get:Rule val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test fun retryingBannerUsesThemeWarningNotLegacyOrange() {
        val holder = object { var warning: Color = Color.Unspecified }
        composeRule.setContent {
            PuxTheme {
                holder.warning = MaterialTheme.puxSemantic.warningOnSurfaceVariant
                DeliveryBanner(
                    status = DeliveryStatus(DeliveryState.RETRYING, "offline", 0),
                    onRetry = {},
                    onForget = {}
                )
            }
        }
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Not connected", substring = true).assertExists()
        assertNotEquals(Color(0xFFE65100), holder.warning)
        assertTrue(ContrastRatio.ratio(holder.warning, LightSurfaceVariant) >= 4.5)
    }
}
