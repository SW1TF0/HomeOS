import Foundation

/// What a device is, used for its icon and which controls it shows. Names match the saved homes of the other apps.
public enum DeviceKind: String, CaseIterable, Sendable {
    case light, outlet, toggle, sensor, climate, cover, fan, lock, media, camera, vacuum, mower, purifier, humidifier,
         appliance, alarm, valve, siren, garage, button, other

    public var label: String {
        switch self {
        case .light: "Light"
        case .outlet: "Plug"
        case .toggle: "Switch"
        case .sensor: "Sensor"
        case .climate: "Climate"
        case .cover: "Blind"
        case .fan: "Fan"
        case .lock: "Lock"
        case .media: "Media"
        case .camera: "Camera"
        case .vacuum: "Robot vacuum"
        case .mower: "Lawn mower"
        case .purifier: "Air purifier"
        case .humidifier: "Humidifier"
        case .appliance: "Appliance"
        case .alarm: "Alarm"
        case .valve: "Valve"
        case .siren: "Siren"
        case .garage: "Garage door"
        case .button: "Button"
        case .other: "Other"
        }
    }

    public static func parse(_ s: String?) -> DeviceKind { s.flatMap(DeviceKind.init(rawValue:)) ?? .other }
}

/// A thing a device can do. Controls are shown only for capabilities it has.
public enum Capability: String, CaseIterable, Sendable {
    case onOff, brightness, colorTemp, color, position, targetTemp, lock, readings, volume, remote,
         run, dock, locate, mode, speed, humidity, alarm, press, snapshot
}

public enum DeviceAction: String, CaseIterable, Sendable {
    case start, pause, stop, dock, locate, press, armHome, armAway, armNight, armVacation, disarm

    public var alarmState: String? {
        switch self {
        case .armHome: Activity.armedHome
        case .armAway: Activity.armedAway
        case .armNight: Activity.armedNight
        case .armVacation: Activity.armedVacation
        case .disarm: Activity.disarmed
        default: nil
        }
    }
}

/// What a robot, an appliance or an alarm is doing, as kept in `DeviceState.activity`.
public enum Activity {
    public static let running = "running", paused = "paused", returning = "returning", docked = "docked",
                      charging = "charging", idle = "idle", error = "error"
    public static let disarmed = "disarmed", armedHome = "armed_home", armedAway = "armed_away",
                      armedNight = "armed_night", armedVacation = "armed_vacation", armedCustom = "armed_custom_bypass",
                      arming = "arming", pending = "pending", disarming = "disarming", triggered = "triggered"
    public static let busy: Set<String> = [running, returning, armedHome, armedAway, armedNight, armedVacation, armedCustom,
                                           arming, pending, triggered]

    public static func after(_ a: DeviceAction?) -> String? {
        switch a {
        case .start: running
        case .pause: paused
        case .stop: idle
        case .dock: returning
        case .locate, .press, nil: nil
        case let a?: a.alarmState
        }
    }
}

public enum RemoteKey: String, CaseIterable, Sendable {
    case power, volumeUp, volumeDown, mute, channelUp, channelDown, up, down, left, right, ok, back, home, menu,
         playPause, stop, rewind, forward, source
}

public func defaultCapabilities(_ kind: DeviceKind) -> Set<Capability> {
    switch kind {
    case .light: [.onOff, .brightness, .colorTemp, .color]
    case .outlet, .toggle, .fan, .valve, .siren: [.onOff]
    case .media: [.onOff, .volume, .remote]
    case .sensor: [.readings]
    case .climate: [.onOff, .targetTemp]
    case .cover, .garage: [.position]
    case .lock: [.lock]
    case .vacuum: [.run, .dock, .locate, .mode]
    case .mower: [.run, .dock]
    case .purifier: [.onOff, .speed, .mode]
    case .humidifier: [.onOff, .humidity]
    case .appliance: [.run]
    case .alarm: [.alarm]
    case .button: [.press]
    case .camera, .other: []
    }
}

