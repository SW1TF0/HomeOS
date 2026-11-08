import Foundation

/// Words for showing devices on screen.
public enum Describe {
    /// "Cleaning", "Going home", "Armed away"... for `DeviceState.activity`.
    public static func activity(_ kind: DeviceKind, _ activity: String?) -> String {
        guard let activity else { return kind == .alarm ? "Unknown" : "Ready" }
        switch activity {
        case Activity.running: return kind == .vacuum ? "Cleaning" : kind == .mower ? "Mowing" : "Running"
        case Activity.paused: return "Paused"
        case Activity.returning: return "Going home"
        case Activity.docked: return "Docked"
        case Activity.charging: return "Charging"
        case Activity.idle: return "Idle"
        case Activity.error: return "Needs help"
        case Activity.disarmed: return "Disarmed"
        case Activity.armedHome: return "Armed home"
        case Activity.armedAway: return "Armed away"
        case Activity.armedNight: return "Armed night"
        case Activity.armedVacation: return "Armed vacation"
        case Activity.armedCustom: return "Armed"
        case Activity.arming: return "Arming"
        case Activity.pending: return "Entry delay"
        case Activity.disarming: return "Disarming"
        case Activity.triggered: return "ALARM"
        default: return mode(activity)
        }
    }

    /// "fan_only" -> "Fan", "heat_cool" -> "Heat/cool".
    public static func mode(_ mode: String) -> String {
        let m = mode.trimmingCharacters(in: .whitespaces)
        if m.isEmpty { return m }
        let known = ["heat_cool": "Heat/cool", "fan_only": "Fan", "dry": "Dry", "auto": "Auto", "off": "Off"]
        if let k = known[m.lowercased()] { return k }
        let spaced = m.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    public static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    static func one(_ v: Double) -> String { String(format: "%.1f", v) }

    private static func join(_ parts: [String?]) -> String { parts.compactMap { $0 }.joined(separator: " · ") }

    /// One-line description of a device's state, e.g. "On · 72%".
    public static func state(_ d: Device) -> String {
        let s = d.state
        if !s.reachable { return "Not responding" }
        let first = s.readings.sorted { $0.key < $1.key }.first?.value
        switch d.kind {
        case .cover, .garage:
            if s.position == nil, let on = s.on { return on ? "Open" : "Closed" }
            let p = s.position ?? 0
            return p <= 0.01 ? "Closed" : p >= 0.99 ? "Open" : "Open \(pct(p))"
        case .valve:
            guard let on = s.on else { return first ?? "Unknown" }
            return on ? "Open" : "Closed"
        case .siren:
            guard let on = s.on else { return "Unknown" }
            return on ? "Sounding" : "Off"
        case .vacuum, .mower, .appliance:
            let err = s.activity == Activity.error ? s.readings["Error"].flatMap { $0.isEmpty ? nil : $0 } : nil
            return join([err ?? activity(d.kind, s.activity), s.battery.map(pct)])
        case .alarm: return activity(d.kind, s.activity)
        case .button: return "Tap to run"
        case .camera: return first ?? "Camera"
        case .humidifier:
            let t = join([s.currentHumidity.map { "\(Int($0.rounded()))%" },
                          s.on == false ? "Off" : s.targetHumidity.map { "set \(Int($0.rounded()))%" }])
            return t.isEmpty ? (s.on == true ? "On" : "Off") : t
        case .lock:
            guard let l = s.locked else { return "Unknown" }
            return l ? "Locked" : "Unlocked"
        case .climate:
            let m = d.has(.mode) && s.mode != nil ? mode(s.mode!) : "set"
            let t = join([s.currentTemp.map { "\(one($0))°" }, s.on == false ? "Off" : s.targetTemp.map { "\(m) \(one($0))°" }])
            return t.isEmpty ? "Climate" : t
        case .sensor:
            if s.readings.isEmpty { return "No readings yet" }
            return s.readings.sorted { $0.key < $1.key }.prefix(2).map(\.value).joined(separator: " · ")
        case .media:
            let vol: String? = s.on != false && s.muted == true ? "Muted" : (s.on != false ? s.volume.map { "Vol \(Int(($0 * 100).rounded()))" } : nil)
            let playing = s.readings["Playing"].flatMap { s.on != false && $0 != "Nothing" ? $0 : nil }
            let t = join([s.on.map { $0 ? "On" : "Off" }, vol, playing])
            return t.isEmpty ? first ?? "Unknown" : t
        default:
            guard let on = s.on else { return first ?? "Unknown" }
            if !on { return "Off" }
            if d.has(.brightness), let b = s.brightness { return "On · \(pct(b))" }
            if d.has(.mode), let m = s.mode { return "On · \(mode(m))" }
            if d.has(.speed), let sp = s.speed { return "On · \(pct(sp))" }
            return "On"
        }
    }

    /// A device's temperature reading in °C, from a thermostat or a sensor.
    public static func temperature(_ d: Device) -> Double? {
        if !d.state.reachable { return nil }
        if let t = d.state.currentTemp { return t }
        guard let raw = d.state.readings["Temperature"], let r = raw.range(of: #"-?\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return Double(raw[r])
    }

    public static func averageTemperature(_ devices: [Device]) -> Double? {
        let t = devices.compactMap(temperature)
        return t.isEmpty ? nil : t.reduce(0, +) / Double(t.count)
    }

    /// The colour (0xRRGGBB) a light gives off, for the glow on tiles and the map.
    public static func lightColor(_ d: Device) -> Int? {
        guard d.kind == .light, d.state.on == true else { return nil }
        return d.state.color ?? d.state.colorTempK.map(ColorMath.kelvinToRgb)
    }

    /// Whether a tap switches the device (instead of opening its controls).
    public static func tapToggles(_ d: Device) -> Bool {
        d.has(.lock) || d.has(.onOff) || d.has(.position) || d.has(.press) || (d.has(.run) && (d.kind == .vacuum || d.kind == .mower))
    }

    /// The 0..1 level a tile can drag: brightness, blind position, volume, fan speed.
    public static func level(_ d: Device) -> Double? {
        if d.has(.brightness) { return d.state.on == false ? 0 : d.state.brightness }
        if d.has(.position) { return d.state.position }
        if d.has(.speed) { return d.state.on == false ? 0 : d.state.speed }
        if d.has(.volume) { return d.state.volume }
        return nil
    }

    public static func levelCommand(_ d: Device, _ v: Double) -> DeviceCommand? {
        if d.has(.brightness) { return v <= 0.01 ? DeviceCommand(on: false) : DeviceCommand(brightness: v) }
        if d.has(.position) { return DeviceCommand(position: v) }
        if d.has(.speed) { return v <= 0.01 ? DeviceCommand(on: false) : DeviceCommand(speed: v) }
        if d.has(.volume) { return DeviceCommand(volume: v) }
        return nil
    }
}
