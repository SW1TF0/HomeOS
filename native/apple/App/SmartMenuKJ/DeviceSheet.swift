import SwiftUI
import SmartMenuCore

struct DeviceSheet: View {
    @Environment(\.palette) var p
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var store: HomeStore
    var deviceId: String
    @State private var editing = false

    var body: some View {
        NSheet {
            if let d = store.data.device(deviceId) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        DotText(d.name, 28)
                        Text([store.roomName(d.roomId), Describe.state(d)].compactMap { $0 }.joined(separator: " · "))
                            .font(NType.body(14)).foregroundStyle(p.textDim)
                    }
                    Spacer()
                    Button { store.setFavorite(d.id, !d.favorite) } label: {
                        Image(systemName: d.favorite ? "star.fill" : "star").foregroundStyle(d.favorite ? Palette.accent : p.text).padding(8)
                    }.buttonStyle(.plain)
                    Button { editing.toggle() } label: { Image(systemName: "pencil").foregroundStyle(p.text).padding(8) }.buttonStyle(.plain)
                }
                if !store.canControl(d) {
                    NCard(padding: 14) {
                        Text("This device comes from a connection the native app cannot drive yet. It is kept as it was, and works again when that connection arrives here.")
                            .font(NType.body(13)).foregroundStyle(p.textDim)
                    }
                    .padding(.top, 12)
                }
                Group {
                    if editing { DeviceEditor(device: d) { editing = false } }
                    else { DeviceControls(device: d) { store.command(d.id, $0) } }
                }
                .padding(.top, 18)
            } else {
                Text("This device is gone.").font(NType.body(14)).foregroundStyle(p.textDim)
            }
        }
    }
}

struct Labeled<Content: View>: View {
    @Environment(\.palette) var p
    var label: String
    @ViewBuilder var content: () -> Content
    init(_ label: String, @ViewBuilder content: @escaping () -> Content) { self.label = label; self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(NType.label).foregroundStyle(p.textDim)
            content()
        }
    }
}

/// A draggable level from 0 to 1. Sends the value when the finger lifts.
struct LevelBar: View {
    @Environment(\.palette) var p
    var value: Double
    var label: (Double) -> String = Describe.pct
    var color: Color?
    var onSet: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        let v = (dragging ?? value).clamped01
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 18).fill(p.surfaceHigh)
                RoundedRectangle(cornerRadius: 18).fill(color ?? p.text).frame(width: max(g.size.width * v, 36))
                Text(label(v)).font(NType.body(14, .semibold))
                    .foregroundStyle(v > 0.25 ? (color == nil ? p.background : .black) : p.text).padding(.leading, 16)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragging = ($0.location.x / max(g.size.width, 1)).clamped01 }
                .onEnded { _ in if let d = dragging { onSet(d) }; dragging = nil })
        }
        .frame(height: 56)
    }
}

struct PowerOrb: View {
    @Environment(\.palette) var p
    var on: Bool
    var icon = "power"
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 30, weight: .medium)).foregroundStyle(on ? p.background : p.text)
                .frame(width: 96, height: 96)
                .background(Circle().fill(on ? p.text : p.surfaceHigh))
                .overlay(alignment: .topTrailing) { if on { Circle().fill(Palette.accent).frame(width: 10, height: 10).offset(x: -10, y: 10) } }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: on)
    }
}

struct ActionButton: View {
    @Environment(\.palette) var p
    var icon: String
    var label: String
    var active = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(active ? p.background : p.text)
                    .frame(width: 52, height: 52).background(Circle().fill(active ? p.text : p.surfaceHigh))
                Text(label).font(NType.body(11)).foregroundStyle(p.textDim)
            }
            .frame(width: 70)
        }
        .buttonStyle(.plain)
    }
}

struct RoundButton: View {
    @Environment(\.palette) var p
    var icon: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).foregroundStyle(p.text).frame(width: 56, height: 56).background(Circle().fill(p.surfaceHigh))
        }
        .buttonStyle(.plain)
    }
}

struct DeviceControls: View {
    @Environment(\.palette) var p
    var device: Device
    var send: (DeviceCommand) -> Void

