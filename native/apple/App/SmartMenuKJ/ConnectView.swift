import SwiftUI
import SmartMenuCore

struct ConnectView: View {
    @Environment(\.palette) var p
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var nav: Nav
    @StateObject private var scan = Scan()

    var body: some View {
        let d = store.data
        VStack(spacing: 0) {
            ScreenTitle(title: "Connect") { ProfileButton() }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        let integrations = d.integrations
                        scan.run { f in integrations.contains { known($0, f) } }
                    } label: {
                        NCard(inverted: true, padding: 18) {
                            HStack(spacing: 14) {
                                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(p.background)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(scan.running ? "Looking around your Wi-Fi…" : "Scan network").font(NType.body(16, .medium)).foregroundStyle(p.background)
                                    Text("Finds Hue, Shelly, WLED, Tasmota, ESPHome and Home Assistant").font(NType.body(13)).foregroundStyle(p.background.opacity(0.65))
                                }
                                Spacer()
                                if scan.running { ProgressView().tint(Palette.accent) }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    if !scan.running && scan.found.isEmpty && Scan.localAddress() == nil {
                        Text("This device is not on Wi-Fi, so Scan network only asks the Hue service. Join your home Wi-Fi to find everything.")
                            .font(NType.body(13)).foregroundStyle(p.textDim)
                    }
                    if !scan.found.isEmpty {
                        SectionLabel("Found · \(scan.found.count)", accent: true)
                        ForEach(scan.found) { f in
                            if let spec = Catalog.spec(f.integrationType) {
                                Row(icon: integrationIcon(spec.icon), title: f.name, subtitle: "\(spec.name) · \(f.host)", trailing: "plus") {
                                    nav.found = f
                                    scan.remove(f)
                                    nav.sheet = .addIntegration(spec.type)
                                }
                            }
                        }
                    }
                    if !d.integrations.isEmpty {
                        SectionLabel("Connected · \(d.integrations.count)")
                        ForEach(d.integrations) { cfg in
                            let spec = Catalog.spec(cfg.type)
                            let st = store.status[cfg.id]
                            let count = d.devices.filter { $0.integrationId == cfg.id }.count
                            let line = spec == nil ? "\(Catalog.laterNames[cfg.type] ?? cfg.type) · not in this version yet"
                                : st?.ok == false ? st!.message : "\(count) devices"
                            Row(icon: integrationIcon(spec?.icon ?? ""), title: cfg.name, subtitle: line,
                                warn: spec == nil || st?.ok == false, busy: store.busy.contains(cfg.id)) {
                                nav.sheet = .integration(cfg.id)
                            }
                        }
                    }
                    SectionLabel("Add a connection")
                    ForEach(Catalog.specs, id: \.type) { spec in
                        Row(icon: integrationIcon(spec.icon), title: spec.name, subtitle: spec.tagline, trailing: "chevron.right") {
                            if spec.fields.isEmpty {
                                if let cfg = store.addIntegration(spec.type) { nav.sheet = .integration(cfg.id) }
                            } else {
                                nav.found = nil
                                nav.sheet = .addIntegration(spec.type)
                            }
                        }
                    }
                    Text("Coming to the native app next: Matter, MQTT and Zigbee2MQTT, TVs and other network devices, cameras, and control from anywhere. The other SmartMenuKJ app has them today.")
                        .font(NType.body(12)).foregroundStyle(p.textDim).padding(.top, 8)
                }
                .padding(.horizontal, 20).padding(.bottom, 28)
            }
        }
    }

    /// Whether a connection already has the address that was found.
    private func known(_ cfg: IntegrationConfig, _ f: FoundService) -> Bool {
        cfg.settings.values.flatMap { parseHosts($0.string ?? "") }.contains { h in
            let bare = h.split(separator: "/").first.map(String.init) ?? h
            return (bare.split(separator: ":").first.map(String.init) ?? bare) == f.host
        }
    }
}

