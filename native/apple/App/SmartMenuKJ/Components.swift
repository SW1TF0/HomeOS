import SwiftUI
import SmartMenuCore

/// A rounded card with a hairline border. Inverted cards are white on black, like Nothing widgets that are on.
struct NCard<Content: View>: View {
    @Environment(\.palette) var p
    var inverted = false
    var radius: CGFloat = 24
    var padding: CGFloat = 18
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(inverted ? p.text : p.surface))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(inverted ? p.text : p.border, lineWidth: 1))
            .animation(.easeOut(duration: 0.2), value: inverted)
    }
}

/// "● LABEL" section header.
struct SectionLabel<Trailing: View>: View {
    @Environment(\.palette) var p
    var text: String
    var accent = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(accent ? Palette.red : p.textDim).frame(width: 6, height: 6)
            Text(text.uppercased()).font(NType.label).tracking(1.8).foregroundStyle(p.textDim)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 4).padding(.top, 22).padding(.bottom, 10)
    }
}

extension SectionLabel where Trailing == EmptyView {
    init(_ text: String, accent: Bool = false) { self.init(text: text, accent: accent) { EmptyView() } }
}

struct HeaderAction: View {
    @Environment(\.palette) var p
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Text(label).font(NType.body(13, .medium)).foregroundStyle(p.textDim) }.buttonStyle(.plain)
    }
}

/// A round, selectable chip.
struct NChip: View {
    @Environment(\.palette) var p
    var label: String
    var selected = false
    var icon: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 13)) }
                Text(label).font(NType.body(13, .medium)).lineLimit(1)
            }
            .foregroundStyle(selected ? p.background : p.text)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(selected ? p.text : p.surfaceHigh))
        }
        .buttonStyle(.plain)
    }
}

/// Dot-matrix text, for big numbers and titles.
struct DotText: View {
    @Environment(\.palette) var p
    var text: String
    var size: CGFloat = 32
    var color: Color?
    init(_ text: String, _ size: CGFloat = 32, color: Color? = nil) { self.text = text; self.size = size; self.color = color }
    var body: some View { Text(text).font(NType.dot(size)).foregroundStyle(color ?? p.text).lineLimit(1) }
}

struct PrimaryButton: View {
    @Environment(\.palette) var p
    var label: String
    var enabled = true
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(NType.body(15, .semibold)).foregroundStyle(p.background)
                .padding(.horizontal, 22).padding(.vertical, 13)
                .background(Capsule().fill(p.text.opacity(enabled ? 1 : 0.35)))
        }
        .buttonStyle(.plain).disabled(!enabled)
    }
}

struct SecondaryButton: View {
    @Environment(\.palette) var p
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(NType.body(15, .medium)).foregroundStyle(p.text)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .overlay(Capsule().stroke(p.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct NTextField: View {
    @Environment(\.palette) var p
    var label: String
    @Binding var text: String
    var hint = ""
    var secret = false
    var multiline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(NType.label).tracking(1.5).foregroundStyle(p.textDim)
            Group {
                if secret { SecureField(hint, text: $text) }
                else if multiline { TextField(hint, text: $text, axis: .vertical).lineLimit(2...6) }
                else { TextField(hint, text: $text) }
            }
            .textFieldStyle(.plain)
            .font(NType.body(15))
            .foregroundStyle(p.text)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(p.surfaceHigh))
        }
    }
}

struct SettingRow<Trailing: View>: View {
    @Environment(\.palette) var p
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(NType.body(15, .medium)).foregroundStyle(p.text)
                if let subtitle { Text(subtitle).font(NType.body(12)).foregroundStyle(p.textDim) }
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 8)
    }
}

/// The title row at the top of each screen.
struct ScreenTitle<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .center) {
            DotText(title, 34)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
    }
}

extension ScreenTitle where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

func deviceIcon(_ kind: DeviceKind, active: Bool = false) -> String {
    switch kind {
    case .light: active ? "lightbulb.fill" : "lightbulb"
    case .outlet: active ? "powerplug.fill" : "powerplug"
    case .toggle: "switch.2"
    case .sensor: "dot.radiowaves.left.and.right"
    case .climate: "thermometer.medium"
    case .cover: active ? "blinds.horizontal.open" : "blinds.horizontal.closed"
    case .fan: "fan"
    case .lock: active ? "lock.open" : "lock"
    case .media: active ? "tv.fill" : "tv"
    case .camera: "video"
    case .vacuum: "circle.dashed.inset.filled"
    case .mower: "leaf"
    case .purifier: "aqi.medium"
    case .humidifier: active ? "drop.fill" : "drop"
    case .appliance: "washer"
    case .alarm: "shield.lefthalf.filled"
    case .valve: "spigot"
    case .siren: "light.beacon.max"
    case .garage: "door.garage.closed"
    case .button: "play.circle"
    case .other: "square.grid.2x2"
    }
}

