package com.smartmenukj.core.util

import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.pow
import kotlin.math.roundToInt

/** Colour conversions shared by the integrations. Colours are 0xRRGGBB. */
object ColorMath {
    fun miredToKelvin(mired: Double): Int = if (mired <= 0) 4000 else (1_000_000 / mired).roundToInt()
    fun kelvinToMired(kelvin: Int): Int = if (kelvin <= 0) 250 else (1_000_000.0 / kelvin).roundToInt()

    fun rgb(r: Int, g: Int, b: Int): Int = ((r and 0xff) shl 16) or ((g and 0xff) shl 8) or (b and 0xff)
    fun channels(c: Int): IntArray = intArrayOf((c shr 16) and 0xff, (c shr 8) and 0xff, c and 0xff)
    fun hex(c: Int): String = "#%06x".format(c and 0xffffff)

    fun parseHex(hex: String?): Int? {
        val h = hex?.replace("#", "")?.trim() ?: return null
        if (h.length < 6) return null
        return h.substring(0, 6).toIntOrNull(16)
    }

    /** sRGB to CIE xy (Philips Hue / Zigbee colour space). */
    fun rgbToXy(color: Int): DoubleArray {
        val c = channels(color).map { it / 255.0 }
        fun lin(v: Double) = if (v > 0.04045) ((v + 0.055) / 1.055).pow(2.4) else v / 12.92
        val r = lin(c[0]); val g = lin(c[1]); val b = lin(c[2])
        val x = r * 0.4124 + g * 0.3576 + b * 0.1805
        val y = r * 0.2126 + g * 0.7152 + b * 0.0722
        val z = r * 0.0193 + g * 0.1192 + b * 0.9505
        val sum = x + y + z
        if (sum == 0.0) return doubleArrayOf(0.3127, 0.3290)
        return doubleArrayOf(x / sum, y / sum)
    }

    /** CIE xy at full brightness back to sRGB. */
    fun xyToRgb(x: Double, y: Double): Int {
        if (y == 0.0) return 0xffffff
        val bigY = 1.0
        val bigX = (bigY / y) * x
        val bigZ = (bigY / y) * (1 - x - y)
        fun gamma(v: Double) = if (v <= 0.0031308) 12.92 * v else 1.055 * v.pow(1 / 2.4) - 0.055
        val r = gamma(bigX * 3.2406 - bigY * 1.5372 - bigZ * 0.4986)
        val g = gamma(-bigX * 0.9689 + bigY * 1.8758 + bigZ * 0.0415)
        val b = gamma(bigX * 0.0557 - bigY * 0.2040 + bigZ * 1.0570)
        val mx = maxOf(r, g, b, 1.0)
        fun ch(v: Double) = ((v / mx).coerceIn(0.0, 1.0) * 255).roundToInt()
        return rgb(ch(r), ch(g), ch(b))
    }

    /** Rough colour of a white light at [kelvin], for drawing it on screen. */
    fun kelvinToRgb(kelvin: Int): Int {
        val t = kelvin / 100.0
        val r: Double; val g: Double; val b: Double
        if (t <= 66) {
            r = 255.0
            g = 99.4708025861 * ln(t) - 161.1195681661
            b = if (t <= 19) 0.0 else 138.5177312231 * ln(t - 10) - 305.0447927307
        } else {
            r = 329.698727446 * (t - 60).pow(-0.1332047592)
            g = 288.1221695283 * (t - 60).pow(-0.0755148492)
            b = 255.0
        }
        fun c(v: Double) = v.coerceIn(0.0, 255.0).roundToInt()
        return rgb(c(r), c(g), c(b))
    }

    /** RGB to hue 0..360, saturation 0..1, value 0..1. */
    fun rgbToHsv(color: Int): DoubleArray {
        val c = channels(color).map { it / 255.0 }
        val mx = c.max(); val mn = c.min(); val d = mx - mn
        var h = 0.0
        if (d > 0) {
            h = when (mx) {
                c[0] -> 60 * (((c[1] - c[2]) / d).mod(6.0))
                c[1] -> 60 * (((c[2] - c[0]) / d) + 2)
                else -> 60 * (((c[0] - c[1]) / d) + 4)
            }
        }
        return doubleArrayOf(if (h < 0) h + 360 else h, if (mx == 0.0) 0.0 else d / mx, mx)
    }

    fun hsvToRgb(h: Double, s: Double, v: Double): Int {
        val c = v * s
        val x = c * (1 - abs((h / 60).mod(2.0) - 1))
        val m = v - c
        val (r, g, b) = when (floor(h.mod(360.0) / 60).toInt()) {
            0 -> Triple(c, x, 0.0)
            1 -> Triple(x, c, 0.0)
            2 -> Triple(0.0, c, x)
            3 -> Triple(0.0, x, c)
            4 -> Triple(x, 0.0, c)
            else -> Triple(c, 0.0, x)
        }
        fun ch(q: Double) = ((q + m) * 255).roundToInt().coerceIn(0, 255)
        return rgb(ch(r), ch(g), ch(b))
    }
}
