package xyz.vidur.pux.ui.screens

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.ui.theme.PuxTheme

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class EnrollChooserScreenTest {
    @get:Rule val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test fun migrationRecoveryRequiredDisablesSetupButtons() {
        composeRule.setContent {
            PuxTheme {
                EnrollChooserScreen(
                    onCreateRelay = {},
                    onAddToRelay = {},
                    migrationRecoveryRequired = true,
                )
            }
        }
        composeRule.onNodeWithText("Create new relay").assertIsNotEnabled()
        composeRule.onNodeWithText("Add to existing relay").assertIsNotEnabled()
        composeRule.onNodeWithText("Resolve the previous installation recovery prompt", substring = true)
            .assertIsDisplayed()
    }
}
