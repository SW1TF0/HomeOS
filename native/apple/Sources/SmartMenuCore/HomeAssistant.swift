import Foundation

/// A Home Assistant server (free, self-hosted). Brings in every light, switch, cover, climate, lock, fan, media player,
/// robot vacuum, mower, alarm, valve, camera, scene and useful sensor it knows about, which covers thousands of brands,
/// Matter, Zigbee and Z-Wave included.
public final class HomeAssistantDriver: IntegrationDriver, @unchecked Sendable {
    public var baseUrl: String {
        var url = config.setting("url")
        if url.isEmpty { return url }
        if !url.hasPrefix("http") { url = "http://\(url)" }
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    private var headers: [String: String] { ["Authorization": "Bearer \(config.setting("token"))"] }

    private func states() async throws -> [JSON] {
        if baseUrl.isEmpty || config.setting("token").isEmpty {
            throw IntegrationError("Enter the server address and a long-lived access token (Profile > Security in Home Assistant).")
        }
        guard let res = try await getJSON("\(baseUrl)/api/states", headers: headers)?.array else {
            throw IntegrationError("Unexpected reply from Home Assistant.")
        }
        return res.filter { $0["entity_id"]?.string != nil }
    }

    public override func discover() async throws -> [Device] {
        let all = try await states()
        // A robot's battery shows on the robot, not as a sensor of its own.
        let robotBatteries = Set(all.filter { ["vacuum", "lawn_mower"].contains(Self.domain($0)) }
            .compactMap { Self.batterySensor(of: Self.entityId($0), all)?["entity_id"]?.string })
        return all.compactMap { e in
            guard let kind = Self.kind(for: e) else { return nil }
            let id = Self.entityId(e)
            if robotBatteries.contains(id) { return nil }
            return makeDevice(id, Self.attrs(e)["friendly_name"]?.string ?? id, kind, capabilities: Self.capabilities(for: e, kind),
                              props: Self.props(for: e), state: Self.withBattery(id, Self.parseState(e), all))
        }
    }

    public override func refreshAll(_ devices: [Device]) async -> [String: DeviceState] {
        guard let all = try? await states() else {
            return Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.state.merging(.unreachable)) })
        }
        let byId = Dictionary(all.map { (Self.entityId($0), $0) }, uniquingKeysWith: { a, _ in a })
        return Dictionary(uniqueKeysWithValues: devices.map { d in
            (d.id, d.state.merging(byId[d.externalId].map { Self.withBattery(d.externalId, Self.parseState($0), all) } ?? .unreachable))
        })
    }

    public override func refresh(_ d: Device) async throws -> DeviceState? {
        try await getJSON("\(baseUrl)/api/states/\(d.externalId)", headers: headers).map(Self.parseState)
    }

    private func call(_ domain: String, _ service: String, _ data: [String: JSON?]) async throws {
        _ = try await sendJSON("POST", "\(baseUrl)/api/services/\(domain)/\(service)", obj(data), headers: headers)
    }

    public override func send(_ d: Device, _ c: DeviceCommand) async throws -> DeviceState? {
        let id = d.externalId
        let domain = String(id.split(separator: ".").first ?? "")
        let target: [String: JSON?] = ["entity_id": JSON(id)]
        func with(_ extra: [String: JSON?]) -> [String: JSON?] { target.merging(extra) { $1 } }
        let action = c.action
        switch domain {
        case "light":
            if c.on == false { try await call("light", "turn_off", target) } else {
                try await call("light", "turn_on", with([
                    "brightness_pct": c.brightness.map { JSON(Int(($0 * 100).rounded())) },
                    "color_temp_kelvin": c.colorTempK.map { JSON($0) },
                    "rgb_color": c.color.map { JSON.array(ColorMath.channels($0).map { JSON($0) }) },
                ]))
            }
        case "cover":
            if let p = c.position { try await call("cover", "set_cover_position", with(["position": JSON(Int((p * 100).rounded()))])) }
            else if let on = c.on { try await call("cover", on ? "open_cover" : "close_cover", target) }
        case "climate", "water_heater":
            // Switch on first: turning on picks a mode by itself, which the chosen mode then replaces.
            if c.on == true { try await call(domain, "turn_on", target) }
            if let m = c.mode {
                if domain == "climate" { try await call(domain, "set_hvac_mode", with(["hvac_mode": JSON(m)])) }
                else { try await call(domain, "set_operation_mode", with(["operation_mode": JSON(m)])) }
            }
            if let t = c.targetTemp { try await call(domain, "set_temperature", with(["temperature": JSON(t)])) }
            if c.on == false { try await call(domain, "turn_off", target) }
        case "humidifier":
            if c.on == true { try await call(domain, "turn_on", target) }
            if let m = c.mode { try await call(domain, "set_mode", with(["mode": JSON(m)])) }
            if let h = c.targetHumidity { try await call(domain, "set_humidity", with(["humidity": JSON(Int(h.rounded()))])) }
            if c.on == false { try await call(domain, "turn_off", target) }
        case "fan":
            if c.on == false { try await call("fan", "turn_off", target) } else {
                if let s = c.speed { try await call("fan", "set_percentage", with(["percentage": JSON(Int((s * 100).rounded()).clamped(1, 100))])) }
                if let m = c.mode { try await call("fan", "set_preset_mode", with(["preset_mode": JSON(m)])) }
                if c.on == true && c.speed == nil && c.mode == nil { try await call("fan", "turn_on", target) }
            }
        case "lock":
            if let l = c.locked { try await call("lock", l ? "lock" : "unlock", target) }
        case "media_player":
            if let on = c.on { try await call(domain, on ? "turn_on" : "turn_off", target) }
            if let v = c.volume { try await call(domain, "volume_set", with(["volume_level": JSON(v)])) }
            if let m = c.muted { try await call(domain, "volume_mute", with(["is_volume_muted": JSON(m)])) }
            if let m = c.mode { try await call(domain, "select_source", with(["source": JSON(m)])) }
            if c.key == .mute {
                // The screen has already flipped it, so this is the wanted state.
                try await call(domain, "volume_mute", with(["is_volume_muted": JSON(d.state.muted ?? true)]))
            } else if let key = c.key {
                let service: String? = switch key {
                case .power: "toggle"
                case .volumeUp: "volume_up"
                case .volumeDown: "volume_down"
                case .playPause: "media_play_pause"
                case .stop: "media_stop"
                case .rewind: "media_previous_track"
                case .forward: "media_next_track"
                default: nil
                }
                if let service { try await call(domain, service, target) }
            }
        case "vacuum":
            if let m = c.mode { try await call(domain, "set_fan_speed", with(["fan_speed": JSON(m)])) }
            let service: String? = switch action {
            case .start?: "start"
            case .pause?: "pause"
            case .stop?: "stop"
            case .dock?: "return_to_base"
            case .locate?: "locate"
            default: nil
            }
            if let service { try await call(domain, service, target) }
        case "lawn_mower":
            let service: String? = switch action {
            case .start?: "start_mowing"
            case .pause?: "pause"
            case .dock?: "dock"
            default: nil
            }
            if let service { try await call(domain, service, target) }
        case "alarm_control_panel":
            let service: String? = switch action {
            case .armHome?: "alarm_arm_home"
            case .armAway?: "alarm_arm_away"
            case .armNight?: "alarm_arm_night"
            case .armVacation?: "alarm_arm_vacation"
            case .disarm?: "alarm_disarm"
            default: nil
            }
            if let service { try await call(domain, service, with(["code": c.code.map { JSON($0) }])) }
        case "valve":
            if let on = c.on { try await call(domain, on ? "open_valve" : "close_valve", target) }
        case "scene", "script":
            if action == .press { try await call(domain, "turn_on", target) }
        case "input_button":
            if action == .press { try await call(domain, "press", target) }
        default:
            if let on = c.on { try await call(domain, on ? "turn_on" : "turn_off", target) }
        }
        return nil
    }

    static let sensorClasses: Set<String> = [
        "temperature", "humidity", "motion", "occupancy", "presence", "door", "window", "opening", "garage_door",
        "power", "energy", "battery", "illuminance", "moisture", "smoke", "gas", "carbon_monoxide", "carbon_dioxide",
        "co2", "pm25", "pm10", "pm1", "volatile_organic_compounds", "aqi", "pressure", "atmospheric_pressure",
        "vibration", "sound",
    ]

    /// Words in the name of a fan that is really an air purifier.
    static let purifierWords = ["purif", "air clean", "luftrein", "пречиств", "очист", "depurat", "oczyszcz"]

    static func entityId(_ e: JSON) -> String { e["entity_id"]?.string ?? "" }
    public static func domain(_ e: JSON) -> String { String(entityId(e).split(separator: ".").first ?? "") }
    static func attrs(_ e: JSON) -> JSON { e["attributes"] ?? [:] }
    static func features(_ a: JSON) -> Int { a["supported_features"]?.int ?? 0 }
    static func strings(_ a: JSON, _ key: String) -> [String] { a[key]?.array?.map(\.description) ?? [] }

    public static func kind(for e: JSON) -> DeviceKind? {
        let id = entityId(e), a = attrs(e)
        let cls = a["device_class"]?.string
        switch domain(e) {
        case "light": return .light
        case "switch": return cls == "outlet" ? .outlet : .toggle
        case "input_boolean": return .toggle
        case "fan":
            let text = "\(id) \(a["friendly_name"]?.string ?? "")".lowercased()
            return purifierWords.contains { text.contains($0) } ? .purifier : .fan
        case "cover": return cls == "garage" || cls == "gate" ? .garage : .cover
        case "climate", "water_heater": return .climate
        case "humidifier": return .humidifier
        case "lock": return .lock
        case "media_player": return .media
        case "camera": return .camera
        case "vacuum": return .vacuum
        case "lawn_mower": return .mower
        case "alarm_control_panel": return .alarm
        case "valve": return .valve
        case "siren": return .siren
        // Device "button" entities are left out: most restart or reset something.
        case "scene", "script", "input_button": return .button
        case "sensor", "binary_sensor": return cls.map(sensorClasses.contains) == true ? .sensor : nil
        default: return nil
        }
    }

    static func climateModes(_ a: JSON) -> [String] { strings(a, "hvac_modes").filter { $0 != "off" } }

    /// Remote keys a media player has, by its supported features.
    static func mediaKeys(_ f: Int) -> [String] {
        var out: [String] = []
        if f & (4 | 1024) != 0 { out += ["volumeUp", "volumeDown"] }
        if f & 8 != 0 { out.append("mute") }
        if f & (1 | 16384) != 0 { out.append("playPause") }
        if f & 4096 != 0 { out.append("stop") }
        if f & 16 != 0 { out.append("rewind") }
        if f & 32 != 0 { out.append("forward") }
        return out
    }

    public static func capabilities(for e: JSON, _ kind: DeviceKind) -> Set<Capability> {
        let a = attrs(e), f = features(a)
        func s(_ c: Capability?...) -> Set<Capability> { Set(c.compactMap { $0 }) }
        switch domain(e) {
        case "light":
            let modes = Set(strings(a, "supported_color_modes"))
            return s(.onOff, modes.contains { $0 != "onoff" } ? .brightness : nil, modes.contains("color_temp") ? .colorTemp : nil,
                     modes.contains { ["hs", "xy", "rgb", "rgbw", "rgbww"].contains($0) } ? .color : nil)
        case "cover": return s(.position, f & 4 == 0 ? .onOff : nil)
        case "fan": return s(.onOff, f & 1 != 0 ? .speed : nil, f & 8 != 0 && !strings(a, "preset_modes").isEmpty ? .mode : nil)
        case "humidifier": return s(.onOff, .humidity, !strings(a, "available_modes").isEmpty ? .mode : nil)
        case "climate": return s(.onOff, .targetTemp, climateModes(a).count > 1 ? .mode : nil)
        case "water_heater": return s(f & 8 != 0 ? .onOff : nil, .targetTemp, f & 2 != 0 && !strings(a, "operation_list").isEmpty ? .mode : nil)
        case "vacuum": return s(.run, f & 16 != 0 ? .dock : nil, f & 512 != 0 ? .locate : nil,
                                f & 32 != 0 && !strings(a, "fan_speed_list").isEmpty ? .mode : nil)
        case "lawn_mower": return s(.run, f & 4 != 0 ? .dock : nil)
        case "media_player": return s(f & (128 | 256) != 0 ? .onOff : nil, f & 4 != 0 ? .volume : nil,
                                      !mediaKeys(f).isEmpty ? .remote : nil,
                                      f & 2048 != 0 && !strings(a, "source_list").isEmpty ? .mode : nil)
        case "alarm_control_panel": return [.alarm]
        case "valve", "siren": return [.onOff]
        case "camera": return [.snapshot]
        case "scene", "script", "input_button": return [.press]
        default: return defaultCapabilities(kind)
        }
    }

    /// What the app needs to know besides the state: modes to pick from, how an alarm is armed...
    public static func props(for e: JSON) -> [String: JSON?] {
        let domain = Self.domain(e), a = attrs(e), f = features(a)
        var arms: [String] = []
        if f & 1 != 0 { arms.append("home") }
        if f & 2 != 0 { arms.append("away") }
        if f & 4 != 0 { arms.append("night") }
        if f & 32 != 0 { arms.append("vacation") }
        let modes: [String] = switch domain {
        case "fan": strings(a, "preset_modes")
        case "humidifier": strings(a, "available_modes")
        case "climate": climateModes(a)
        case "water_heater": strings(a, "operation_list").filter { $0 != "off" }
        case "vacuum": strings(a, "fan_speed_list")
        case "media_player": strings(a, "source_list")
        default: []
        }
        func list(_ l: [String]) -> JSON { .array(l.map { .string($0) }) }
        var out: [String: JSON?] = ["domain": JSON(domain)]
        if !modes.isEmpty { out["modes"] = list(modes) }
        if domain == "humidifier" {
            out["minHumidity"] = JSON(a["min_humidity"]?.double ?? 30)
            out["maxHumidity"] = JSON(a["max_humidity"]?.double ?? 80)
        }
        if domain == "vacuum" && f & 8 == 0 { out["noStop"] = JSON(true) }
        if domain == "media_player" { out["keys"] = list(mediaKeys(f)) }
        if domain == "alarm_control_panel" {
            if !arms.isEmpty { out["arms"] = list(arms) }
            out["codeFormat"] = a["code_format"]
            out["codeArmRequired"] = JSON(a["code_arm_required"]?.bool ?? true)
        }
        return out
    }

    public static func parseState(_ e: JSON) -> DeviceState {
        let id = entityId(e)
        let domain = String(id.split(separator: ".").first ?? "")
        let state = e["state"]?.description ?? ""
        let a = attrs(e)
        let reachable = state != "unavailable"
        switch domain {
        case "sensor", "binary_sensor":
            let label = a["friendly_name"]?.string ?? id
            let unit = a["unit_of_measurement"]?.string
            let value = domain == "binary_sensor" ? (state == "on" ? "Detected" : "Clear") : state
            return DeviceState(readings: [label: unit.map { "\(value) \($0)" } ?? value], reachable: reachable)
        case "cover":
            let open = state == "open" || state == "opening"
            return DeviceState(on: open, position: a["current_position"]?.double.map { $0 / 100 } ?? (open ? 1 : 0), reachable: reachable)
        case "climate", "water_heater":
            let mode: String? = state == "off" || !reachable ? nil : (domain == "water_heater" ? a["operation_mode"]?.string ?? state : state)
            return DeviceState(on: state != "off", targetTemp: a["temperature"]?.double, currentTemp: a["current_temperature"]?.double,
                               mode: mode, reachable: reachable)
        case "humidifier":
            return DeviceState(on: state == "on", mode: a["mode"]?.string, targetHumidity: a["humidity"]?.double,
                               currentHumidity: a["current_humidity"]?.double, reachable: reachable)
        case "fan":
            let pct = a["percentage"]?.double
            return DeviceState(on: state == "on", mode: a["preset_mode"]?.string ?? "",
                               speed: state == "on" && (pct ?? 0) > 0 ? pct! / 100 : nil, reachable: reachable)
        case "lock":
            return DeviceState(locked: state == "locked", reachable: reachable)
        case "media_player":
            let title = a["media_title"]?.string, artist = a["media_artist"]?.string
            let on = !["off", "standby", "unavailable"].contains(state)
            let playing = !on || title == nil ? "Nothing" : (artist.map { "\($0) - \(title!)" } ?? title!)
            return DeviceState(on: on, volume: a["volume_level"]?.double, muted: a["is_volume_muted"]?.bool, mode: a["source"]?.string,
                               readings: ["Playing": playing], reachable: reachable)
        case "vacuum":
            let activity: String? = switch state {
            case "cleaning": Activity.running
            case "paused": Activity.paused
            case "returning": Activity.returning
            case "docked": Activity.docked
            case "idle": Activity.idle
            case "error": Activity.error
            default: nil
            }
            let status = a["status"]?.string
            return DeviceState(activity: activity, battery: a["battery_level"]?.double.map { $0.clamped(0, 100) / 100 },
                               mode: a["fan_speed"]?.string,
                               readings: ["Error": activity == Activity.error ? status ?? "" : ""], reachable: reachable)
        case "lawn_mower":
            let activity: String? = switch state {
            case "mowing": Activity.running
            case "paused": Activity.paused
            case "returning": Activity.returning
            case "docked": Activity.docked
            case "error": Activity.error
            default: nil
            }
            return DeviceState(activity: activity, reachable: reachable)
        case "alarm_control_panel":
            return DeviceState(activity: reachable && state != "unknown" ? state : nil, reachable: reachable)
        case "valve":
            return DeviceState(on: state == "open" || state == "opening", reachable: reachable)
        case "scene", "script", "input_button", "camera":
            return DeviceState(reachable: reachable)
        case "light":
            let rgb = a["rgb_color"]?.array
            let mode = a["color_mode"]?.string
            return DeviceState(on: state == "on", brightness: a["brightness"]?.double.map { $0 / 255 },
                               colorTempK: mode == "color_temp" ? a["color_temp_kelvin"]?.int : nil,
                               color: mode != "color_temp" && rgb?.count == 3 ? ColorMath.rgb(rgb![0].int ?? 0, rgb![1].int ?? 0, rgb![2].int ?? 0) : nil,
                               reachable: reachable)
        default:
            return DeviceState(on: state == "on", reachable: reachable)
        }
    }

    /// The battery sensor of a robot (`sensor.<robot>_battery`).
    static func batterySensor(of robotId: String, _ all: [JSON]) -> JSON? {
        let obj = robotId.split(separator: ".", maxSplits: 1).last.map(String.init) ?? robotId
        return all.first { entityId($0).hasPrefix("sensor.\(obj)") && attrs($0)["device_class"]?.string == "battery" }
    }

    static func withBattery(_ id: String, _ s: DeviceState, _ all: [JSON]) -> DeviceState {
        if s.battery != nil || !(id.hasPrefix("vacuum.") || id.hasPrefix("lawn_mower.")) { return s }
        guard let level = batterySensor(of: id, all)?["state"]?.double else { return s }
        return s.merging(DeviceState(battery: level.clamped(0, 100) / 100, reachable: s.reachable))
    }
}
