import Foundation

/// Philips Hue bridge, over its local API. No Hue account or cloud needed.
public final class HueDriver: IntegrationDriver, @unchecked Sendable {
    private var host: String { config.setting("host") }
    private var username: String { config.setting("username") }
    private func api(_ path: String) -> String { "http://\(host)/api/\(username)\(path)" }

    private func requireSetup() throws {
        if host.isEmpty { throw IntegrationError("Enter the bridge address, or use Scan network.") }
        if username.isEmpty { throw IntegrationError("Press the bridge's link button, then tap Pair.") }
    }

    public override func pair() async throws -> [String: String] {
        if host.isEmpty { throw IntegrationError("Enter the bridge address first.") }
        let res = try await sendJSON("POST", "http://\(host)/api", ["devicetype": "smartmenukj#native"])
        let first = res?[0]
        if let u = first?["success"]?["username"]?.string { return ["username": u] }
        let err = first?["error"]?["description"]?.string ?? "unexpected reply"
        throw IntegrationError("Bridge said: \(err). Press the round link button on the bridge, then tap Pair within 30 seconds.")
    }

    private func throwHueError(_ res: JSON?) throws {
        if let err = res?[0]?["error"] { throw IntegrationError("Hue bridge: \(err["description"]?.string ?? "error")") }
    }

    private func lights() async throws -> [String: JSON] {
        try requireSetup()
        let res = try await getJSON(api("/lights"))
        try throwHueError(res)
        return res?.object ?? [:]
    }

    public override func discover() async throws -> [Device] {
        try await lights().sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { toDevice($0.key, $0.value) }
    }

    private func toDevice(_ id: String, _ light: JSON) -> Device {
        let st = light["state"] ?? [:]
        let type = (light["type"]?.string ?? "").lowercased()
        var caps: Set<Capability> = [.onOff]
        if st["bri"] != nil { caps.insert(.brightness) }
        if st["ct"] != nil { caps.insert(.colorTemp) }
        if st["xy"] != nil { caps.insert(.color) }
        return makeDevice(id, light["name"]?.string ?? "Hue light \(id)", type.contains("plug") ? .outlet : .light,
                          capabilities: caps, props: ["model": light["modelid"], "type": light["type"]],
                          state: HueDriver.parseState(st))
    }

    public override func refreshAll(_ devices: [Device]) async -> [String: DeviceState] {
        guard let all = try? await lights() else {
            return Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.state.merging(.unreachable)) })
        }
        return Dictionary(uniqueKeysWithValues: devices.map { d in
            (d.id, d.state.merging(all[d.externalId]?["state"].map(HueDriver.parseState) ?? .unreachable))
        })
    }

    public override func refresh(_ d: Device) async throws -> DeviceState? {
        try requireSetup()
        let res = try await getJSON(api("/lights/\(d.externalId)"))
        try throwHueError(res)
        return res?["state"].map(HueDriver.parseState)
    }

    public override func send(_ d: Device, _ c: DeviceCommand) async throws -> DeviceState? {
        try requireSetup()
        var body: [String: JSON] = [:]
        if let on = c.on { body["on"] = .bool(on) }
        if let b = c.brightness {
            body["on"] = .bool(b > 0)
            body["bri"] = JSON(Int((b * 253 + 1).rounded()).clamped(1, 254))
        }
        if let k = c.colorTempK { body["ct"] = JSON(ColorMath.kelvinToMired(k).clamped(153, 500)) }
        if let col = c.color { body["xy"] = .array(ColorMath.rgbToXy(col).map { .number($0) }) }
        try throwHueError(try await sendJSON("PUT", api("/lights/\(d.externalId)/state"), .object(body)))
        return nil
    }

    public static func parseState(_ st: JSON) -> DeviceState {
        let xy = st["xy"]?.array
        let mode = st["colormode"]?.string
        return DeviceState(
            on: st["on"]?.bool,
            brightness: st["bri"]?.double.map { ($0 - 1) / 253 },
            colorTempK: mode == "ct" ? st["ct"]?.double.map(ColorMath.miredToKelvin) : nil,
            color: mode != "ct" && xy?.count == 2 ? ColorMath.xyToRgb(xy![0].double ?? 0, xy![1].double ?? 0) : nil,
            reachable: st["reachable"]?.bool ?? true)
    }
}
