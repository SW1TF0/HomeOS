import SwiftUI
import SmartMenuCore

struct ScenesView: View {
    @Environment(\.palette) var p
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var nav: Nav

    var body: some View {
        VStack(spacing: 0) {
            ScreenTitle(title: "Scenes") {
                HStack(spacing: 8) {
                    NChip(label: "New", icon: "plus") { nav.sheet = .scene(newSceneId) }
                    ProfileButton()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if store.data.scenes.isEmpty {
                        Text("A scene puts many devices in their place with one tap: lights down for a film, everything off when you leave.")
                            .font(NType.body(14)).foregroundStyle(p.textDim).padding(.vertical, 8)
                    }
                    ForEach(store.data.scenes) { s in
                        NCard(padding: 16) {
                            HStack(spacing: 14) {
                                Image(systemName: sceneIcon(s.icon)).foregroundStyle(p.text)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name).font(NType.body(16, .medium)).foregroundStyle(p.text)
                                    Text((["\(s.actions.count) devices"] + (s.schedule.map { ["\($0.time) · \($0.daysLabel)"] } ?? [])).joined(separator: " · "))
                                        .font(NType.body(13)).foregroundStyle(p.textDim)
                                }
                                Spacer()
                                Button { nav.sheet = .scene(s.id) } label: { Image(systemName: "pencil").foregroundStyle(p.textDim).padding(8) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { store.runScene(s.id) }
                    }
                    Text("Tap a scene to run it. Timed scenes run while the app is open in this version.")
                        .font(NType.body(12)).foregroundStyle(p.textDim).padding(.top, 8)
                }
                .padding(.horizontal, 20).padding(.bottom, 28)
            }
        }
    }
}

/// Makes or changes a scene: its name, icon, time, and what each device does.
struct SceneEditor: View {
    @Environment(\.palette) var p
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var store: HomeStore
    var sceneId: String
    @State private var loaded = false
    @State private var name = ""
    @State private var icon = "auto"
    @State private var actions: [String: SceneAction] = [:]
    @State private var timed = false
    @State private var hour = 7
    @State private var minute = 0
    @State private var days: Set<Int> = Set(1...7)
    @State private var confirm = false

    var body: some View {
        let d = store.data
        let existing = d.scenes.first { $0.id == sceneId }
        NSheet {
            DotText(existing == nil ? "New scene" : "Scene", 26).padding(.bottom, 12)
            if existing == nil && name.isEmpty {
                FlowRow {
                    ForEach(SmartMenuCore.Scene.templates, id: \.0) { n, i in
                        NChip(label: n, icon: sceneIcon(i)) {
                            name = n; icon = i
                            let list = ["off", "away", "night"].contains(i)
                                ? d.devices.compactMap { SceneAction.turn($0, false) }
                                : d.devices.filter(\.countsAsOn).map(SceneAction.capture)
                            actions = Dictionary(list.map { ($0.deviceId, $0) }, uniquingKeysWith: { a, _ in a })
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            NTextField(label: "Name", text: $name)
            FlowRow {
                ForEach(sceneIconKeys, id: \.self) { k in
                    Button { icon = k } label: {
                        Image(systemName: sceneIcon(k)).foregroundStyle(icon == k ? Palette.accent : p.textDim).frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 12)
            SectionLabel(text: "Devices · \(actions.count)") {
                HeaderAction(label: "Use how they are now") {
                    let list = d.devices.filter { actions[$0.id] != nil || $0.countsAsOn }.map(SceneAction.capture)
                    actions = Dictionary(list.map { ($0.deviceId, $0) }, uniquingKeysWith: { a, _ in a })
                }
            }
            Text("For each device pick On (as it is now), Off, or leave it out.").font(NType.body(13)).foregroundStyle(p.textDim).padding(.bottom, 8)
            ForEach(d.devices) { dev in
                let a = actions[dev.id]
                HStack(spacing: 6) {
                    Image(systemName: deviceIcon(dev.kind)).foregroundStyle(p.text).frame(width: 24)
                    VStack(alignment: .leading) {
                        Text(dev.name).font(NType.body(14, .medium)).foregroundStyle(p.text).lineLimit(1)
                        Text(store.roomName(dev.roomId) ?? "No room").font(NType.body(12)).foregroundStyle(p.textDim)
                    }
                    Spacer()
                    NChip(label: "On", selected: a != nil && !a!.isOff) {
                        actions[dev.id] = dev.state.isActive ? SceneAction.capture(dev) : (SceneAction.turn(dev, true) ?? SceneAction.capture(dev))
                    }
                    if let off = SceneAction.turn(dev, false) {
                        NChip(label: "Off", selected: a?.isOff == true) { actions[dev.id] = off }
                    }
                    NChip(label: "—", selected: a == nil) { actions[dev.id] = nil }
                }
                .padding(.vertical, 4)
            }
            SectionLabel("Time")
            Toggle(isOn: $timed) { Text("Run by itself").font(NType.body(15, .medium)).foregroundStyle(p.text) }.tint(Palette.accent)
            if timed {
                HStack(spacing: 8) {
                    RoundButton(icon: "minus") { hour = (hour + 23) % 24 }
                    DotText(String(format: "%02d", hour), 44)
                    RoundButton(icon: "plus") { hour = (hour + 1) % 24 }
                    DotText(":", 44)
                    RoundButton(icon: "minus") { minute = (minute + 55) % 60 }
                    DotText(String(format: "%02d", minute), 44)
                    RoundButton(icon: "plus") { minute = (minute + 5) % 60 }
                }
                .padding(.vertical, 8)
                FlowRow(spacing: 6) {
                    ForEach(Array(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].enumerated()), id: \.offset) { i, n in
                        NChip(label: n, selected: days.contains(i + 1)) {
                            if days.contains(i + 1) { days.remove(i + 1) } else { days.insert(i + 1) }
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                PrimaryButton(label: "Save", enabled: !actions.isEmpty) {
                    store.saveScene(SmartMenuCore.Scene(
                        id: existing?.id ?? store.newSceneId(),
                        name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Scene" : name,
                        icon: icon,
                        actions: d.devices.compactMap { actions[$0.id] },
                        schedule: timed && !days.isEmpty ? SceneSchedule(hour: hour, minute: minute, days: days) : nil))
                    dismiss()
                }
                if let existing {
                    SecondaryButton(label: "Run") { store.runScene(existing.id) }
                    SecondaryButton(label: confirm ? "Tap again" : "Remove") {
                        if confirm { store.removeScene(existing.id); dismiss() } else { confirm = true }
                    }
                }
            }
            .padding(.top, 18)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let e = existing {
                name = e.name; icon = e.icon
                actions = Dictionary(e.actions.map { ($0.deviceId, $0) }, uniquingKeysWith: { a, _ in a })
                if let t = e.schedule { timed = true; hour = t.hour; minute = t.minute; days = t.days }
            }
        }
    }
}