/// A requested change. Nil fields are left as they are.
public struct DeviceCommand: Equatable, Sendable {
    public var on: Bool?
    public var brightness: Double?
    public var colorTempK: Int?
    public var color: Int?
    public var position: Double?
    public var targetTemp: Double?
    public var locked: Bool?
    public var volume: Double?
    public var muted: Bool?
    public var key: RemoteKey?
    public var action: DeviceAction?
    public var mode: String?
    public var speed: Double?
    public var targetHumidity: Double?
    /// An alarm code, sent with arm and disarm. Never saved.
    public var code: String?

    public init(on: Bool? = nil, brightness: Double? = nil, colorTempK: Int? = nil, color: Int? = nil, position: Double? = nil,
                targetTemp: Double? = nil, locked: Bool? = nil, volume: Double? = nil, muted: Bool? = nil, key: RemoteKey? = nil,
                action: DeviceAction? = nil, mode: String? = nil, speed: Double? = nil, targetHumidity: Double? = nil,
                code: String? = nil) {
        self.on = on; self.brightness = brightness; self.colorTempK = colorTempK; self.color = color
        self.position = position; self.targetTemp = targetTemp; self.locked = locked; self.volume = volume
        self.muted = muted; self.key = key; self.action = action; self.mode = mode; self.speed = speed
        self.targetHumidity = targetHumidity; self.code = code
    }
}

/// The last known state of a device.
public struct DeviceState: Equatable, Sendable {
    public var on: Bool?
    public var brightness: Double?
    public var colorTempK: Int?
    public var color: Int?
    public var position: Double?
    public var targetTemp: Double?
    public var currentTemp: Double?
    public var locked: Bool?
    public var volume: Double?
    public var muted: Bool?
    public var activity: String?
    public var battery: Double?
    public var mode: String?
    public var speed: Double?
    public var targetHumidity: Double?
    public var currentHumidity: Double?
    public var readings: [String: String] = [:]
    public var reachable: Bool = true

    public init(on: Bool? = nil, brightness: Double? = nil, colorTempK: Int? = nil, color: Int? = nil, position: Double? = nil,
                targetTemp: Double? = nil, currentTemp: Double? = nil, locked: Bool? = nil, volume: Double? = nil,
                muted: Bool? = nil, activity: String? = nil, battery: Double? = nil, mode: String? = nil, speed: Double? = nil,
                targetHumidity: Double? = nil, currentHumidity: Double? = nil, readings: [String: String] = [:],
                reachable: Bool = true) {
        self.on = on; self.brightness = brightness; self.colorTempK = colorTempK; self.color = color
        self.position = position; self.targetTemp = targetTemp; self.currentTemp = currentTemp; self.locked = locked
        self.volume = volume; self.muted = muted; self.activity = activity; self.battery = battery; self.mode = mode
        self.speed = speed; self.targetHumidity = targetHumidity; self.currentHumidity = currentHumidity
        self.readings = readings; self.reachable = reachable
    }

    public static let unreachable = DeviceState(reachable: false)

    public var isActive: Bool {
        on == true || ((position ?? 0) > 0.01 && on == nil) || locked == false || activity.map { Activity.busy.contains($0) } == true
    }

    public func applying(_ c: DeviceCommand) -> DeviceState {
        var s = self
        if let v = c.on { s.on = v }
        else if (c.brightness ?? c.speed ?? 0) > 0 { s.on = true }
        else if c.key == .power, let o = on { s.on = !o }
        if let v = c.brightness { s.brightness = v }
        if let v = c.colorTempK { s.colorTempK = v; s.color = nil }
        if let v = c.color { s.color = v; if c.colorTempK == nil { s.colorTempK = nil } }
        if let v = c.position { s.position = v }
        if let v = c.targetTemp { s.targetTemp = v }
        if let v = c.locked { s.locked = v }
        if let v = c.volume { s.volume = v }
        if let v = c.muted { s.muted = v } else if c.key == .mute, let m = muted { s.muted = !m }
        if let a = Activity.after(c.action) { s.activity = a }
        if let v = c.mode { s.mode = v }
        if let v = c.speed { s.speed = v }
        if let v = c.targetHumidity { s.targetHumidity = v }
        return s
    }