func integrationIcon(_ key: String) -> String {
    switch key {
    case "hub": "house"
    case "bulb": "lightbulb"
    case "plug": "powerplug"
    case "power": "power"
    case "strip": "light.strip.2"
    case "chip": "cpu"
    case "virtual": "cube.transparent"
    default: "link"
    }
}

let sceneIconKeys = ["auto", "morning", "day", "evening", "night", "movie", "away", "home", "off", "party", "relax", "work"]

func sceneIcon(_ key: String) -> String {
    switch key {
    case "morning": "sunrise"
    case "day": "sun.max"
    case "evening": "sunset"
    case "night": "moon"
    case "movie": "film"
    case "away": "figure.walk"
    case "home": "house"
    case "off": "power"
    case "party": "sparkles"
    case "relax": "cup.and.saucer"
    case "work": "laptopcomputer"
    default: "wand.and.stars"
    }
}

extension Int {
    var color: Color { Color(hex: self) }
}

/// A device on a grid: tap switches it, hold opens its controls, and a sideways drag sets its level.
struct DeviceTile: View {
    @Environment(\.palette) var p
    @EnvironmentObject var store: HomeStore
    var device: Device
    var roomName: String?
    var onOpen: () -> Void
    @State private var dragging: Double?
    @State private var width: CGFloat = 160

    var body: some View {
        let active = device.countsAsOn
        let level = Describe.level(device)
        let shown = dragging ?? level
        let fg = active ? p.background : p.text
        let glow = Describe.lightColor(device)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ZStack {
                    Circle().fill(active ? (glow?.color ?? p.background).opacity(glow == nil ? 0.08 : 0.35) : p.surfaceHigh)
                    Image(systemName: deviceIcon(device.kind, active: active)).font(.system(size: 17)).foregroundStyle(fg)
                }
                .frame(width: 38, height: 38)
                Spacer()
                if !device.state.reachable { Circle().fill(Palette.red).frame(width: 7, height: 7) }
                else if device.favorite { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(active ? fg.opacity(0.5) : p.textDim) }
            }
            Spacer(minLength: 14)
            Text(device.name).font(NType.body(15, .semibold)).foregroundStyle(fg).lineLimit(1)
            Text(dragging.map(Describe.pct) ?? Describe.state(device)).font(NType.body(12)).foregroundStyle(fg.opacity(0.65)).lineLimit(1)
            if let roomName { Text(roomName).font(NType.body(11)).foregroundStyle(fg.opacity(0.45)).lineLimit(1) }
            if let shown, dragging != nil || (active && level != nil) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(fg.opacity(0.15))
                        Capsule().fill(fg).frame(width: g.size.width * shown)
                    }
                }
                .frame(height: 3).padding(.top, 8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(active ? p.text : p.surface))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(active ? p.text : p.border, lineWidth: 1))
        .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width } })
        .contentShape(Rectangle())
        .onTapGesture { Describe.tapToggles(device) ? store.toggle(device.id) : onOpen() }
        .onLongPressGesture(minimumDuration: 0.4) { onOpen() }
        .simultaneousGesture(DragGesture(minimumDistance: 12)
            .onChanged { v in
                guard level != nil, abs(v.translation.width) > abs(v.translation.height) else { return }
                let start = Describe.level(device) ?? 0
                dragging = (start + v.translation.width / max(width, 1)).clamped01
            }
            .onEnded { _ in
                if let v = dragging, let c = Describe.levelCommand(device, v) { store.command(device.id, c) }
                dragging = nil
            })
        .animation(.easeOut(duration: 0.18), value: active)
    }
}

extension Double {
    var clamped01: Double { Swift.min(Swift.max(self, 0), 1) }
}

/// A sheet with the Nothing look: dark card, a grab bar, scrolling content.
struct NSheet<Content: View>: View {
    @Environment(\.palette) var p
    @Environment(\.dismiss) var dismiss
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0, content: content).padding(20)
        }
        .background(p.background.ignoresSafeArea())
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(p.textDim) }.buttonStyle(.plain).padding(16)
        }
        #else
        .presentationDragIndicator(.visible)
        #endif
        .environment(\.palette, p)
    }
}

/// A row of chips that wraps onto more lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxW { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
