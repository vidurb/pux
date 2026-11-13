package xyz.vidur.pux.ui.theme

import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import org.junit.Assert.assertTrue
import xyz.vidur.pux.ui.theme.LightSurface
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ThemeRoleOnSurfaceTest {
    @get:Rule val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test fun lightSecondaryAndTertiaryRolesMeetAaOnWhiteSurface() {
        val holder = object {
            var secondary: Color = Color.Unspecified
            var tertiary: Color = Color.Unspecified
        }
        composeRule.setContent {
            PuxTheme(darkTheme = false) {
                holder.secondary = MaterialTheme.colorScheme.secondary
                holder.tertiary = MaterialTheme.colorScheme.tertiary
            }
        }
        composeRule.waitForIdle()
        assertTrue(ContrastRatio.ratio(holder.secondary, LightSurface) >= 4.5)
        assertTrue(ContrastRatio.ratio(holder.tertiary, LightSurface) >= 4.5)
    }

    @Test fun darkSecondaryRoleMeetsAaOnSecondaryFill() {
        val holder = object {
            var secondary: Color = Color.Unspecified
            var onSecondary: Color = Color.Unspecified
        }
        composeRule.setContent {
            PuxTheme(darkTheme = true) {
                holder.secondary = MaterialTheme.colorScheme.secondary
                holder.onSecondary = MaterialTheme.colorScheme.onSecondary
            }
        }
        composeRule.waitForIdle()
        assertTrue(ContrastRatio.ratio(holder.onSecondary, holder.secondary) >= 4.5)
    }
}
