package com.mansfera.lynxreminders.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import com.mansfera.lynxreminders.R

/**
 * SPEC §8 tokens (shared with Lynx Battery). Monochrome Ink on white; color is functional only
 * (list colors, overdue red). Material 3 is mapped onto these tokens so stock components never
 * show their default purple.
 */
@Immutable
data class LynxColors(
    val dark: Boolean,
    val bg: Color,
    val panel: Color,
    val sunk: Color,
    val fg: Color,
    val ink2: Color,
    val muted: Color,
    val line: Color,
    val mist: Color,
    val signal: Color,
) {
    /** Light: vertical sky (#A9B3C6 → #C9D0DC at 45% → #EEF0F3). Dark: radial #2A2D35 → #0E0E10 from the bottom. */
    fun stage(widthPx: Float, heightPx: Float): Brush = if (dark) {
        Brush.radialGradient(listOf(Color(0xFF2A2D35), Color(0xFF0E0E10)), center = androidx.compose.ui.geometry.Offset(widthPx / 2, heightPx), radius = maxOf(widthPx, heightPx) * 0.9f)
    } else {
        Brush.verticalGradient(0f to Color(0xFFA9B3C6), 0.45f to Color(0xFFC9D0DC), 1f to Color(0xFFEEF0F3))
    }

    /** Toggle "on" track: a white track in dark mode would hide the white knob (same fix as Lynx Battery). */
    val toggleOn: Color get() = if (dark) mist else fg

    fun listColor(token: String?): Color = when (token) {
        "slate" -> Color(0xFF5E6B85)
        "blue" -> Color(0xFF2F7CF6)
        "green" -> Color(0xFF30D158)
        "yellow" -> Color(0xFFF5B400)
        "orange" -> Color(0xFFF07C2A)
        "red" -> Color(0xFFE8271E)
        "pink" -> Color(0xFFE0559A)
        "brown" -> Color(0xFF9A7B5B)
        else -> fg // ink: #0E0E10, white in dark
    }
}

val LightLynx = LynxColors(
    dark = false,
    bg = Color.White, panel = Color.White, sunk = Color(0xFFF1F3F7), fg = Color(0xFF0E0E10),
    ink2 = Color(0xFF3A3D45), muted = Color(0xFF6A6F7C), line = Color(0x1F0E0E10), mist = Color(0xFFB3BCCD), signal = Color(0xFFE8271E),
)

val DarkLynx = LynxColors(
    dark = true,
    bg = Color(0xFF101012), panel = Color(0xFF1A1A1D), sunk = Color(0xFF17171A), fg = Color.White,
    ink2 = Color.White.copy(alpha = 0.78f), muted = Color.White.copy(alpha = 0.55f), line = Color.White.copy(alpha = 0.10f),
    mist = Color(0xFFB3BCCD), signal = Color(0xFFFF453A),
)

val LocalLynx = staticCompositionLocalOf { LightLynx }

@OptIn(androidx.compose.ui.text.ExperimentalTextApi::class)
private fun onestF(w: Int) = Font(R.font.onest, FontWeight(w), variationSettings = FontVariation.Settings(FontVariation.weight(w)))

/** Onest for all text and display, Geist Mono for times, counts and dates (both variable fonts). */
private fun onest(w: Int) = onestF(w)
@OptIn(androidx.compose.ui.text.ExperimentalTextApi::class)
private fun geist(w: Int) = Font(R.font.geist_mono, FontWeight(w), variationSettings = FontVariation.Settings(FontVariation.weight(w)))

val Onest = FontFamily(onest(400), onest(500), onest(600), onest(700))
val GeistMono = FontFamily(geist(400), geist(500), geist(600))

/**
 * Type scale. SPEC §8 sizes are macOS popover points; on a phone the same roles are scaled by
 * ~1.15 so rows stay readable at arm's length while keeping the hierarchy (hero 84 vs row 16 ≈ 5×).
 */