    /// Overlays the known fields of `o`. An empty mode or reading is a device saying it has none any more.
    public func merging(_ o: DeviceState) -> DeviceState {
        var s = self
        s.on = o.on ?? on; s.brightness = o.brightness ?? brightness; s.colorTempK = o.colorTempK ?? colorTempK
        s.color = o.color ?? color; s.position = o.position ?? position; s.targetTemp = o.targetTemp ?? targetTemp
        s.currentTemp = o.currentTemp ?? currentTemp; s.locked = o.locked ?? locked; s.volume = o.volume ?? volume
        s.muted = o.muted ?? muted; s.activity = o.activity ?? activity; s.battery = o.battery ?? battery
        if let m = o.mode { s.mode = m.isEmpty ? nil : m }
        s.speed = o.speed ?? speed; s.targetHumidity = o.targetHumidity ?? targetHumidity
        s.currentHumidity = o.currentHumidity ?? currentHumidity
        if !o.readings.isEmpty { s.readings = readings.merging(o.readings) { $1 }.filter { !$0.value.isEmpty } }
        s.reachable = o.reachable
        return s
    }

    public var json: JSON {
        obj([
            "on": JSON(on), "brightness": JSON(brightness), "colorTempK": JSON(colorTempK), "color": JSON(color),
            "position": JSON(position), "targetTemp": JSON(targetTemp), "currentTemp": JSON(currentTemp),
            "locked": JSON(locked), "volume": JSON(volume), "muted": JSON(muted), "activity": JSON(activity),
            "battery": JSON(battery), "mode": JSON(mode), "speed": JSON(speed), "targetHumidity": JSON(targetHumidity),
            "currentHumidity": JSON(currentHumidity),
            "readings": readings.isEmpty ? nil : .object(readings.mapValues { .string($0) }),
            "reachable": .bool(reachable),
        ])
    }

    public init(json j: JSON) {
        self.init(on: j["on"]?.bool, brightness: j["brightness"]?.double, colorTempK: j["colorTempK"]?.int,
                  color: j["color"]?.int, position: j["position"]?.double, targetTemp: j["targetTemp"]?.double,
                  currentTemp: j["currentTemp"]?.double, locked: j["locked"]?.bool, volume: j["volume"]?.double,
                  muted: j["muted"]?.bool, activity: j["activity"]?.string, battery: j["battery"]?.double,
                  mode: j["mode"]?.string, speed: j["speed"]?.double, targetHumidity: j["targetHumidity"]?.double,
                  currentHumidity: j["currentHumidity"]?.double,
                  readings: j["readings"]?.object?.mapValues { $0.description } ?? [:],
                  reachable: j["reachable"]?.bool ?? true)
    }
}

public struct MapPos: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

public struct Device: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: DeviceKind
    public var integrationId: String
    public var externalId: String
    public var capabilities: Set<Capability>
    public var props: [String: JSON]
    public var roomId: String?
    public var floorId: String?
    public var mapPos: MapPos?
    public var favorite: Bool
    public var state: DeviceState

    public init(id: String, name: String, kind: DeviceKind, integrationId: String, externalId: String,
                capabilities: Set<Capability>? = nil, props: [String: JSON] = [:], roomId: String? = nil,
                floorId: String? = nil, mapPos: MapPos? = nil, favorite: Bool = false, state: DeviceState = DeviceState()) {
        self.id = id; self.name = name; self.kind = kind; self.integrationId = integrationId; self.externalId = externalId
        self.capabilities = capabilities ?? defaultCapabilities(kind); self.props = props; self.roomId = roomId
        self.floorId = floorId; self.mapPos = mapPos; self.favorite = favorite; self.state = state
    }

    public static func idFor(_ integrationId: String, _ externalId: String) -> String { "\(integrationId)::\(externalId)" }

    public func has(_ c: Capability) -> Bool { capabilities.contains(c) }
    public var countsAsOn: Bool { state.isActive && kind != .lock && kind != .alarm }
    public var modes: [String] { props["modes"]?.array?.map(\.description) ?? [] }
    public func prop(_ k: String) -> String? { props[k]?.string }

    public func json(withState: Bool = true) -> JSON {
        obj([
            "id": .string(id), "name": .string(name), "kind": .string(kind.rawValue), "integrationId": .string(integrationId),
            "externalId": .string(externalId),
            "capabilities": .array(Capability.allCases.filter(capabilities.contains).map { .string($0.rawValue) }),
            "props": .object(props), "roomId": JSON(roomId), "floorId": JSON(floorId),
            "mapPos": mapPos.map { .array([.number($0.x), .number($0.y)]) }, "favorite": .bool(favorite),
            "state": withState ? state.json : nil,
        ])
    }

    public init?(json j: JSON) {
        guard let id = j["id"]?.string, let integrationId = j["integrationId"]?.string, let ext = j["externalId"]?.string else { return nil }
        let kind = DeviceKind.parse(j["kind"]?.string)
        let pos = j["mapPos"]?.array
        self.init(id: id, name: j["name"]?.string ?? "Device", kind: kind, integrationId: integrationId, externalId: ext,
                  capabilities: j["capabilities"]?.array.map { Set($0.compactMap { $0.string.flatMap(Capability.init(rawValue:)) }) },
                  props: j["props"]?.object ?? [:], roomId: j["roomId"]?.string, floorId: j["floorId"]?.string,
                  mapPos: pos.flatMap { $0.count >= 2 ? MapPos($0[0].double ?? 0, $0[1].double ?? 0) : nil },
                  favorite: j["favorite"]?.bool ?? false, state: j["state"].map(DeviceState.init(json:)) ?? DeviceState())
    }
}

