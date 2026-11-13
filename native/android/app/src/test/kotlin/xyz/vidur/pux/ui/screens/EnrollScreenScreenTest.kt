package xyz.vidur.pux.ui.screens

import android.Manifest
import androidx.compose.ui.test.assertIsDisplayed
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.core.app.ApplicationProvider
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.RuntimeEnvironment
import xyz.vidur.pux.ui.theme.PuxTheme

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class EnrollScreenScreenTest {
    @get:Rule val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Before fun grantCamera() {
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.CAMERA)
    }

    @Test fun cameraErrorFallbackIsVisible() {
        composeRule.setContent {
            PuxTheme {
                EnrollScreen(
                    onEnrolled = {},
                    onPasteFallback = {},
                    onBack = {},
                    initialCameraError = "Camera unavailable: test bind failure",
                )
            }
        }
        composeRule.onNodeWithText("Camera unavailable: test bind failure").assertIsDisplayed()
        composeRule.onNodeWithText("You can enter your enrollment payload manually instead.").assertIsDisplayed()
    }
}