object LynxType {
    val hero = TextStyle(fontFamily = Onest, fontWeight = FontWeight.Medium, fontSize = 84.sp, letterSpacing = (-0.048).em, lineHeight = 84.sp)
    val heroUnit = TextStyle(fontFamily = Onest, fontWeight = FontWeight.Medium, fontSize = 30.sp)
    val stat = TextStyle(fontFamily = Onest, fontWeight = FontWeight.Medium, fontSize = 28.sp, letterSpacing = (-0.029).em, lineHeight = 32.sp)
    val screenTitle = TextStyle(fontFamily = Onest, fontWeight = FontWeight.Medium, fontSize = 30.sp, letterSpacing = (-0.027).em, lineHeight = 34.sp)
    val title = TextStyle(fontFamily = Onest, fontWeight = FontWeight.SemiBold, fontSize = 18.sp, lineHeight = 24.sp)
    val row = TextStyle(fontFamily = Onest, fontWeight = FontWeight.Normal, fontSize = 16.sp, lineHeight = 21.sp)
    val rowMedium = row.copy(fontWeight = FontWeight.Medium)
    val body = TextStyle(fontFamily = Onest, fontWeight = FontWeight.Normal, fontSize = 14.5.sp, lineHeight = 20.sp)
    val caption = TextStyle(fontFamily = Onest, fontWeight = FontWeight.Normal, fontSize = 12.5.sp, lineHeight = 16.sp)
    val captionMedium = caption.copy(fontWeight = FontWeight.Medium)
    val label = TextStyle(fontFamily = Onest, fontWeight = FontWeight.Medium, fontSize = 14.sp, lineHeight = 18.sp)
    val mono = TextStyle(fontFamily = GeistMono, fontWeight = FontWeight.Medium, fontSize = 12.sp, lineHeight = 15.sp)
    val monoSmall = TextStyle(fontFamily = GeistMono, fontWeight = FontWeight.Normal, fontSize = 10.sp, lineHeight = 12.sp)
}

/** Spacing scale from SPEC §8: 4/6/10/12/14/18/24. */
object Sp {
    val s4 = androidx.compose.ui.unit.Dp(4f)
    val s6 = androidx.compose.ui.unit.Dp(6f)
    val s10 = androidx.compose.ui.unit.Dp(10f)
    val s12 = androidx.compose.ui.unit.Dp(12f)
    val s14 = androidx.compose.ui.unit.Dp(14f)
    val s18 = androidx.compose.ui.unit.Dp(18f)
    val s24 = androidx.compose.ui.unit.Dp(24f)
}

private fun scheme(c: LynxColors): ColorScheme {
    val base = if (c.dark) darkColorScheme() else lightColorScheme()
    return base.copy(
        primary = c.fg, onPrimary = c.bg, primaryContainer = c.sunk, onPrimaryContainer = c.fg,
        secondary = c.ink2, onSecondary = c.bg, secondaryContainer = c.sunk, onSecondaryContainer = c.fg,
        tertiary = c.ink2, onTertiary = c.bg, tertiaryContainer = c.sunk, onTertiaryContainer = c.fg,
        background = c.bg, onBackground = c.fg, surface = c.panel, onSurface = c.fg,
        surfaceVariant = c.sunk, onSurfaceVariant = c.muted, surfaceTint = Color.Transparent,
        surfaceContainerLowest = c.panel, surfaceContainerLow = c.panel, surfaceContainer = c.panel,
        surfaceContainerHigh = c.panel, surfaceContainerHighest = c.sunk, surfaceBright = c.panel, surfaceDim = c.sunk,
        inverseSurface = c.fg, inverseOnSurface = c.bg, inversePrimary = c.bg,
        outline = c.line, outlineVariant = c.line, scrim = Color.Black.copy(alpha = 0.4f),
        error = c.signal, onError = Color.White, errorContainer = c.sunk, onErrorContainer = c.signal,
    )
}

private val typography = Typography().let { t ->
    Typography(
        displayLarge = LynxType.hero, displayMedium = LynxType.screenTitle, displaySmall = LynxType.stat,
        headlineLarge = LynxType.screenTitle, headlineMedium = LynxType.stat, headlineSmall = LynxType.title,
        titleLarge = LynxType.title, titleMedium = LynxType.rowMedium, titleSmall = LynxType.label,
        bodyLarge = LynxType.row, bodyMedium = LynxType.body, bodySmall = LynxType.caption,
        labelLarge = LynxType.label, labelMedium = LynxType.captionMedium, labelSmall = LynxType.caption,
    )
}

@Composable
fun LynxTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val c = if (dark) DarkLynx else LightLynx
    CompositionLocalProvider(LocalLynx provides c) {
        MaterialTheme(colorScheme = scheme(c), typography = typography, content = content)
    }
}

val lynx: LynxColors @Composable get() = LocalLynx.current