public struct Floor: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
    public var json: JSON { ["id": .string(id), "name": .string(name)] }
    public init?(json j: JSON) {
        guard let id = j["id"]?.string else { return nil }
        self.init(id: id, name: j["name"]?.string ?? "Floor")
    }
}

/// A room drawn on a floor plan. Coordinates are map units (one grid cell).
public struct Room: Identifiable, Equatable, Sendable {
    public var id: String
    public var floorId: String
    public var name: String
    public var x: Double, y: Double, width: Double, height: Double

    public init(id: String, floorId: String, name: String, x: Double, y: Double, width: Double, height: Double) {
        self.id = id; self.floorId = floorId; self.name = name; self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var right: Double { x + width }
    public var bottom: Double { y + height }
    public func contains(_ p: MapPos) -> Bool { p.x >= x && p.x < right && p.y >= y && p.y < bottom }

    public var json: JSON {
        ["id": .string(id), "floorId": .string(floorId), "name": .string(name), "x": .number(x), "y": .number(y),
         "width": .number(width), "height": .number(height)]
    }

    public init?(json j: JSON) {
        guard let id = j["id"]?.string, let f = j["floorId"]?.string else { return nil }
        self.init(id: id, floorId: f, name: j["name"]?.string ?? "Room", x: j["x"]?.double ?? 0, y: j["y"]?.double ?? 0,
                  width: j["width"]?.double ?? 4, height: j["height"]?.double ?? 4)
    }
}

public struct IntegrationConfig: Identifiable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var name: String
    public var settings: [String: JSON]
    public var enabled: Bool

    public init(id: String, type: String, name: String, settings: [String: JSON] = [:], enabled: Bool = true) {
        self.id = id; self.type = type; self.name = name; self.settings = settings; self.enabled = enabled
    }

    public func setting(_ key: String, _ fallback: String = "") -> String {
        let v = settings[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? fallback : v
    }

    public var json: JSON {
        ["id": .string(id), "type": .string(type), "name": .string(name), "settings": .object(settings), "enabled": .bool(enabled)]
    }

    public init?(json j: JSON) {
        guard let id = j["id"]?.string, let type = j["type"]?.string else { return nil }
        self.init(id: id, type: type, name: j["name"]?.string ?? type, settings: j["settings"]?.object ?? [:],
                  enabled: j["enabled"]?.bool ?? true)
    }
}

/// One device's part in a scene.
public struct SceneAction: Equatable, Sendable {
    public var deviceId: String
    public var command: DeviceCommand
    public init(deviceId: String, command: DeviceCommand) { self.deviceId = deviceId; self.command = command }

    public var isOff: Bool {
        command.on == false || command.locked == true || command.action == .dock || (command.on == nil && command.position == 0)
    }

