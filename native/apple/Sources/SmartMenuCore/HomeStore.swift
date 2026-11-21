import Foundation
#if canImport(Combine)
import Combine
#endif

/// Where homes are kept: small named text files.
public protocol HomeStorage: AnyObject {
    func read(_ name: String) -> String?
    func write(_ name: String, _ text: String)
    func delete(_ name: String)
}

public final class MemoryStorage: HomeStorage {
    public var files: [String: String] = [:]
    public init() {}
    public func read(_ name: String) -> String? { files[name] }
    public func write(_ name: String, _ text: String) { files[name] = text }
    public func delete(_ name: String) { files[name] = nil }
}

/// Files in a folder (the app's Application Support folder on iPhone and Mac).
public final class FolderStorage: HomeStorage {
    let dir: URL
    public init(_ dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    public func read(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
    public func write(_ name: String, _ text: String) {
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    public func delete(_ name: String) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
}

/// How a connection did the last time it was used.
public struct IntegrationStatus: Equatable, Sendable {
    public var ok: Bool
    public var message: String
    public var at = Date()
}

#if canImport(Combine)
public typealias StoreObject = ObservableObject
#else
public protocol StoreObject: AnyObject {}
#endif

/// Everything the app knows and does with a home. The screens read it and call these methods; nothing else changes a
/// home. Saves a moment after each change.
@MainActor
public final class HomeStore: StoreObject {
    public static let defaultHome = "My home"
    static let homesFile = "homes.json"
    static let minRoom = 2.0
    static func homeFile(_ id: String) -> String { "home-\(id).json" }

    #if canImport(Combine)
    @Published public private(set) var loaded = false
    @Published public private(set) var homes: [HomeEntry] = []
    @Published public private(set) var homeId = ""
    @Published public private(set) var data = HomeData()
    @Published public private(set) var status: [String: IntegrationStatus] = [:]
    /// Connections being searched or paired right now.
    @Published public private(set) var busy: Set<String> = []
    @Published public private(set) var canUndo = false
    #else
    public private(set) var loaded = false
    public private(set) var homes: [HomeEntry] = []
    public private(set) var homeId = ""
    public private(set) var data = HomeData()
    public private(set) var status: [String: IntegrationStatus] = [:]
    public private(set) var busy: Set<String> = []
    public private(set) var canUndo = false
    #endif

    public var home: HomeEntry? { homes.first { $0.id == homeId } }

    /// Short messages for the user ("Hue: added 3 new devices.").
    public var onMessage: (String) -> Void = { _ in }
    /// Called after every save, so a backup file can follow.
    public var onSaved: () -> Void = {}

    private let storage: HomeStorage
    private let http: Http
    private let newId: () -> String
    private let saveDelay: Double
    private var drivers: [String: IntegrationDriver] = [:]
    private var saveTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var undo: [HomeData] = []

    public init(storage: HomeStorage, http: Http, saveDelay: Double = 0.4,
                newId: @escaping () -> String = { String(UUID().uuidString.lowercased().prefix(8)) }) {
        self.storage = storage; self.http = http; self.saveDelay = saveDelay; self.newId = newId
    }

    // MARK: Loading and saving

    public func load() {
        let list = storage.read(Self.homesFile).flatMap { try? JSON.parse($0) }
        var entries = list?["homes"]?.array?.compactMap { e -> HomeEntry? in
            guard let id = e["id"]?.string else { return nil }
            return HomeEntry(id: id, name: e["name"]?.string ?? Self.defaultHome)
        } ?? []
        var current = list?["current"]?.string
        if entries.isEmpty {
            entries = [HomeEntry(id: "home", name: Self.defaultHome)]
            current = "home"
            storage.write(Self.homeFile("home"), Seed.sampleHome().json().text())
            writeHomes(entries, "home")
        }
        let id = entries.first { $0.id == current }?.id ?? entries[0].id
        homes = entries
        homeId = id
        data = readHome(id) ?? Seed.emptyHome()
        loaded = true
        startDrivers()
    }

    private func readHome(_ id: String) -> HomeData? {
        storage.read(Self.homeFile(id)).flatMap { try? JSON.parse($0) }.map(HomeData.init(json:))
    }

    private func writeHomes(_ list: [HomeEntry], _ current: String) {
        let j: JSON = ["current": .string(current), "homes": .array(list.map { ["id": .string($0.id), "name": .string($0.name)] })]
        storage.write(Self.homesFile, j.text())
    }

    private func saveSoon() {
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            self?.saveNow()
        }
    }

    public func saveNow() {
        guard loaded else { return }
        storage.write(Self.homeFile(homeId), data.json().text())
        writeHomes(homes, homeId)
        onSaved()
    }

    private func change(layout: Bool = false, save: Bool = true, _ f: (inout HomeData) -> Void) {
        if layout {
            undo.append(data)
            if undo.count > 30 { undo.removeFirst() }
        }
        var d = data
        f(&d)
        data = d
        canUndo = !undo.isEmpty
        if save { saveSoon() }
    }

    private func device(_ id: String, _ f: (inout Device) -> Void) {
        change { d in
            if let i = d.devices.firstIndex(where: { $0.id == id }) { f(&d.devices[i]) }
        }
    }

    // MARK: Connections

    private func startDrivers() {
        drivers = [:]
        for cfg in data.integrations where cfg.enabled {
            guard let spec = Catalog.spec(cfg.type) else { continue }
            drivers[cfg.id] = spec.create(cfg, http)
        }
    }

    /// Whether this app can control `device` (its connection is one this app has).
    public func canControl(_ device: Device) -> Bool { drivers[device.integrationId] != nil }

    @discardableResult
    public func addIntegration(_ type: String, name: String? = nil, settings: [String: String] = [:]) -> IntegrationConfig? {
        guard let spec = Catalog.spec(type) else { return nil }
        if type == "demo", let existing = data.integrations.first(where: { $0.type == "demo" }) { return existing }
        let cfg = IntegrationConfig(id: "\(type)-\(newId())", type: type, name: name ?? spec.name,
                                    settings: settings.mapValues { .string($0) })
        change { $0.integrations.append(cfg) }
        startDrivers()
        return cfg
    }

    public func updateIntegration(_ id: String, name: String, settings: [String: String]) {
        change { d in
            if let i = d.integrations.firstIndex(where: { $0.id == id }) {
                d.integrations[i].name = name
                for (k, v) in settings { d.integrations[i].settings[k] = .string(v) }
            }
        }
        startDrivers()
    }

    /// Removes a connection and every device that came from it.
    public func removeIntegration(_ id: String) {
        change { d in
            let gone = Set(d.devices.filter { $0.integrationId == id }.map(\.id))
            d.integrations.removeAll { $0.id == id }
            d.devices.removeAll { $0.integrationId == id }
            for i in d.scenes.indices { d.scenes[i].actions.removeAll { gone.contains($0.deviceId) } }
        }
        startDrivers()
    }

    /// Pairs a connection that needs it (Hue's link button) and keeps what it was given.
    @discardableResult
    public func pair(_ id: String) async -> Bool {
        guard let driver = drivers[id], let cfg = data.integration(id) else { return false }
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            let got = try await driver.pair()
            updateIntegration(id, name: cfg.name, settings: got)
            onMessage("\(cfg.name): paired.")
            return true
        } catch {
            status[id] = IntegrationStatus(ok: false, message: "\(error)")
            onMessage("\(cfg.name): \(error)")
            return false
        }
    }

    /// Finds the devices of a connection. New ones are added without a room; known ones keep where they are.
    @discardableResult
    public func sync(_ id: String) async -> Int {
        guard let driver = drivers[id], let cfg = data.integration(id) else { return 0 }
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            let found = try await driver.discover()
            var added = 0
            change { d in
                for f in found {
                    if let i = d.devices.firstIndex(where: { $0.id == f.id }) {
                        // Keep what was learned later (pairing tokens, keys...).
                        d.devices[i].props.merge(f.props) { $1 }
                        d.devices[i].capabilities = f.capabilities
                        d.devices[i].state = d.devices[i].state.merging(f.state)
                    } else {
                        d.devices.append(f)
                        added += 1
                    }
                }
            }
            status[id] = IntegrationStatus(ok: true, message: "\(found.count) devices")
            onMessage(added == 0 ? "\(cfg.name): \(found.count) devices, nothing new." : "\(cfg.name): added \(added) new devices.")
            return added
        } catch {
            status[id] = IntegrationStatus(ok: false, message: "\(error)")
            onMessage("\(cfg.name): \(error)")
            return 0
        }
    }

