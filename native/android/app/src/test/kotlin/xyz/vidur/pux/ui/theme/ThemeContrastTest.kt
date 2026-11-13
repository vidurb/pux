package xyz.vidur.pux.ui.theme

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertTrue
import org.junit.Test

class ThemeContrastTest {
    @Test
    fun semanticPairsMeetWcagAa() {
        val normalTextPairs = listOf(
            Color(0xFF047857) to Color(0xFFEBF1EE),
            Color(0xFFC2410C) to Color(0xFFEBF1EE),
            Color(0xFF34D399) to Color(0xFF24302C),
            Color(0xFFFBBF24) to Color(0xFF24302C),
            PuxErrorOnSurfaceLight to LightSurface,
            Color(0xFF0E3B32) to LightSurface,
            Color(0xFF064E3B) to LightSurface,
        )
        val largeTextPairs = listOf(
            Color(0xFFFFFFFF) to Color(0xFF0E3B32),
            Color(0xFF121816) to Color(0xFFEF4444),
            Color(0xFF6EE7B7) to Color(0xFF121816),
        )
        for ((fg, bg) in normalTextPairs) {
            assertTrue(
                "Normal text contrast ${ContrastRatio.ratio(fg, bg)}:1",
                ContrastRatio.ratio(fg, bg) >= 4.5
            )
        }
        for ((fg, bg) in largeTextPairs) {
            assertTrue(
                "Large text contrast ${ContrastRatio.ratio(fg, bg)}:1",
                ContrastRatio.ratio(fg, bg) >= 3.0
            )
        }
    }
}