    private static func isRobot(_ d: Device) -> Bool { d.has(.run) && (d.kind == .vacuum || d.kind == .mower) }

    /// The command that recreates what `d` is doing now.
    public static func capture(_ d: Device) -> SceneAction {
        let s = d.state
        let on = d.has(.onOff) ? s.on : nil
        let lit = on != false
        var action: DeviceAction?
        if isRobot(d) {
            if s.activity == Activity.running { action = .start }
            else if d.has(.dock), [Activity.returning, Activity.docked, Activity.charging].contains(s.activity ?? "") { action = .dock }
        } else if d.has(.alarm), d.props["codeArmRequired"]?.bool != true {
            action = DeviceAction.allCases.first { $0 != .disarm && $0.alarmState == s.activity }
        }
        return SceneAction(deviceId: d.id, command: DeviceCommand(
            on: on,
            brightness: d.has(.brightness) && lit ? s.brightness : nil,
            colorTempK: d.has(.colorTemp) && lit && s.color == nil ? s.colorTempK : nil,
            color: d.has(.color) && lit ? s.color : nil,
            position: d.has(.position) ? s.position : nil,
            targetTemp: d.has(.targetTemp) && lit ? s.targetTemp : nil,
            locked: d.has(.lock) ? s.locked : nil,
            volume: d.has(.volume) && lit ? s.volume : nil,
            action: action,
            mode: d.has(.mode) && lit ? s.mode : nil,
            speed: d.has(.speed) && lit ? s.speed : nil,
            targetHumidity: d.has(.humidity) && lit ? s.targetHumidity : nil))
    }

    /// Turns `d` off or on, or the nearest thing: a blind closes, a robot goes home, a lock locks.
    public static func turn(_ d: Device, _ on: Bool) -> SceneAction? {
        let c: DeviceCommand?
        if d.has(.onOff) { c = DeviceCommand(on: on) }
        else if d.has(.position) { c = DeviceCommand(position: on ? 1 : 0) }
        else if d.has(.lock) { c = on ? nil : DeviceCommand(locked: true) }
        else if isRobot(d) { c = on ? DeviceCommand(action: .start) : (d.has(.dock) ? DeviceCommand(action: .dock) : nil) }
        else { c = nil }
        return c.map { SceneAction(deviceId: d.id, command: $0) }
    }

    public var json: JSON {
        let c = command
        return obj(["deviceId": .string(deviceId), "on": JSON(c.on), "brightness": JSON(c.brightness),
                    "colorTempK": JSON(c.colorTempK), "color": JSON(c.color), "position": JSON(c.position),
                    "targetTemp": JSON(c.targetTemp), "locked": JSON(c.locked), "volume": JSON(c.volume),
                    "mode": JSON(c.mode), "speed": JSON(c.speed), "targetHumidity": JSON(c.targetHumidity),
                    "action": JSON(c.action?.rawValue)])
    }

    public init?(json j: JSON) {
        guard let id = j["deviceId"]?.string else { return nil }
        self.init(deviceId: id, command: DeviceCommand(
            on: j["on"]?.bool, brightness: j["brightness"]?.double, colorTempK: j["colorTempK"]?.int, color: j["color"]?.int,
            position: j["position"]?.double, targetTemp: j["targetTemp"]?.double, locked: j["locked"]?.bool,
            volume: j["volume"]?.double, action: j["action"]?.string.flatMap(DeviceAction.init(rawValue:)),
            mode: j["mode"]?.string, speed: j["speed"]?.double, targetHumidity: j["targetHumidity"]?.double))
    }
}

/// When a scene runs by itself: a time of day on some weekdays (1 = Monday).
public struct SceneSchedule: Equatable, Sendable {
    public var hour: Int, minute: Int
    public var days: Set<Int>
    public init(hour: Int, minute: Int, days: Set<Int> = Set(1...7)) { self.hour = hour; self.minute = minute; self.days = days }

    public var time: String { String(format: "%02d:%02d", hour, minute) }
    public var daysLabel: String {
        if days.count == 7 { return "Every day" }
        if days == [1, 2, 3, 4, 5] { return "Weekdays" }
        if days == [6, 7] { return "Weekends" }
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return days.sorted().map { names[$0 - 1] }.joined(separator: " ")
    }

