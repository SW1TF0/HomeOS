import SwiftUI
import SmartMenuCore

/// Apple-style colours: iOS system greys, black or white text, system blue for actions.
struct Palette: Equatable {
    var background: Color, surface: Color, surfaceHigh: Color, border: Color, text: Color, textDim: Color, dot: Color
    var dark: Bool

    /// Buttons, links, switches and anything selected.
    static let accent = Color(hex: 0x007AFF)
    /// Errors, deletes and devices that don't answer.
    static let red = Color(hex: 0xFF3B30)
    static let green = Color(hex: 0x34C759), yellow = Color(hex: 0xFFCC00), orange = Color(hex: 0xFF9500)
    static let purple = Color(hex: 0xAF52DE), blue = Color(hex: 0x007AFF), teal = Color(hex: 0x30B0C7)
    static let indigo = Color(hex: 0x5856D6), pink = Color(hex: 0xFF2D55)

    static let darkMode = Palette(background: Color(hex: 0x000000), surface: Color(hex: 0x1C1C1E), surfaceHigh: Color(hex: 0x2C2C2E),
                                  border: Color(hex: 0x38383A), text: Color(hex: 0xFFFFFF), textDim: Color(hex: 0x98989F),
                                  dot: Color(hex: 0x2C2C2E), dark: true)
    static let lightMode = Palette(background: Color(hex: 0xF2F2F7), surface: .white, surfaceHigh: Color(hex: 0xE5E5EA),
                                   border: Color(hex: 0xD1D1D6), text: Color(hex: 0x000000), textDim: Color(hex: 0x6C6C70),
                                   dot: Color(hex: 0xD1D1D6), dark: false)

    /// A device tile that is off (frosted grey), one that is on (white), and the text on it, as in Apple Home.
    var tileOff: Color { dark ? Color(hex: 0x3A3A3C).opacity(0.7) : Color.black.opacity(0.08) }
    var tileOn: Color { .white }
    var onTileOn: Color { .black }
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
