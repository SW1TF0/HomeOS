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
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import com.smartmenukj.app.R

/** Colours in the spirit of Nothing OS: black and white, greys, one red. */
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
    val accent get() = Red

    companion object {
        val Red = Color(0xFFD71921)

        val Dark = Palette(
            background = Color(0xFF000000),
            surface = Color(0xFF111111),
            surfaceHigh = Color(0xFF1C1C1C),
            border = Color(0xFF2A2A2A),
            text = Color(0xFFFFFFFF),
            textDim = Color(0xFF8C8C8C),
            dot = Color(0xFF262626),
            dark = true,
        )

        val Light = Palette(
            background = Color(0xFFF3F3F3),
            surface = Color(0xFFFFFFFF),
            surfaceHigh = Color(0xFFE9E9E9),
            border = Color(0xFFDADADA),
            text = Color(0xFF000000),
            textDim = Color(0xFF6E6E6E),
            dot = Color(0xFFD4D4D4),
            dark = false,
        )
    }
}

val LocalPalette = staticCompositionLocalOf { Palette.Dark }

/**
 * Type styles. Doto is a free (SIL OFL) dot-matrix font used for headings and numbers; Space Grotesk (SIL OFL) is
 * used for everything else. Both are variable fonts, so each weight is asked for by its axis.
 */
@OptIn(ExperimentalTextApi::class)
object NType {
    private fun doto(weight: Int) = Font(
        R.font.doto, FontWeight(weight),
        variationSettings = FontVariation.Settings(FontVariation.weight(weight), FontVariation.Setting("ROND", 100f)),
    )

    private fun grotesk(weight: Int) = Font(
        R.font.space_grotesk, FontWeight(weight),
        variationSettings = FontVariation.Settings(FontVariation.weight(weight)),
    )

    val Dot = FontFamily(doto(800), doto(600), doto(400))
    val Body = FontFamily(grotesk(300), grotesk(400), grotesk(500), grotesk(600), grotesk(700))

    fun dot(size: TextUnit, color: Color = Color.Unspecified, weight: Int = 800, spacing: TextUnit = 0.sp) =
        TextStyle(fontFamily = Dot, fontWeight = FontWeight(weight), fontSize = size, color = color,
            letterSpacing = spacing, lineHeight = size * 1.05)

    fun body(size: TextUnit, color: Color = Color.Unspecified, weight: Int = 400, spacing: TextUnit = 0.sp) =
        TextStyle(fontFamily = Body, fontWeight = FontWeight(weight), fontSize = size, color = color,
            letterSpacing = spacing, lineHeight = size * 1.3)

    /** Small all-caps label, like the section headers in Nothing OS. */
    fun label(color: Color = Color.Unspecified) = body(11.sp, color, 500, 0.16.em)
}

@Composable
fun NothingTheme(mode: String, content: @Composable () -> Unit) {
    val dark = when (mode) {
        "light" -> false
        "system" -> isSystemInDarkTheme()
        else -> true
    }
    val p = if (dark) Palette.Dark else Palette.Light
    val scheme = (if (dark) darkColorScheme() else lightColorScheme()).copy(
        primary = p.text,
        onPrimary = p.background,
        secondary = Palette.Red,
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
            titleLarge = NType.body(20.sp, weight = 500),
            titleMedium = NType.body(16.sp, weight = 500),
            titleSmall = NType.body(14.sp, weight = 500),
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