    /// Reads the state of every device from its connection.
    public func refreshAll() async {
        let d = data
        var jobs: [(IntegrationDriver, [Device])] = []
        for cfg in d.integrations where cfg.enabled && Catalog.spec(cfg.type)?.polls == true {
            guard let driver = drivers[cfg.id] else { continue }
            let mine = d.devices.filter { $0.integrationId == cfg.id }
            if !mine.isEmpty { jobs.append((driver, mine)) }
        }
        if jobs.isEmpty { return }
        let merged = await withTaskGroup(of: [String: DeviceState].self) { group in
            for (driver, mine) in jobs { group.addTask { await driver.refreshAll(mine) } }
            var all: [String: DeviceState] = [:]
            for await r in group { all.merge(r) { $1 } }
            return all
        }
        if merged.isEmpty { return }
        change(save: false) { h in
            for i in h.devices.indices { if let s = merged[h.devices[i].id] { h.devices[i].state = s } }
        }
    }

    /// Reads every device now and then every `seconds` while the app is open.
    public func startPolling(_ seconds: Int) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 3)) * 1_000_000_000)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Devices

    /// Shows the change at once and sends it. If the device refuses, it goes back to how it was and the user is told why.
    public func command(_ deviceId: String, _ c: DeviceCommand) {
        Task { await send(deviceId, c) }
    }

    @discardableResult
    public func send(_ deviceId: String, _ c: DeviceCommand) async -> Bool {
        guard let dev = data.device(deviceId) else { return false }
        let before = dev.state
        if c.key == nil || c.key == .mute || c.key == .power { device(deviceId) { $0.state = $0.state.applying(c) } }
        guard let driver = drivers[dev.integrationId] else {
            device(deviceId) { $0.state = before }
            onMessage("\(dev.name): this connection does not work in this version yet.")
            return false
        }
        do {
            if let confirmed = try await driver.send(data.device(deviceId) ?? dev, c) {
                device(deviceId) { $0.state = $0.state.merging(confirmed) }
            }
            return true
        } catch {
            device(deviceId) { $0.state = before }
            onMessage("\(dev.name): \(error)")
            return false
        }
    }

    /// The main switch of a device: on/off, open/close, lock/unlock, start/go home.
    public func toggle(_ deviceId: String) {
        guard let d = data.device(deviceId) else { return }
        let s = d.state
        let c: DeviceCommand
        if d.has(.onOff) { c = DeviceCommand(on: s.on != true) }
        else if d.has(.position) { c = DeviceCommand(position: (s.position ?? 0) > 0.01 ? 0 : 1) }
        else if d.has(.lock) { c = DeviceCommand(locked: s.locked != true) }
        else if d.has(.run) {
            c = DeviceCommand(action: s.activity == Activity.running ? (d.has(.dock) ? .dock : .pause) : .start)
        } else if d.has(.press) { c = DeviceCommand(action: .press) }
        else { return }
        command(deviceId, c)
    }

    public func renameDevice(_ id: String, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { device(id) { $0.name = n } }
    }

    public func setFavorite(_ id: String, _ favorite: Bool) { device(id) { $0.favorite = favorite } }

    public func setKind(_ id: String, _ kind: DeviceKind) { device(id) { $0.kind = kind } }

    /// Puts a device in a room. It is placed on the map inside the room unless it already is.
    public func setRoom(_ id: String, _ roomId: String?) {
        let room = data.room(roomId)
        change(layout: true) { d in
            guard let i = d.devices.firstIndex(where: { $0.id == id }) else { return }
            guard let room else { d.devices[i].roomId = nil; return }
            let dev = d.devices[i]
            let inside = dev.mapPos.map { room.contains($0) && dev.floorId == room.floorId } == true
            if !inside { d.devices[i].mapPos = Self.freeSpot(d, room) }
            d.devices[i].roomId = room.id
            d.devices[i].floorId = room.floorId
        }
    }

    /// Moves a device on the map. Dropped inside a room, it belongs to that room.
    public func moveDevice(_ id: String, floorId: String, _ pos: MapPos) {
        change(layout: true) { d in
            let room = d.rooms(on: floorId).last { $0.contains(pos) }
            guard let i = d.devices.firstIndex(where: { $0.id == id }) else { return }
            d.devices[i].mapPos = pos
            d.devices[i].floorId = floorId
            d.devices[i].roomId = room?.id
        }
    }

    public func removeDevice(_ id: String) {
        change { d in
            d.devices.removeAll { $0.id == id }
            for i in d.scenes.indices { d.scenes[i].actions.removeAll { $0.deviceId == id } }
        }
    }

    /// Adds a virtual device (it lives only in the app).
    @discardableResult
    public func addVirtualDevice(_ name: String, _ kind: DeviceKind, roomId: String?) -> Device? {
        guard let demo = addIntegration("demo") else { return nil }
        let ext = "manual:\(newId())"
        let room = data.room(roomId)
        let state: DeviceState = switch kind {
        case .light: DeviceState(on: false, brightness: 1, colorTempK: 3000)
        case .climate: DeviceState(on: true, targetTemp: 21, currentTemp: 21)
        case .cover, .garage: DeviceState(position: 0)
        case .lock: DeviceState(locked: true)
        case .vacuum, .mower: DeviceState(activity: Activity.docked, battery: 1)
        case .alarm: DeviceState(activity: Activity.disarmed)
        case .sensor: DeviceState(readings: ["Temperature": "21 °C"])
        default: DeviceState(on: false)
        }
        let n = name.trimmingCharacters(in: .whitespaces)
        let dev = Device(id: Device.idFor(demo.id, ext), name: n.isEmpty ? kind.label : n, kind: kind, integrationId: demo.id,
                         externalId: ext, props: kind == .vacuum ? ["modes": ["Quiet", "Balanced", "Turbo"]] : [:],
                         roomId: room?.id, floorId: room?.floorId ?? data.floors.first?.id,
                         mapPos: room.map { Self.freeSpot(data, $0) }, state: state)
        change { $0.devices.append(dev) }
        return dev
    }

    // MARK: Floors and rooms

    @discardableResult
    public func addFloor(_ name: String) -> Floor {
        let f = Floor(id: "floor-\(newId())", name: name.isEmpty ? "Floor \(data.floors.count + 1)" : name)
        change(layout: true) { $0.floors.append(f) }
        return f
    }

    public func renameFloor(_ id: String, _ name: String) {
        guard !name.isEmpty else { return }
        change { d in if let i = d.floors.firstIndex(where: { $0.id == id }) { d.floors[i].name = name } }
    }

    /// Removes a floor with its rooms. Its devices stay, without a room or a place on the map.
    public func removeFloor(_ id: String) {
        guard data.floors.count > 1 else { return }
        change(layout: true) { d in
            d.floors.removeAll { $0.id == id }
            d.rooms.removeAll { $0.floorId == id }
            for i in d.devices.indices where d.devices[i].floorId == id {
                d.devices[i].floorId = nil; d.devices[i].roomId = nil; d.devices[i].mapPos = nil
            }
        }
    }

    /// Adds a room in the first free place on `floorId`.
    @discardableResult
    public func addRoom(_ floorId: String, _ name: String, width: Double = 6, height: Double = 5) -> Room {
        let spot = Self.freeRoomSpot(data.rooms(on: floorId), width, height)
        let r = Room(id: "room-\(newId())", floorId: floorId, name: name.isEmpty ? "Room" : name, x: spot.x, y: spot.y,
                     width: width, height: height)
        change(layout: true) { $0.rooms.append(r) }
        return r
    }

    public func renameRoom(_ id: String, _ name: String) {
        guard !name.isEmpty else { return }
        change { d in if let i = d.rooms.firstIndex(where: { $0.id == id }) { d.rooms[i].name = name } }
    }

    /// Moves and resizes a room, snapped to the grid. Devices inside move with it.
    public func setRoomRect(_ id: String, x: Double, y: Double, w: Double, h: Double, record: Bool = true) {
        guard let old = data.room(id) else { return }
        let nx = max(Self.snap(x), 0), ny = max(Self.snap(y), 0)
        let nw = max(Self.snap(w), Self.minRoom), nh = max(Self.snap(h), Self.minRoom)
        if nx == old.x && ny == old.y && nw == old.width && nh == old.height { return }
        let dx = nx - old.x, dy = ny - old.y
        let moved = w == old.width && h == old.height
        change(layout: record) { d in
            if let i = d.rooms.firstIndex(where: { $0.id == id }) {
                d.rooms[i].x = nx; d.rooms[i].y = ny; d.rooms[i].width = nw; d.rooms[i].height = nh
            }
            for i in d.devices.indices where d.devices[i].roomId == id {
                guard let p = d.devices[i].mapPos else { continue }
                d.devices[i].mapPos = moved ? MapPos(p.x + dx, p.y + dy)
                    : MapPos(p.x.clamped(nx + 0.5, nx + nw - 0.5), p.y.clamped(ny + 0.5, ny + nh - 0.5))
            }
        }
    }

    /// Remembers the layout before a drag, so one undo takes back the whole drag.
    public func beginLayoutChange() {
        undo.append(data)
        if undo.count > 30 { undo.removeFirst() }
        canUndo = true
    }

    public func undoLayout() {
        guard let last = undo.popLast() else { return }
        var d = data
        d.floors = last.floors
        d.rooms = last.rooms
        for i in d.devices.indices {
            if let o = last.device(d.devices[i].id) {
                d.devices[i].roomId = o.roomId; d.devices[i].floorId = o.floorId; d.devices[i].mapPos = o.mapPos
            }
        }
        data = d
        canUndo = !undo.isEmpty
        saveSoon()
    }

    /// Removes a room. Its devices stay on the map, without a room.
    public func removeRoom(_ id: String) {
        change(layout: true) { d in
            d.rooms.removeAll { $0.id == id }
            for i in d.devices.indices where d.devices[i].roomId == id { d.devices[i].roomId = nil }
        }
    }

    // MARK: Scenes

    public func saveScene(_ scene: Scene) {
        change { d in
            if let i = d.scenes.firstIndex(where: { $0.id == scene.id }) { d.scenes[i] = scene } else { d.scenes.append(scene) }
        }
    }

    public func newSceneId() -> String { "scene-\(newId())" }

    public func removeScene(_ id: String) { change { $0.scenes.removeAll { $0.id == id } } }

    /// Puts every device of a scene in its state, all at once.
    public func runScene(_ id: String) {
        guard let scene = data.scenes.first(where: { $0.id == id }) else { return }
        Task {
            var failed = 0
            await withTaskGroup(of: Bool.self) { group in
                for a in scene.actions { group.addTask { await self.send(a.deviceId, a.command) } }
                for await ok in group where !ok { failed += 1 }
            }
            onMessage(failed == 0 ? "\(scene.name): done." : "\(scene.name): \(failed) devices did not answer.")
        }
    }

    /// Scenes with a time that is due now (day 1 is Monday). Called once a minute while the app is open.
    public func runDueScenes(day: Int, hour: Int, minute: Int) {
        for s in data.scenes {
            guard let t = s.schedule else { continue }
            if t.hour == hour && t.minute == minute && t.days.contains(day) { runScene(s.id) }
        }
    }

    // MARK: Homes

    public func setTheme(_ mode: String) { change { $0.themeMode = mode } }

    @discardableResult
    public func addHome(_ name: String, sample: Bool = false) -> HomeEntry {
        saveNow()
        let e = HomeEntry(id: "home-\(newId())", name: name.isEmpty ? Self.defaultHome : name)
        let d = sample ? Seed.sampleHome() : Seed.emptyHome()
        storage.write(Self.homeFile(e.id), d.json().text())
        open(e.id, d, homes: homes + [e])
        return e
    }

    private func open(_ id: String, _ d: HomeData, homes list: [HomeEntry]) {
        undo = []
        homes = list
        homeId = id
        data = d
        status = [:]
        canUndo = false
        writeHomes(list, id)
        startDrivers()
    }

    public func switchHome(_ id: String) {
        guard id != homeId else { return }
        saveNow()
        open(id, readHome(id) ?? Seed.emptyHome(), homes: homes)
    }

    public func renameHome(_ id: String, _ name: String) {
        guard !name.isEmpty, let i = homes.firstIndex(where: { $0.id == id }) else { return }
        homes[i].name = name
        writeHomes(homes, homeId)
    }

    public func removeHome(_ id: String) {
        guard homes.count > 1 else { return }
        storage.delete(Self.homeFile(id))
        let rest = homes.filter { $0.id != id }
        if id == homeId {
            open(rest[0].id, readHome(rest[0].id) ?? Seed.emptyHome(), homes: rest)
        } else {
            homes = rest
            writeHomes(rest, homeId)
        }
    }

    /// Swaps the sample home for an empty one.
    public func clearSample() {
        change { d in
            let theme = d.themeMode
            d = Seed.emptyHome()
            d.themeMode = theme
        }
        startDrivers()
    }

    // MARK: Backup

    /// Every home as one JSON text, in the same shape as the Flutter and Android apps' backup file.
    public func exportAll() -> String {
        let list: [JSON] = homes.compactMap { h in
            guard let d = h.id == homeId ? data : readHome(h.id) else { return nil }
            return ["id": .string(h.id), "name": .string(h.name), "home": d.json(withState: false)]
        }
        let j: JSON = ["app": "SmartHomeKJ", "backup": "homes", "current": .string(homeId), "homes": .array(list)]
        return j.text(pretty: true)
    }

    /// Takes back the homes in a backup: a backup of every home replaces the homes here, a backup of one home replaces
    /// the open home. Returns how many homes came back.
    public func importAll(_ raw: String) throws -> Int {
        guard let j = try? JSON.parse(raw), j.object != nil else { throw IntegrationError("That is not a SmartHomeKJ backup.") }
        guard j["backup"]?.string == "homes", let list = j["homes"]?.array else {
            let d = HomeData(json: j)
            if d.floors.isEmpty { throw IntegrationError("That backup has no home in it.") }
            undo = []
            data = d
            status = [:]
            canUndo = false
            saveNow()
            startDrivers()
            return 1
        }
        var next: [(HomeEntry, HomeData)] = []
        for h in list {
            guard let id = h["id"]?.string, let hj = h["home"] else { continue }
            let d = HomeData(json: hj)
            if d.floors.isEmpty || next.contains(where: { $0.0.id == id }) { continue }
            next.append((HomeEntry(id: id, name: h["name"]?.string ?? Self.defaultHome), d))
        }
        if next.isEmpty { throw IntegrationError("That backup has no homes.") }
        for old in homes where !next.contains(where: { $0.0.id == old.id }) { storage.delete(Self.homeFile(old.id)) }
        for (e, d) in next { storage.write(Self.homeFile(e.id), d.json().text()) }
        let current = next.first { $0.0.id == j["current"]?.string } ?? next[0]
        open(current.0.id, current.1, homes: next.map(\.0))
        return next.count
    }

    // MARK: Layout helpers

    public static func snap(_ v: Double) -> Double { (v * 2).rounded() / 2 }

    /// A place inside `room` that no other device of the room is on.
    public static func freeSpot(_ d: HomeData, _ room: Room) -> MapPos {
        let taken = d.devices.filter { $0.roomId == room.id }.compactMap(\.mapPos)
        let cols = max(Int((room.width - 1).rounded(.down)), 1)
        let rows = max(Int((room.height - 1).rounded(.down)), 1)
        for r in 0..<rows {
            for c in 0..<cols {
                let p = MapPos(room.x + 1 + Double(c), room.y + 1 + Double(r))
                if !taken.contains(where: { abs($0.x - p.x) < 0.9 && abs($0.y - p.y) < 0.9 }) { return p }
            }
        }
        return MapPos(room.x + room.width / 2, room.y + room.height / 2)
    }

    /// The top-left corner of the first gap on a floor where a room of this size fits.
    public static func freeRoomSpot(_ rooms: [Room], _ w: Double, _ h: Double) -> MapPos {
        for y in 0...60 {
            for x in 0...40 {
                let fx = 1 + Double(x), fy = 1 + Double(y)
                if !rooms.contains(where: { fx < $0.right && fx + w > $0.x && fy < $0.bottom && fy + h > $0.y }) { return MapPos(fx, fy) }
            }
        }
        return MapPos(1, (rooms.map(\.bottom).max() ?? 0) + 1)
    }
}
