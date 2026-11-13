package xyz.vidur.pux.ui.components

import androidx.compose.ui.graphics.Color
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.vidur.pux.api.ApiClient
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.testutil.FakeSharedPreferences
import xyz.vidur.pux.ui.theme.ContrastRatio
import xyz.vidur.pux.ui.theme.PuxTheme
import xyz.vidur.pux.ui.theme.puxSemantic

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ServerStatusCardScreenTest {
    @get:Rule val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test fun reachableStateUsesSemanticSuccessContrast() {
        val store = RecordStore(FakeSharedPreferences(), "https://pux.example")
        RecordStore.instance = store
        ApiClient.instance = ApiClient(store)
        val holder = object {
            var success: Color = Color.Unspecified
            var errorOnSurface: Color = Color.Unspecified
        }
        composeRule.setContent {
            PuxTheme {
                holder.success = androidx.compose.material3.MaterialTheme.puxSemantic.successOnSurfaceVariant
                holder.errorOnSurface = androidx.compose.material3.MaterialTheme.puxSemantic.errorOnSurface
                ServerStatusCard()
            }
        }
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Checking server", substring = true)
        assertTrue(ContrastRatio.ratio(holder.success, Color(0xFFEBF1EE)) >= 4.5)
        assertTrue(ContrastRatio.ratio(holder.errorOnSurface, Color(0xFFFFFFFF)) >= 4.5)
    }
}
