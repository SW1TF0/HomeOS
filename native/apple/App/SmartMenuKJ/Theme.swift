import CoreText
import SwiftUI
import SmartMenuCore

/// Colours in the spirit of Nothing OS: black and white, greys, one red.
struct Palette: Equatable {
    var background: Color, surface: Color, surfaceHigh: Color, border: Color, text: Color, textDim: Color, dot: Color
    var dark: Bool

    static let red = Color(hex: 0xD71921)

    static let darkMode = Palette(background: Color(hex: 0x000000), surface: Color(hex: 0x111111), surfaceHigh: Color(hex: 0x1C1C1C),
                                  border: Color(hex: 0x2A2A2A), text: .white, textDim: Color(hex: 0x8C8C8C), dot: Color(hex: 0x262626),
                                  dark: true)
    static let lightMode = Palette(background: Color(hex: 0xF3F3F3), surface: .white, surfaceHigh: Color(hex: 0xE9E9E9),
                                   border: Color(hex: 0xDADADA), text: .black, textDim: Color(hex: 0x6E6E6E), dot: Color(hex: 0xD4D4D4),
                                   dark: false)
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

/// Doto is a free (SIL OFL) dot-matrix font used for headings and numbers; Space Grotesk (SIL OFL) is used for
/// everything else. Both ship inside the app and are registered at launch.
enum NType {
    static func register() {
        for name in ["Doto", "SpaceGrotesk"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    static func dot(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font { .custom("Doto", fixedSize: size).weight(weight) }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Space Grotesk", fixedSize: size).weight(weight) }
    /// Small all-caps label, like the section headers in Nothing OS.
    static let label = body(11, .medium)
}

/// The dot grid that sits behind Nothing OS screens.
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
