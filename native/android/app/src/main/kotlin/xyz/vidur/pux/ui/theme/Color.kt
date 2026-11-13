package xyz.vidur.pux.ui.theme

import androidx.compose.ui.graphics.Color

val PuxBrandDark = Color(0xFF0E3B32)
val PuxBrandTeal = Color(0xFF1E6B5C)
val PuxBrandLight = Color(0xFF2E8B57)

val PuxEmerald = Color(0xFF10B981)
val PuxWarning = Color(0xFFF59E0B)
val PuxError = Color(0xFFEF4444)

val DarkBackground = Color(0xFF121816)
val DarkSurface = Color(0xFF1B2421)
val DarkSurfaceVariant = Color(0xFF24302C)
val DarkOnBackground = Color(0xFFE8ECEB)

val LightBackground = Color(0xFFF8FAF9)
val LightSurface = Color(0xFFFFFFFF)
val LightSurfaceVariant = Color(0xFFEBF1EE)
val LightOnBackground = Color(0xFF1B2421)

/** Success/warning tints tuned for ≥4.5:1 on [LightSurfaceVariant] / [DarkSurfaceVariant]. */
val PuxSuccessOnSurfaceVariantLight = Color(0xFF047857)
val PuxSuccessOnSurfaceVariantDark = Color(0xFF34D399)
val PuxWarningOnSurfaceVariantLight = Color(0xFFC2410C)
val PuxWarningOnSurfaceVariantDark = Color(0xFFFBBF24)

/** Warning body text on default surface (QR enrollment hint). */
val PuxWarningOnSurfaceLight = PuxWarningOnSurfaceVariantLight
val PuxWarningOnSurfaceDark = PuxWarningOnSurfaceVariantDark

val PuxOnError = Color(0xFF121816)

/** Error foreground on [LightSurface] / [DarkSurface] (not error-container fills). */
val PuxErrorOnSurfaceLight = Color(0xFF7F1D1D)
val PuxErrorOnSurfaceDark = Color(0xFFFECACA)