    var body: some View {
        let d = device, s = device.state
        VStack(alignment: .leading, spacing: 18) {
            if d.has(.onOff) || d.has(.lock) {
                HStack(spacing: 16) {
                    if d.has(.onOff) { PowerOrb(on: s.on == true) { send(DeviceCommand(on: s.on != true)) } }
                    if d.has(.lock) {
                        PowerOrb(on: s.locked == false, icon: s.locked == false ? "lock.open" : "lock") { send(DeviceCommand(locked: s.locked != true)) }
                        Text(s.locked == false ? "Unlocked. Tap to lock." : "Locked. Tap to unlock.").font(NType.body(14)).foregroundStyle(p.textDim)
                    }
                }
            }
            if d.has(.brightness) {
                Labeled("Brightness") {
                    LevelBar(value: s.on == false ? 0 : s.brightness ?? 1) { send($0 < 0.01 ? DeviceCommand(on: false) : DeviceCommand(brightness: $0)) }
                    HStack(spacing: 8) {
                        ForEach([0.1, 0.25, 0.5, 0.75, 1.0], id: \.self) { v in NChip(label: Describe.pct(v)) { send(DeviceCommand(brightness: v)) } }
                    }
                }
            }
            if d.has(.colorTemp) {
                let k = Double(s.colorTempK ?? 3000)
                let v = ((k - 2200) / 4300).clamped01
                Labeled("White") {
                    LevelBar(value: v, label: { "\(Int(2200 + $0 * 4300)) K" }, color: ColorMath.kelvinToRgb(Int(2200 + v * 4300)).color) {
                        send(DeviceCommand(colorTempK: Int(2200 + $0 * 4300)))
                    }
                    HStack(spacing: 8) {
                        ForEach([("Warm", 2700), ("Neutral", 4000), ("Cool", 5500), ("Daylight", 6500)], id: \.1) { name, kk in
                            NChip(label: name, selected: s.color == nil && s.colorTempK == kk) { send(DeviceCommand(colorTempK: kk)) }
                        }
                    }
                }
            }
            if d.has(.color) { Labeled("Colour") { ColorRing(color: s.color) { send(DeviceCommand(color: $0)) } } }
            if d.has(.position) {
                Labeled(d.kind == .garage ? "Door" : "Open") {
                    LevelBar(value: s.position ?? 0) { send(DeviceCommand(position: $0)) }
                    HStack(spacing: 8) {
                        NChip(label: "Close") { send(DeviceCommand(position: 0)) }
                        NChip(label: "Half") { send(DeviceCommand(position: 0.5)) }
                        NChip(label: "Open") { send(DeviceCommand(position: 1)) }
                    }
                }
            }
            if d.has(.targetTemp) { Labeled("Temperature") { TempControl(state: s) { send(DeviceCommand(targetTemp: $0)) } } }
            if d.has(.speed) {
                Labeled("Speed") {
                    LevelBar(value: s.on == false ? 0 : s.speed ?? 0.5) { send($0 < 0.01 ? DeviceCommand(on: false) : DeviceCommand(speed: $0)) }
                }
            }
            if d.has(.humidity) {
                let lo = d.props["minHumidity"]?.double ?? 30, hi = d.props["maxHumidity"]?.double ?? 80
                Labeled("Humidity") {
                    LevelBar(value: ((s.targetHumidity ?? 50) - lo) / (hi - lo), label: { "\(Int((lo + $0 * (hi - lo)).rounded()))%" }) {
                        send(DeviceCommand(targetHumidity: (lo + $0 * (hi - lo)).rounded()))
                    }
                }
            }
            if d.has(.volume) {
                Labeled("Volume") {
                    HStack {
                        Button { send(DeviceCommand(muted: s.muted != true)) } label: {
                            Image(systemName: s.muted == true ? "speaker.slash" : "speaker.wave.2")
                                .foregroundStyle(s.muted == true ? Palette.accent : p.text).frame(width: 40, height: 40)
                        }.buttonStyle(.plain)
                        LevelBar(value: s.volume ?? 0) { send(DeviceCommand(volume: $0)) }
                    }
                }
            }
            if d.has(.remote) { Labeled("Remote") { RemotePad(device: d, send: send) } }
            if d.has(.run) || d.has(.dock) || d.has(.locate) {
                Labeled(Describe.activity(d.kind, s.activity) + (s.battery.map { " · \(Describe.pct($0))" } ?? "")) {
                    HStack(spacing: 4) {
                        if d.has(.run) {
                            let running = s.activity == Activity.running
                            ActionButton(icon: running ? "pause" : "play", label: running ? "Pause" : "Start", active: running) {
                                send(DeviceCommand(action: running ? .pause : .start))
                            }
                            if d.props["noStop"] == nil { ActionButton(icon: "stop", label: "Stop") { send(DeviceCommand(action: .stop)) } }
                        }
                        if d.has(.dock) { ActionButton(icon: "house", label: "Go home", active: s.activity == Activity.returning) { send(DeviceCommand(action: .dock)) } }
                        if d.has(.locate) { ActionButton(icon: "bell", label: "Find") { send(DeviceCommand(action: .locate)) } }
                    }
                }
            }
            if d.has(.alarm) { Labeled("Alarm") { AlarmControls(device: d, send: send) } }
            if d.has(.press) {
                PrimaryButton(label: d.kind == .button ? "Run" : "Press") { send(DeviceCommand(action: .press)) }
            }
            if d.has(.mode) && !d.modes.isEmpty {
                Labeled(d.kind == .vacuum ? "Suction" : d.kind == .media ? "Input" : "Mode") {
                    FlowRow {
                        ForEach(d.modes, id: \.self) { m in NChip(label: Describe.mode(m), selected: s.mode == m) { send(DeviceCommand(mode: m)) } }
                    }
                }
            }
            if !s.readings.isEmpty {
                Labeled("Readings") {
                    FlowRow(spacing: 10) {
                        ForEach(s.readings.sorted { $0.key < $1.key }, id: \.key) { k, v in
                            NCard(radius: 18, padding: 14) {
                                Text(k).font(NType.label).foregroundStyle(p.textDim)
                                DotText(v, 22).padding(.top, 4)
                            }
                            .fixedSize()
                        }
                    }
                }
            }
            if d.capabilities.isEmpty && s.readings.isEmpty {
                Text("Nothing to control on this one yet.").font(NType.body(14)).foregroundStyle(p.textDim)
            }
        }
    }
}

