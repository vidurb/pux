package xyz.vidur.pux.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

/*
 * WCAG AA contrast ratios (sRGB, relative luminance):
 * Light — onPrimary (#FFFFFF) on primary (#0E3B32): 12.42:1
 * Light — primary (#0E3B32) on background (#F8FAF9): 11.85:1
 * Light — onError (#121816) on error (#EF4444): 4.78:1
 * Light — error on surface (#7F1D1D) on surface (#FFFFFF): 5.56:1
 * Light — onSecondaryContainer (#0E3B32) on surface (#FFFFFF): 11.85:1
 * Light — onTertiaryContainer (#064E3B) on surface (#FFFFFF): 9.75:1
 * Light — success (#047857) on surfaceVariant (#EBF1EE): 4.79:1
 * Light — warning (#C2410C) on surfaceVariant (#EBF1EE): 4.52:1
 * Dark — primary (#6EE7B7) on background (#121816): 11.80:1
 * Dark — onPrimary (#0E3B32) on primary (#6EE7B7): 8.15:1
 * Dark — onError (#121816) on error (#EF4444): 4.78:1
 * Dark — success (#34D399) on surfaceVariant (#24302C): 7.12:1
 * Dark — warning (#FBBF24) on surfaceVariant (#24302C): 8.20:1
 */

data class PuxSemanticColors(
    val successOnSurfaceVariant: Color,
    val warningOnSurfaceVariant: Color,
    val warningOnSurface: Color,
    val errorOnSurface: Color,
    val secondaryOnSurface: Color,
    val tertiaryOnSurface: Color,
)

val LocalPuxSemanticColors = staticCompositionLocalOf {
    PuxSemanticColors(
        successOnSurfaceVariant = PuxSuccessOnSurfaceVariantLight,
        warningOnSurfaceVariant = PuxWarningOnSurfaceVariantLight,
        warningOnSurface = PuxWarningOnSurfaceLight,
        errorOnSurface = PuxErrorOnSurfaceLight,
        secondaryOnSurface = PuxBrandDark,
        tertiaryOnSurface = Color(0xFF064E3B),
    )
}

val MaterialTheme.puxSemantic: PuxSemanticColors
    @Composable
    get() = LocalPuxSemanticColors.current

private val DarkColorScheme = darkColorScheme(
    primary = Color(0xFF6EE7B7),
    onPrimary = PuxBrandDark,
    primaryContainer = PuxBrandTeal,
    onPrimaryContainer = DarkOnBackground,
    secondary = Color(0xFF1F4D3F),
    onSecondary = DarkOnBackground,
    secondaryContainer = Color(0xFF1F4D3F),
    onSecondaryContainer = DarkOnBackground,
    tertiary = PuxEmerald,
    onTertiary = PuxBrandDark,
    tertiaryContainer = Color(0xFF134E3A),
    onTertiaryContainer = DarkOnBackground,
    background = DarkBackground,
    onBackground = DarkOnBackground,
    surface = DarkSurface,
    onSurface = DarkOnBackground,
    surfaceVariant = DarkSurfaceVariant,
    onSurfaceVariant = Color(0xFFC5D1CD),
    surfaceDim = DarkBackground,
    surfaceBright = Color(0xFF3A4542),
    surfaceContainerLowest = DarkBackground,
    surfaceContainerLow = Color(0xFF161E1C),
    surfaceContainer = DarkSurface,
    surfaceContainerHigh = Color(0xFF252F2C),
    surfaceContainerHighest = DarkSurfaceVariant,
    inverseSurface = LightOnBackground,
    inverseOnSurface = LightSurface,
    inversePrimary = PuxBrandTeal,
    error = PuxError,
    onError = PuxOnError,
    errorContainer = Color(0xFF5C2020),
    onErrorContainer = Color(0xFFFECACA),
    outline = Color(0xFF8A9E97),
    outlineVariant = Color(0xFF3D4F49),
    scrim = Color(0xFF000000),
)

private val LightColorScheme = lightColorScheme(
    primary = PuxBrandDark,
    onPrimary = LightSurface,
    primaryContainer = Color(0xFFB8E6D4),
    onPrimaryContainer = PuxBrandDark,
    secondary = PuxBrandDark,
    onSecondary = LightSurface,
    secondaryContainer = Color(0xFFD4EDE6),
    onSecondaryContainer = PuxBrandDark,
    tertiary = Color(0xFF064E3B),
    onTertiary = LightSurface,
    tertiaryContainer = Color(0xFFD1FAE5),
    onTertiaryContainer = Color(0xFF064E3B),
    background = LightBackground,
    onBackground = LightOnBackground,
    surface = LightSurface,
    onSurface = LightOnBackground,
    surfaceVariant = LightSurfaceVariant,
    onSurfaceVariant = Color(0xFF3D4F49),
    surfaceDim = Color(0xFFD5DDD9),
    surfaceBright = LightSurface,
    surfaceContainerLowest = LightSurface,
    surfaceContainerLow = Color(0xFFF2F6F4),
    surfaceContainer = LightBackground,
    surfaceContainerHigh = LightSurfaceVariant,
    surfaceContainerHighest = Color(0xFFE0E8E4),
    inverseSurface = LightOnBackground,
    inverseOnSurface = LightBackground,
    inversePrimary = Color(0xFF6EE7B7),
    error = PuxError,
    onError = PuxOnError,
    errorContainer = Color(0xFFFEE2E2),
    onErrorContainer = Color(0xFF7F1D1D),
    outline = Color(0xFF6B7F78),
    outlineVariant = Color(0xFFC5D1CD),
    scrim = Color(0xFF000000),
)

@Composable
fun PuxTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit
) {
    val colorScheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }
        darkTheme -> DarkColorScheme
        else -> LightColorScheme
    }

    val semantic = if (darkTheme) {
        PuxSemanticColors(
            successOnSurfaceVariant = PuxSuccessOnSurfaceVariantDark,
            warningOnSurfaceVariant = PuxWarningOnSurfaceVariantDark,
            warningOnSurface = PuxWarningOnSurfaceDark,
            errorOnSurface = PuxErrorOnSurfaceDark,
            secondaryOnSurface = Color(0xFF6EE7B7),
            tertiaryOnSurface = Color(0xFF34D399),
        )
    } else {
        PuxSemanticColors(
            successOnSurfaceVariant = PuxSuccessOnSurfaceVariantLight,
            warningOnSurfaceVariant = PuxWarningOnSurfaceVariantLight,
            warningOnSurface = PuxWarningOnSurfaceLight,
            errorOnSurface = PuxErrorOnSurfaceLight,
            secondaryOnSurface = PuxBrandDark,
            tertiaryOnSurface = Color(0xFF064E3B),
        )
    }

    CompositionLocalProvider(LocalPuxSemanticColors provides semantic) {
        MaterialTheme(
            colorScheme = colorScheme,
            content = content
        )
    }
}
