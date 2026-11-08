import Foundation

/// Colour conversions shared by the integrations. Colours are 0xRRGGBB.
public enum ColorMath {
    public static func miredToKelvin(_ mired: Double) -> Int { mired <= 0 ? 4000 : Int((1_000_000 / mired).rounded()) }
    public static func kelvinToMired(_ kelvin: Int) -> Int { kelvin <= 0 ? 250 : Int((1_000_000 / Double(kelvin)).rounded()) }

    public static func rgb(_ r: Int, _ g: Int, _ b: Int) -> Int { ((r & 0xff) << 16) | ((g & 0xff) << 8) | (b & 0xff) }
    public static func channels(_ c: Int) -> [Int] { [(c >> 16) & 0xff, (c >> 8) & 0xff, c & 0xff] }
    public static func hex(_ c: Int) -> String { String(format: "#%06x", c & 0xffffff) }

    public static func parseHex(_ hex: String?) -> Int? {
        guard let h = hex?.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces), h.count >= 6 else { return nil }
        return Int(h.prefix(6), radix: 16)
    }

    /// sRGB to CIE xy (Philips Hue / Zigbee colour space).
    public static func rgbToXy(_ color: Int) -> [Double] {
        func lin(_ v: Double) -> Double { v > 0.04045 ? pow((v + 0.055) / 1.055, 2.4) : v / 12.92 }
        let c = channels(color).map { lin(Double($0) / 255) }
        let x = c[0] * 0.4124 + c[1] * 0.3576 + c[2] * 0.1805
        let y = c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722
        let z = c[0] * 0.0193 + c[1] * 0.1192 + c[2] * 0.9505
        let sum = x + y + z
        if sum == 0 { return [0.3127, 0.3290] }
        return [x / sum, y / sum]
    }

    /// CIE xy at full brightness back to sRGB.
    public static func xyToRgb(_ x: Double, _ y: Double) -> Int {
        if y == 0 { return 0xffffff }
        let bigY = 1.0, bigX = (bigY / y) * x, bigZ = (bigY / y) * (1 - x - y)
        func gamma(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        let r = gamma(bigX * 3.2406 - bigY * 1.5372 - bigZ * 0.4986)
        let g = gamma(-bigX * 0.9689 + bigY * 1.8758 + bigZ * 0.0415)
        let b = gamma(bigX * 0.0557 - bigY * 0.2040 + bigZ * 1.0570)
        let mx = max(r, g, b, 1)
        func ch(_ v: Double) -> Int { Int((min(max(v / mx, 0), 1) * 255).rounded()) }
        return rgb(ch(r), ch(g), ch(b))
    }

    /// Rough colour of a white light at `kelvin`, for drawing it on screen.
    public static func kelvinToRgb(_ kelvin: Int) -> Int {
        let t = Double(kelvin) / 100
        let r, g, b: Double
        if t <= 66 {
            r = 255
            g = 99.4708025861 * log(t) - 161.1195681661
            b = t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
        } else {
            r = 329.698727446 * pow(t - 60, -0.1332047592)
            g = 288.1221695283 * pow(t - 60, -0.0755148492)
            b = 255
        }
        func c(_ v: Double) -> Int { Int(min(max(v, 0), 255).rounded()) }
        return rgb(c(r), c(g), c(b))
    }

    /// RGB to hue 0..360, saturation 0..1, value 0..1.
    public static func rgbToHsv(_ color: Int) -> (h: Double, s: Double, v: Double) {
        let c = channels(color).map { Double($0) / 255 }
        let mx = c.max()!, mn = c.min()!, d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == c[0] { h = 60 * ((c[1] - c[2]) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == c[1] { h = 60 * ((c[2] - c[0]) / d + 2) }
            else { h = 60 * ((c[0] - c[1]) / d + 4) }
        }
        return (h < 0 ? h + 360 : h, mx == 0 ? 0 : d / mx, mx)
    }

    public static func hsvToRgb(_ h: Double, _ s: Double, _ v: Double) -> Int {
        let c = v * s
        let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let x = c * (1 - abs((hh / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Double, Double, Double)
        switch Int(hh / 60) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        func ch(_ q: Double) -> Int { min(max(Int(((q + m) * 255).rounded()), 0), 255) }
        return rgb(ch(r), ch(g), ch(b))
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}
