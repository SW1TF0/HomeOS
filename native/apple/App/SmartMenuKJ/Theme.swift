import SwiftUI
import SmartMenuCore

/// Colours from smarthomekj.eu: soft white and black surfaces, near-black text, one blue accent.
struct Palette: Equatable {
    var background: Color, surface: Color, surfaceHigh: Color, border: Color, text: Color, textDim: Color, dot: Color
    var dark: Bool

    /// Buttons, links, switches and anything selected.
    static let accent = Color(hex: 0x0071E3)
    /// Errors, deletes and devices that don't answer.
    static let red = Color(hex: 0xFF3B30)
    static let green = Color(hex: 0x34C759), yellow = Color(hex: 0xFFB800), orange = Color(hex: 0xFF9500)
    static let purple = Color(hex: 0xAF52DE), blue = Color(hex: 0x007AFF), teal = Color(hex: 0x30B0C7)
    static let indigo = Color(hex: 0x5856D6), pink = Color(hex: 0xFF2D55)

    static let darkMode = Palette(background: Color(hex: 0x000000), surface: Color(hex: 0x1C1C1E), surfaceHigh: Color(hex: 0x2C2C2E),
                                  border: Color(hex: 0x38383A), text: Color(hex: 0xF5F5F7), textDim: Color(hex: 0x98989D),
                                  dot: Color(hex: 0x2C2C2E), dark: true)
    static let lightMode = Palette(background: Color(hex: 0xF5F5F7), surface: .white, surfaceHigh: Color(hex: 0xE8E8ED),
                                   border: Color(hex: 0xD2D2D7), text: Color(hex: 0x1D1D1F), textDim: Color(hex: 0x6E6E73),
                                   dot: Color(hex: 0xD2D2D7), dark: false)

    /// A device tile that is off, one that is on (white, like the site's phone demo), and the text on it.
    var tileOff: Color { dark ? Color(hex: 0x1C1C1E) : Color(hex: 0xE3E3E8) }
    var tileOn: Color { dark ? Color(hex: 0xF5F5F7) : .white }
    var onTileOn: Color { Color(hex: 0x1D1D1F) }
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = Palette.darkMode }

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

extension Color {
    init(hex: Int) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

/// Type styles: the Apple system font, as on smarthomekj.eu. Bold headings, regular text.
enum NType {
    static func dot(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight == .heavy ? .bold : weight) }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    /// Small section header.
    static let label = body(13, .semibold)
}

/// The faint dot grid behind the floor plan.
struct DotGrid: View {
    var color: Color
    var spacing: CGFloat = 16
    var radius: CGFloat = 0.9
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}