/// A card row with an icon, two lines and a trailing mark.
struct Row: View {
    @Environment(\.palette) var p
    var icon: String
    var title: String
    var subtitle: String
    var trailing: String?
    var warn = false
    var busy = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            NCard(padding: 16) {
                HStack(spacing: 14) {
                    Image(systemName: icon).foregroundStyle(p.text).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(NType.body(15, .medium)).foregroundStyle(p.text)
                        Text(subtitle).font(NType.body(13)).foregroundStyle(warn ? Palette.red : p.textDim).lineLimit(2)
                    }
                    Spacer()
                    if busy { ProgressView().tint(Palette.accent) }
                    else if let trailing { Image(systemName: trailing).foregroundStyle(p.textDim) }
                    else { Circle().fill(warn ? Palette.red : p.textDim).frame(width: 8, height: 8) }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// The form for a new connection, filled in from what Scan network found. Saving searches it for devices.
struct AddIntegrationSheet: View {
    @Environment(\.palette) var p
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var nav: Nav
    var type: String
    @State private var values: [String: String] = [:]
    @State private var loaded = false

    var body: some View {
        NSheet {
            if let spec = Catalog.spec(type) {
                HStack(spacing: 12) {
                    Image(systemName: integrationIcon(spec.icon)).foregroundStyle(p.text)
                    DotText(spec.name, 26)
                }
                Text(spec.description).font(NType.body(14)).foregroundStyle(p.textDim).padding(.top, 8)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(spec.fields, id: \.key) { f in
                        NTextField(label: f.label + (f.required ? "" : " (optional)"),
                                   text: Binding(get: { values[f.key] ?? "" }, set: { values[f.key] = $0 }),
                                   hint: f.hint, secret: f.secret, multiline: f.multiline)
                    }
                    let ready = spec.fields.filter(\.required).allSatisfy { !(values[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
                    PrimaryButton(label: spec.canPair ? "Add and pair" : "Add and search", enabled: ready) { add(spec) }
                    if spec.canPair {
                        Text("Press the round link button on the bridge first, then tap Add and pair within 30 seconds.")
                            .font(NType.body(13)).foregroundStyle(p.textDim)
                    }
                }
                .padding(.top, 16)
            }
        }
        .onAppear {
            guard !loaded, let spec = Catalog.spec(type) else { return }
            loaded = true
            for f in spec.fields { values[f.key] = f.defaultValue ?? "" }
            if let found = nav.found {
                for key in ["hosts", "host", "url"] where spec.fields.contains(where: { $0.key == key }) {
                    values[key] = found.address
                    break
                }
            }
        }
    }

    private func add(_ spec: IntegrationSpec) {
        let name = nav.found.flatMap { spec.type == "homeassistant" ? nil : $0.name } ?? spec.name
        guard let cfg = store.addIntegration(spec.type, name: name, settings: values) else { return }
        nav.found = nil
        nav.sheet = .integration(cfg.id)
        let pair = spec.canPair && (values["username"] ?? "").isEmpty
        Task {
            if pair { if await store.pair(cfg.id) { await store.sync(cfg.id) } } else { await store.sync(cfg.id) }
        }
    }
}

/// One connection: its devices, search again, pair, settings, remove.
struct IntegrationSheet: View {
    @Environment(\.palette) var p
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var nav: Nav
    var integrationId: String
    @State private var editing = false
    @State private var confirm = false
    @State private var name = ""
    @State private var values: [String: String] = [:]

    var body: some View {
        NSheet {
            if let cfg = store.data.integration(integrationId) {
                let spec = Catalog.spec(cfg.type)
                let devices = store.data.devices.filter { $0.integrationId == integrationId }
                let st = store.status[integrationId]
                DotText(cfg.name, 26)
                Text(spec == nil ? "\(Catalog.laterNames[cfg.type] ?? cfg.type) does not work in the native app yet. Its \(devices.count) devices are kept as they are."
                     : store.busy.contains(integrationId) ? "Working…" : st?.ok == false ? st!.message : "\(devices.count) devices")
                    .font(NType.body(14)).foregroundStyle(st?.ok == false ? Palette.red : p.textDim)
                if let spec {
                    HStack(spacing: 8) {
                        if !spec.fields.isEmpty || !spec.manualDevices {
                            NChip(label: "Search again", icon: "arrow.clockwise") { Task { await store.sync(integrationId) } }
                        }
                        if spec.canPair {
                            NChip(label: "Pair", icon: "link") { Task { if await store.pair(integrationId) { await store.sync(integrationId) } } }
                        }
                        if !spec.fields.isEmpty {
                            NChip(label: "Settings", selected: editing, icon: "slider.horizontal.3") {
                                name = cfg.name
                                values = Dictionary(uniqueKeysWithValues: spec.fields.map { ($0.key, cfg.setting($0.key)) })
                                editing.toggle()
                            }
                        }
                    }
                    .padding(.top, 14)
                    if editing {
                        VStack(alignment: .leading, spacing: 10) {
                            NTextField(label: "Name", text: $name)
                            ForEach(spec.fields, id: \.key) { f in
                                NTextField(label: f.label, text: Binding(get: { values[f.key] ?? "" }, set: { values[f.key] = $0 }),
                                           hint: f.hint, secret: f.secret, multiline: f.multiline)
                            }
                            PrimaryButton(label: "Save and search") {
                                store.updateIntegration(integrationId, name: name, settings: values)
                                editing = false
                                Task { await store.sync(integrationId) }
                            }
                        }
                        .padding(.top, 14)
                    }
                }
                if !devices.isEmpty {
                    SectionLabel("Devices")
                    ForEach(devices) { dev in
                        SettingRow(title: dev.name, subtitle: "\(store.roomName(dev.roomId) ?? "No room yet") · \(Describe.state(dev))") {
                            Image(systemName: deviceIcon(dev.kind)).foregroundStyle(p.textDim)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { nav.sheet = .device(dev.id) }
                    }
                }
                if spec?.manualDevices == true {
                    Text("Add virtual devices on the Devices tab.").font(NType.body(13)).foregroundStyle(p.textDim).padding(.top, 10)
                }
                SecondaryButton(label: confirm ? "Tap again to remove it and its devices" : "Remove connection") {
                    if confirm { store.removeIntegration(integrationId); dismiss() } else { confirm = true }
                }
                .padding(.top, 18)
            }
        }
    }
}
