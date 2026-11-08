import SwiftUI
import SmartMenuCore

@main
struct SmartMenuKJApp: App {
    @StateObject private var store: HomeStore
    @StateObject private var nav = Nav()
    @StateObject private var toasts = Toasts()
    @Environment(\.scenePhase) private var phase
    @AppStorage("checkSeconds") private var checkSeconds = 10

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmartMenuKJ/homes", isDirectory: true)
        let s = HomeStore(storage: FolderStorage(dir), http: URLSessionHttp())
        s.load()
        _store = StateObject(wrappedValue: s)
    }

    var body: some SwiftUI.Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(nav)
                .environmentObject(toasts)
                .onAppear {
                    let t = toasts
                    store.onMessage = { [weak t] m in t?.show(m) }
                    store.startPolling(checkSeconds)
                }
                .onChange(of: phase) { p in
                    if p == .active { store.startPolling(checkSeconds) } else { store.stopPolling(); store.saveNow() }
                }
                .onChange(of: checkSeconds) { s in store.startPolling(s) }
                .onReceive(Timer.publish(every: 60, tolerance: 2, on: .main, in: .common).autoconnect()) { _ in runDueScenes() }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif
    }

    /// Scene timers, checked once a minute while the app is open.
    private func runDueScenes() {
        let c = Calendar(identifier: .iso8601).dateComponents([.weekday, .hour, .minute], from: Date())
        // Calendar weekdays start on Sunday (1); scenes count Monday as 1.
        let day = ((c.weekday ?? 1) + 5) % 7 + 1
        store.runDueScenes(day: day, hour: c.hour ?? 0, minute: c.minute ?? 0)
    }
}

enum Tab: String, CaseIterable {
    case home = "Home", map = "Map", devices = "Devices", scenes = "Scenes", connect = "Connect"
    var icon: String {
        switch self {
        case .home: "house"
        case .map: "square.grid.3x3"
        case .devices: "rectangle.3.group"
        case .scenes: "wand.and.stars"
        case .connect: "point.3.connected.trianglepath.dotted"
        }
    }
}

enum Sheet: Identifiable, Equatable {
    case device(String), room(String), scene(String), integration(String), addIntegration(String), homes, addDevice
    var id: String {
        switch self {
        case .device(let s): "device:\(s)"
        case .room(let s): "room:\(s)"
        case .scene(let s): "scene:\(s)"
        case .integration(let s): "integration:\(s)"
        case .addIntegration(let s): "add:\(s)"
        case .homes: "homes"
        case .addDevice: "addDevice"
        }
    }
}

/// Which tab, sheet and page is open. Screens ask it to open each other.
@MainActor
final class Nav: ObservableObject {
    @Published var tab = Tab.home
    @Published var sheet: Sheet?
    @Published var settings = false
    @Published var mapEdit = false
    @Published var mapFloor: String?
    /// What Scan network found, for the add form to fill itself in from.
    @Published var found: FoundService?

    func openMap(edit: Bool = false, floorId: String? = nil) {
        mapEdit = edit
        if let floorId { mapFloor = floorId }
        tab = .map
    }
}

/// Short messages at the bottom of the screen.
@MainActor
final class Toasts: ObservableObject {
    @Published var text: String?
    private var hide: Task<Void, Never>?
    func show(_ m: String) {
        text = m
        hide?.cancel()
        hide = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled { self?.text = nil }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var toasts: Toasts
    @Environment(\.colorScheme) var scheme

    var palette: Palette {
        switch store.data.themeMode {
        case "light": .lightMode
        case "system": scheme == .dark ? .darkMode : .lightMode
        default: .darkMode
        }
    }

    var body: some View {
        let p = palette
        VStack(spacing: 0) {
            ZStack {
                p.background.ignoresSafeArea()
                if nav.settings { SettingsView() } else {
                    switch nav.tab {
                    case .home: HomeView()
                    case .map: MapView()
                    case .devices: DevicesView()
                    case .scenes: ScenesView()
                    case .connect: ConnectView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !nav.settings { BottomBar() }
        }
        .background(p.background.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let t = toasts.text {
                Text(t).font(NType.body(14, .medium)).foregroundStyle(p.background)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 16).fill(p.text))
                    .padding(.horizontal, 20).padding(.bottom, 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { toasts.text = nil }
            }
        }
        .animation(.easeOut(duration: 0.2), value: toasts.text)
        .sheet(item: $nav.sheet) { s in
            Group {
                switch s {
                case .device(let id): DeviceSheet(deviceId: id)
                case .room(let id): RoomSheet(roomId: id)
                case .scene(let id): SceneEditor(sceneId: id)
                case .integration(let id): IntegrationSheet(integrationId: id)
                case .addIntegration(let type): AddIntegrationSheet(type: type)
                case .homes: HomesSheet()
                case .addDevice: AddVirtualDeviceSheet()
                }
            }
            .environmentObject(store).environmentObject(nav).environmentObject(toasts)
            .environment(\.palette, p)
            .preferredColorScheme(p.dark ? .dark : .light)
        }
        .environment(\.palette, p)
        .preferredColorScheme(p.dark ? .dark : .light)
        .tint(Palette.accent)
    }
}

struct BottomBar: View {
    @Environment(\.palette) var p
    @EnvironmentObject var nav: Nav
    var body: some View {
        HStack {
            ForEach(Tab.allCases, id: \.self) { t in
                let on = nav.tab == t
                Button { nav.tab = t } label: {
                    VStack(spacing: 4) {
                        Image(systemName: t.icon).font(.system(size: 20)).foregroundStyle(on ? Palette.accent : p.textDim)
                        Text(t.rawValue).font(NType.body(11, .medium)).foregroundStyle(on ? Palette.accent : p.textDim)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(p.border.opacity(0.6)).frame(height: 0.5) }
    }
}

/// The round button top right that opens Settings.
struct ProfileButton: View {
    @Environment(\.palette) var p
    @EnvironmentObject var nav: Nav
    var body: some View {
        Button { nav.settings = true } label: {
            Image(systemName: "person").font(.system(size: 16)).foregroundStyle(p.text)
                .frame(width: 40, height: 40).background(Circle().fill(p.surfaceHigh))
        }
        .buttonStyle(.plain)
    }
}

extension HomeStore {
    func roomName(_ id: String?) -> String? { data.room(id)?.name }
}