/// A hue ring: drag around it to pick a colour.
struct ColorRing: View {
    @Environment(\.palette) var p
    var color: Int?
    var onPick: (Int) -> Void
    @State private var picked: Double?

    static func hueAt(_ pt: CGPoint, _ c: CGPoint) -> Double {
        let deg = atan2(Double(pt.y - c.y), Double(pt.x - c.x)) * 180 / .pi
        return (deg + 450).truncatingRemainder(dividingBy: 360)
    }

    var body: some View {
        let hue = picked ?? color.map { ColorMath.rgbToHsv($0).h }
        HStack(spacing: 16) {
            GeometryReader { g in
                let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
                ZStack {
                    Circle().fill(AngularGradient(colors: (0...12).map { Color(hue: Double($0 % 12) / 12, saturation: 1, brightness: 1) },
                                                  center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)))
                    Circle().fill(p.background).padding(35)
                    Circle().fill(hue.map { ColorMath.hsvToRgb($0, 1, 1).color } ?? p.surfaceHigh)
                        .overlay(Circle().stroke(p.border)).padding(63)
                }
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { picked = Self.hueAt($0.location, c) }
                    .onEnded { _ in if let h = picked { onPick(ColorMath.hsvToRgb(h, 1, 1)) } })
            }
            .frame(width: 180, height: 180)
            VStack(spacing: 8) {
                ForEach([0xFF3B30, 0xFF9500, 0xFFD60A, 0x34C759, 0x0A84FF, 0xBF5AF2], id: \.self) { c in
                    Button { picked = ColorMath.rgbToHsv(c).h; onPick(c) } label: { Circle().fill(c.color).frame(width: 32, height: 32) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

struct TempControl: View {
    @Environment(\.palette) var p
    var state: DeviceState
    var onSet: (Double) -> Void
    @State private var target: Double?

    var body: some View {
        let t = target ?? state.targetTemp ?? 21
        HStack {
            RoundButton(icon: "minus") { let v = ((t - 0.5) * 2).rounded() / 2; target = v; onSet(v) }
            Spacer()
            VStack {
                DotText(String(format: "%.1f°", t), 56)
                if let now = state.currentTemp { Text(String(format: "Now %.1f°", now)).font(NType.body(13)).foregroundStyle(p.textDim) }
            }
            Spacer()
            RoundButton(icon: "plus") { let v = ((t + 0.5) * 2).rounded() / 2; target = v; onSet(v) }
        }
        .onChange(of: state.targetTemp) { _ in target = nil }
    }
}

struct RemotePad: View {
    var device: Device
    var send: (DeviceCommand) -> Void

    var body: some View {
        let keys = device.props["keys"]?.array.map { Set($0.map(\.description)) }
        let has = { (k: RemoteKey) in keys == nil || keys!.contains(k.rawValue) }
        let key = { (k: RemoteKey) in send(DeviceCommand(key: k)) }
        VStack(spacing: 12) {
            if keys == nil {
                RoundButton(icon: "chevron.up") { key(.up) }
                HStack(spacing: 12) {
                    RoundButton(icon: "chevron.left") { key(.left) }
                    RoundButton(icon: "circle") { key(.ok) }
                    RoundButton(icon: "chevron.right") { key(.right) }
                }
                RoundButton(icon: "chevron.down") { key(.down) }
            }
            HStack(spacing: 4) {
                if keys == nil {
                    ActionButton(icon: "arrow.uturn.backward", label: "Back") { key(.back) }
                    ActionButton(icon: "house", label: "Home") { key(.home) }
                }
                if has(.volumeDown) { ActionButton(icon: "speaker.wave.1", label: "Vol -") { key(.volumeDown) } }
                if has(.volumeUp) { ActionButton(icon: "speaker.wave.3", label: "Vol +") { key(.volumeUp) } }
            }
            HStack(spacing: 4) {
                if has(.rewind) { ActionButton(icon: "backward.end", label: "Back") { key(.rewind) } }
                if has(.playPause) { ActionButton(icon: "playpause", label: "Play") { key(.playPause) } }
                if has(.stop) { ActionButton(icon: "stop", label: "Stop") { key(.stop) } }
                if has(.forward) { ActionButton(icon: "forward.end", label: "Next") { key(.forward) } }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct AlarmControls: View {
    @Environment(\.palette) var p
    var device: Device
    var send: (DeviceCommand) -> Void
    @State private var code = ""

    var body: some View {
        let s = device.state
        let arms = device.props["arms"]?.array?.map(\.description) ?? ["home", "away"]
        VStack(alignment: .leading, spacing: 10) {
            DotText(Describe.activity(device.kind, s.activity), 28,
                    color: s.activity.map { Activity.busy.contains($0) } == true ? Palette.accent : nil)
            if device.props["codeFormat"] != nil { NTextField(label: "Code", text: $code, secret: true) }
            FlowRow {
                ForEach(arms, id: \.self) { a in
                    if let action = ["home": DeviceAction.armHome, "away": .armAway, "night": .armNight, "vacation": .armVacation][a] {
                        NChip(label: "Arm \(a)", selected: s.activity == action.alarmState) {
                            send(DeviceCommand(action: action, code: code.isEmpty ? nil : code))
                        }
                    }
                }
                NChip(label: "Disarm", selected: s.activity == Activity.disarmed) {
                    send(DeviceCommand(action: .disarm, code: code.isEmpty ? nil : code))
                }
            }
        }
    }
}

/// Rename a device, pick its room and kind, or remove it.
struct DeviceEditor: View {
    @Environment(\.palette) var p
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var store: HomeStore
    var device: Device
    var onDone: () -> Void
    @State private var name = ""
    @State private var confirm = false

    var body: some View {
        let d = device
        VStack(alignment: .leading, spacing: 14) {
            NTextField(label: "Name", text: $name)
            Labeled("Room") {
                FlowRow {
                    NChip(label: "No room", selected: d.roomId == nil) { store.setRoom(d.id, nil) }
                    ForEach(store.data.rooms) { r in NChip(label: r.name, selected: d.roomId == r.id) { store.setRoom(d.id, r.id) } }
                }
            }
            Labeled("Show as") {
                FlowRow {
                    ForEach(DeviceKind.allCases, id: \.self) { k in
                        NChip(label: k.label, selected: d.kind == k, icon: deviceIcon(k)) { store.setKind(d.id, k) }
                    }
                }
            }
            HStack(spacing: 10) {
                PrimaryButton(label: "Save") { store.renameDevice(d.id, name); onDone() }
                SecondaryButton(label: confirm ? "Tap again to remove" : "Remove") {
                    if confirm { store.removeDevice(d.id); dismiss() } else { confirm = true }
                }
            }
        }
        .onAppear { name = d.name }
    }
}
