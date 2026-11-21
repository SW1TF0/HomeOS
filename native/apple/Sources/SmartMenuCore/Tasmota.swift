import Foundation

/// Devices running the open Tasmota firmware, over its HTTP command API.
public final class TasmotaDriver: HostListDriver, @unchecked Sendable {
    private var password: String { config.setting("password") }

    private func cmd(_ host: String, _ command: String) async throws -> JSON? {
        var q: [(String, String)] = []
        if !password.isEmpty { q += [("user", "admin"), ("password", password)] }
        q.append(("cmnd", command))
        return try await getJSON("http://\(host)/cm?" + query(q))
    }

    public override func readHost(_ host: String) async throws -> JSON { try await cmd(host, "Status 0") ?? .null }

    public override func probe(_ host: String) async throws -> [Device] {
        let data = try await readHost(host)
        guard data.object != nil else { throw IntegrationError("\(host) is not a Tasmota device.") }
        let status = data["Status"] ?? [:]
        let sts = data["StatusSTS"]?.object ?? [:]
        let names = status["FriendlyName"]?.array?.map(\.description) ?? []
        let deviceName = status["DeviceName"]?.string ?? names.first ?? "Tasmota"
        let powerKeys = sts.keys.filter { $0.range(of: #"^POWER\d*$"#, options: .regularExpression) != nil }.sorted()
        let isLight = sts["Dimmer"] != nil
        var out: [Device] = []
        for key in powerKeys {
            let idx = key == "POWER" ? 1 : Int(key.dropFirst(5)) ?? 1
            var caps: Set<Capability> = [.onOff]
            if isLight && idx == 1 {
                caps.insert(.brightness)
                if sts["CT"] != nil { caps.insert(.colorTemp) }
                if sts["HSBColor"] != nil { caps.insert(.color) }
            }
            let given = idx - 1 < names.count ? names[idx - 1] : ""
            let name = !given.isEmpty ? given : (powerKeys.count == 1 ? deviceName : "\(deviceName) \(idx)")
            var d = makeDevice("\(host)#\(idx)", name, isLight && idx == 1 ? .light : .outlet, capabilities: caps,
                               props: ["host": JSON(host), "channel": JSON(idx)])
            d.state = DeviceState().merging(state(d, from: data) ?? DeviceState())
            out.append(d)
        }
        let readings = TasmotaDriver.readings(data["StatusSNS"])
        if !readings.isEmpty {
            out.append(makeDevice("\(host)#sensor", "\(deviceName) sensor", .sensor, props: ["host": JSON(host), "channel": 0],
                                  state: DeviceState(readings: readings)))
        }
        return out
    }

    public override func state(_ d: Device, from data: JSON) -> DeviceState? {
        guard data.object != nil else { return nil }
        let idx = d.props["channel"]?.int ?? 1
        if idx == 0 { return DeviceState(readings: TasmotaDriver.readings(data["StatusSNS"])) }
        let sts = data["StatusSTS"] ?? data
        let power = sts["POWER\(idx)"] ?? (idx == 1 ? sts["POWER"] : nil)
        let hsb = sts["HSBColor"]?.string
        let white = sts["White"]?.double
        return DeviceState(
            on: power.map { $0.description == "ON" },
            brightness: d.has(.brightness) ? sts["Dimmer"]?.double.map { $0 / 100 } : nil,
            colorTempK: d.has(.colorTemp) && (white == nil || white! > 0) ? sts["CT"]?.double.map(ColorMath.miredToKelvin) : nil,
            color: d.has(.color) && (white == nil || white == 0) ? hsb.flatMap(TasmotaDriver.hsbToRgb) : nil)
    }

    public override func send(_ d: Device, _ c: DeviceCommand) async throws -> DeviceState? {
        let host = d.prop("host") ?? ""
        let idx = d.props["channel"]?.int ?? 1
        if let on = c.on { _ = try await cmd(host, "Power\(idx) \(on ? "On" : "Off")") }
        if let b = c.brightness { _ = try await cmd(host, "Dimmer \(Int((b * 100).rounded()))") }
        if let k = c.colorTempK { _ = try await cmd(host, "CT \(ColorMath.kelvinToMired(k).clamped(153, 500))") }
        if let col = c.color { _ = try await cmd(host, "Color \(ColorMath.hex(col))") }
        return nil
    }

    public static func readings(_ sns: JSON?) -> [String: String] {
        var out: [String: String] = [:]
        guard let sns = sns?.object else { return out }
        let unit = sns["TempUnit"]?.string ?? "C"
        for (_, values) in sns {
            for (k, v) in values.object ?? [:] where v.isNumber {
                let pair: (String, String)? = switch k {
                case "Temperature": ("Temperature", " °\(unit)")
                case "Humidity": ("Humidity", " %")
                case "Pressure": ("Pressure", " hPa")
                case "Power": ("Power", " W")
                case "Voltage": ("Voltage", " V")
                case "Today": ("Energy today", " kWh")
                default: nil
                }
                if let pair { out[pair.0] = "\(v.description)\(pair.1)" }
            }
        }
        return out
    }

    public static func hsbToRgb(_ hsb: String) -> Int? {
        let p = hsb.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        guard p.count >= 3 else { return nil }
        return ColorMath.hsvToRgb(p[0], p[1] / 100, 1)
    }
}
