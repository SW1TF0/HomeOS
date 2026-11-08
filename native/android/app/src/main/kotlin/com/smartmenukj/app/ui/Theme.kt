package com.smartmenukj.app.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import com.smartmenukj.app.R

/** Apple-style colours: iOS system greys, black or white text, system blue for actions. */
@Immutable
data class Palette(
    val background: Color,
    val surface: Color,
    val surfaceHigh: Color,
    val border: Color,
    val text: Color,
    val textDim: Color,
    val dot: Color,
    val dark: Boolean,
) {
    val accent get() = Accent

    /** Background of a device tile that is off (frosted grey) and of one that is on (white), as in Apple Home. */
    val tileOff get() = if (dark) Color(0xB33A3A3C) else Color(0x14000000)
    val tileOn get() = Color.White
    val onTileOn get() = Color.Black

    companion object {
        /** Buttons, links, switches and anything selected. */
        val Accent = Color(0xFF007AFF)

        /** Errors, deletes and devices that don't answer. */
        val Red = Color(0xFFFF3B30)
        val Green = Color(0xFF34C759)
        val Yellow = Color(0xFFFFCC00)
        val Orange = Color(0xFFFF9500)
        val Purple = Color(0xFFAF52DE)
        val Blue = Color(0xFF007AFF)
        val Teal = Color(0xFF30B0C7)
        val Indigo = Color(0xFF5856D6)
        val Pink = Color(0xFFFF2D55)

        val Dark = Palette(
            background = Color(0xFF000000),
            surface = Color(0xFF1C1C1E),
            surfaceHigh = Color(0xFF2C2C2E),
            border = Color(0xFF38383A),
            text = Color(0xFFFFFFFF),
            textDim = Color(0xFF98989F),
            dot = Color(0xFF2C2C2E),
            dark = true,
        )

        val Light = Palette(
            background = Color(0xFFF2F2F7),
            surface = Color(0xFFFFFFFF),
            surfaceHigh = Color(0xFFE5E5EA),
            border = Color(0xFFD1D1D6),
            text = Color(0xFF000000),
            textDim = Color(0xFF6C6C70),
            dot = Color(0xFFD1D1D6),
            dark = false,
        )
    }
}

val LocalPalette = staticCompositionLocalOf { Palette.Dark }

/** Type styles. Inter (SIL OFL), the closest free font to Apple's San Francisco: bold headings, tight spacing. */
object NType {
    val Body = FontFamily(
        Font(R.font.inter_400, FontWeight.Normal),
        Font(R.font.inter_500, FontWeight.Medium),
        Font(R.font.inter_600, FontWeight.SemiBold),
        Font(R.font.inter_700, FontWeight.Bold),
    )

    /** Headings and big numbers. */
    fun dot(size: TextUnit, color: Color = Color.Unspecified, weight: Int = 700, spacing: TextUnit = (-0.025).em) =
        TextStyle(fontFamily = Body, fontWeight = FontWeight(weight.coerceAtMost(700)), fontSize = size, color = color,
            letterSpacing = spacing, lineHeight = size * 1.1)

    fun body(size: TextUnit, color: Color = Color.Unspecified, weight: Int = 400, spacing: TextUnit = 0.sp) =
        TextStyle(fontFamily = Body, fontWeight = FontWeight(weight), fontSize = size, color = color,
            letterSpacing = spacing, lineHeight = size * 1.3)

    /** Small section header. */
    fun label(color: Color = Color.Unspecified) = body(13.sp, color, 600)
}

@Composable
fun AppTheme(mode: String, content: @Composable () -> Unit) {
    val dark = when (mode) {
        "light" -> false
        "system" -> isSystemInDarkTheme()
        else -> true
    }
    val p = if (dark) Palette.Dark else Palette.Light
    val scheme = (if (dark) darkColorScheme() else lightColorScheme()).copy(
        primary = Palette.Accent,
        onPrimary = Color.White,
        secondary = Palette.Accent,
        onSecondary = Color.White,
        error = Palette.Red,
        background = p.background,
        onBackground = p.text,
        surface = p.surface,
        onSurface = p.text,
        surfaceVariant = p.surfaceHigh,
        onSurfaceVariant = p.textDim,
        surfaceContainer = p.surface,
        surfaceContainerHigh = p.surface,
        surfaceContainerHighest = p.surfaceHigh,
        surfaceContainerLow = p.surface,
        outline = p.border,
        outlineVariant = p.border,
    )
    val type = MaterialTheme.typography.let { t ->
        t.copy(
            displayLarge = NType.dot(64.sp),
            displayMedium = NType.dot(44.sp),
            displaySmall = NType.dot(32.sp),
            headlineMedium = NType.dot(26.sp),
            headlineSmall = NType.dot(22.sp),
            titleLarge = NType.body(20.sp, weight = 600),
            titleMedium = NType.body(16.sp, weight = 600),
            titleSmall = NType.body(14.sp, weight = 600),
            bodyLarge = NType.body(16.sp),
            bodyMedium = NType.body(14.sp),
            bodySmall = NType.body(12.sp),
            labelLarge = NType.body(14.sp, weight = 500),
            labelMedium = NType.body(12.sp, weight = 500),
            labelSmall = NType.label(),
        )
    }
    CompositionLocalProvider(LocalPalette provides p) {
        MaterialTheme(colorScheme = scheme, typography = type, content = content)
    }
}
