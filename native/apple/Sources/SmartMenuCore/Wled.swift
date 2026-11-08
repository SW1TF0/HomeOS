import Foundation

/// LED strips running the open WLED firmware, over its JSON API.
public final class WledDriver: HostListDriver, @unchecked Sendable {
    public override func readHost(_ host: String) async throws -> JSON { try await getJSON("http://\(host)/json/state") ?? .null }

    public override func probe(_ host: String) async throws -> [Device] {
        guard let data = try await getJSON("http://\(host)/json"), data.object != nil else {
            throw IntegrationError("\(host) is not a WLED light.")
        }
        let info = data["info"] ?? [:]
        var d = makeDevice(host, info["name"]?.string ?? "WLED", .light, capabilities: [.onOff, .brightness, .color],
                           props: ["host": JSON(host), "leds": info["leds"]?["count"]])
        d.state = state(d, from: data["state"] ?? .null) ?? DeviceState()
        return [d]
    }

    public override func state(_ d: Device, from data: JSON) -> DeviceState? {
        guard data.object != nil else { return nil }
        let col = data["seg"]?[0]?["col"]?[0]?.array
        let color = col.flatMap { $0.count >= 3 ? ColorMath.rgb($0[0].int ?? 0, $0[1].int ?? 0, $0[2].int ?? 0) : nil }
        return DeviceState(on: data["on"]?.bool, brightness: data["bri"]?.double.map { $0 / 255 }, color: color)
    }

    public override func send(_ d: Device, _ c: DeviceCommand) async throws -> DeviceState? {
        let host = d.prop("host") ?? ""
        var body: [String: JSON] = ["v": true]
        if let on = c.on { body["on"] = .bool(on) }
        if let b = c.brightness {
            body["on"] = .bool(b > 0)
            body["bri"] = JSON(Int((b * 255).rounded()).clamped(1, 255))
        }
        if let col = c.color { body["seg"] = [["col": .array([.array(ColorMath.channels(col).map { JSON($0) })])]] }
        let res = try await sendJSON("POST", "http://\(host)/json/state", .object(body))
        return res.flatMap { state(d, from: $0) }
    }
}