    public var json: JSON { ["hour": .number(Double(hour)), "minute": .number(Double(minute)), "days": .array(days.sorted().map { .number(Double($0)) })] }
    public init(json j: JSON) {
        self.init(hour: j["hour"]?.int ?? 0, minute: j["minute"]?.int ?? 0,
                  days: j["days"]?.array.map { Set($0.compactMap(\.int)) } ?? Set(1...7))
    }
}

public struct Scene: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var icon: String
    public var actions: [SceneAction]
    public var schedule: SceneSchedule?

    public init(id: String, name: String, icon: String = "auto", actions: [SceneAction] = [], schedule: SceneSchedule? = nil) {
        self.id = id; self.name = name; self.icon = icon; self.actions = actions; self.schedule = schedule
    }

    public var json: JSON {
        obj(["id": .string(id), "name": .string(name), "icon": .string(icon), "actions": .array(actions.map(\.json)),
             "schedule": schedule?.json])
    }

    public init?(json j: JSON) {
        guard let id = j["id"]?.string else { return nil }
        self.init(id: id, name: j["name"]?.string ?? "Scene", icon: j["icon"]?.string ?? "auto",
                  actions: j["actions"]?.array?.compactMap(SceneAction.init(json:)) ?? [],
                  schedule: j["schedule"].flatMap { $0 == .null ? nil : SceneSchedule(json: $0) })
    }

    public static let templates: [(String, String)] = [
        ("All off", "off"), ("Good morning", "morning"), ("Movie night", "movie"), ("Good night", "night"),
        ("Away", "away"), ("Dinner", "dinner"), ("Focus", "focus"),
    ]
}

/// Everything saved about one home, in the same JSON as the Android and Flutter apps.
public struct HomeData: Equatable, Sendable {
    public var floors: [Floor] = []
    public var rooms: [Room] = []
    public var devices: [Device] = []
    public var integrations: [IntegrationConfig] = []
    public var scenes: [Scene] = []
    /// Kept as they are; this app does not run automations yet.
    public var automations: [JSON] = []
    public var themeMode = "dark"

    public init(floors: [Floor] = [], rooms: [Room] = [], devices: [Device] = [], integrations: [IntegrationConfig] = [],
                scenes: [Scene] = [], automations: [JSON] = [], themeMode: String = "dark") {
        self.floors = floors; self.rooms = rooms; self.devices = devices; self.integrations = integrations
        self.scenes = scenes; self.automations = automations; self.themeMode = themeMode
    }

    public func device(_ id: String) -> Device? { devices.first { $0.id == id } }
    public func room(_ id: String?) -> Room? { id.flatMap { id in rooms.first { $0.id == id } } }
    public func integration(_ id: String) -> IntegrationConfig? { integrations.first { $0.id == id } }
    public func rooms(on floorId: String) -> [Room] { rooms.filter { $0.floorId == floorId } }
    public func devices(in roomId: String) -> [Device] { devices.filter { $0.roomId == roomId } }

    public func json(withState: Bool = true) -> JSON {
        obj(["app": "SmartMenuKJ", "version": 1, "themeMode": .string(themeMode),
             "floors": .array(floors.map(\.json)), "rooms": .array(rooms.map(\.json)),
             "devices": .array(devices.map { $0.json(withState: withState) }),
             "integrations": .array(integrations.map(\.json)), "scenes": .array(scenes.map(\.json)),
             "automations": automations.isEmpty ? nil : .array(automations)])
    }

    public init(json j: JSON) {
        self.init(floors: j["floors"]?.array?.compactMap(Floor.init(json:)) ?? [],
                  rooms: j["rooms"]?.array?.compactMap(Room.init(json:)) ?? [],
                  devices: j["devices"]?.array?.compactMap(Device.init(json:)) ?? [],
                  integrations: j["integrations"]?.array?.compactMap(IntegrationConfig.init(json:)) ?? [],
                  scenes: j["scenes"]?.array?.compactMap(Scene.init(json:)) ?? [],
                  automations: j["automations"]?.array ?? [],
                  themeMode: j["themeMode"]?.string ?? "dark")
    }
}

public struct HomeEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}
