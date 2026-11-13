package xyz.vidur.pux.ui

import android.Manifest
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.lifecycle.Lifecycle
import com.google.mlkit.common.sdkinternal.MlKitContext
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import xyz.vidur.pux.ui.screens.EnrollScreen
import xyz.vidur.pux.ui.theme.PuxTheme

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class EnrollmentRecoveryRegressionTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun cameraPermissionIsRecheckedOnResume() {
        val app = RuntimeEnvironment.getApplication()
        MlKitContext.initializeIfNeeded(app)
        shadowOf(app).denyPermissions(Manifest.permission.CAMERA)
        compose.setContent { PuxTheme { EnrollScreen(onEnrolled = {}, onPasteFallback = {}, onBack = {}) } }
        compose.waitForIdle()
        compose.onNodeWithText("Camera permission was denied. Open Settings to allow camera access, or enroll manually.").assertIsDisplayed()
        compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
        shadowOf(app).grantPermissions(Manifest.permission.CAMERA)
        compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        compose.waitForIdle()
        compose.onNodeWithText("Camera permission was denied. Open Settings to allow camera access, or enroll manually.").assertDoesNotExist()
    }

    @Test fun oversizedEnrollmentLeavesQrUnavailableInsteadOfThrowing() {
        assertNull(QrCodeUtil.generateQrBitmapOrNull("a".repeat(10000), 480))
    }
}
