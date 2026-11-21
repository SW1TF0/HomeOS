import Foundation

/// Something found on the local network, and which integration can use it.
public struct FoundService: Identifiable, Equatable, Sendable {
    public var name: String
    public var host: String
    public var port: Int
    public var integrationType: String
    public init(name: String, host: String, port: Int, integrationType: String) {
        self.name = name; self.host = host; self.port = port; self.integrationType = integrationType
    }

    /// Address to store in an integration's settings.
    public var address: String {
        switch integrationType {
        case "homeassistant": "http://\(host):\(port)"
        case "hue", "esphome": host
        default: port == 80 || port == 0 ? host : "\(host):\(port)"
        }
    }

    public var id: String { "\(integrationType)|\(host)" }
}

/// Works out what devices on the home network are, over plain HTTP: Shelly, WLED, Tasmota, Hue, ESPHome and Home
/// Assistant all answer in their own way. Also asks the free Hue discovery service. Finding the addresses (mDNS and a
/// sweep of the Wi-Fi) is done by the app.
public struct NetworkScanner: Sendable {
    let http: Http
    public init(http: Http) { self.http = http }

    /// Maps an mDNS service type to the integration that uses it.
    public static func type(forService service: String, name: String) -> String? {
        var s = service.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if s.hasSuffix(".local") { s.removeLast(6) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        switch s {
        case "_hue._tcp": return "hue"
        case "_shelly._tcp": return "shelly"
        case "_wled._tcp": return "wled"
        case "_esphomelib._tcp": return "esphome"
        case "_home-assistant._tcp": return "homeassistant"
        case "_http._tcp":
            let n = name.lowercased()
            if n.hasPrefix("shelly") { return "shelly" }
            if n.contains("tasmota") { return "tasmota" }
            if n.hasPrefix("wled") { return "wled" }
            return nil
        default: return nil
        }
    }

    public func hueCloud() async -> [FoundService] {
        guard let res = try? await http.request("GET", "https://discovery.meethue.com/", headers: [:], body: nil, timeout: 4),
              let list = (try? JSON.parse(res.body))?.array else { return [] }
        return list.compactMap { e in e["internalipaddress"]?.string.map { FoundService(name: "Hue bridge", host: $0, port: 80, integrationType: "hue") } }
    }

    private func get(_ url: String) async -> String? {
        guard let r = try? await http.request("GET", url, headers: [:], body: nil, timeout: 1.5), (200..<300).contains(r.status) else { return nil }
        return r.text
    }

    private func json(_ url: String) async -> JSON? { await get(url).flatMap { try? JSON.parse($0) }.flatMap { $0.object != nil ? $0 : nil } }

    /// Works out what answers HTTP on `host`, or nil when it is nothing this app drives.
    public func identify(_ host: String) async -> FoundService? {
        if let j = await json("http://\(host)/shelly"), j["mac"] != nil || j["gen"] != nil || j["type"] != nil {
            return FoundService(name: j["name"]?.string ?? j["type"]?.string ?? j["model"]?.string ?? "Shelly", host: host, port: 80, integrationType: "shelly")
        }
        if let j = await json("http://\(host)/json/info"), j["leds"] != nil {
            return FoundService(name: j["name"]?.string ?? "WLED", host: host, port: 80, integrationType: "wled")
        }
        if let j = await json("http://\(host)/api/config"), j["bridgeid"] != nil {
            return FoundService(name: j["name"]?.string ?? "Hue bridge", host: host, port: 80, integrationType: "hue")
        }
        if let s = await json("http://\(host)/cm?cmnd=Status")?["Status"], s.object != nil {
            return FoundService(name: s["DeviceName"]?.string ?? s["FriendlyName"]?[0]?.string ?? "Tasmota", host: host, port: 80, integrationType: "tasmota")
        }
        if let t = await get("http://\(host)/"), t.range(of: "ESPHome", options: .caseInsensitive) != nil || t.contains("esp-app") {
            var title = host
            if let a = t.range(of: "<title>"), let b = t.range(of: "</title>", range: a.upperBound..<t.endIndex) {
                let found = t[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespaces)
                if !found.isEmpty { title = found }
            }
            return FoundService(name: title, host: host, port: 80, integrationType: "esphome")
        }
        return nil
    }

    /// The Home Assistant API answers 401 without a token.
    public func identifyHomeAssistant(_ host: String) async -> FoundService? {
        guard let r = try? await http.request("GET", "http://\(host):8123/api/", headers: [:], body: nil, timeout: 1.5),
              r.status == 401 || r.status == 200 else { return nil }
        return FoundService(name: "Home Assistant", host: host, port: 8123, integrationType: "homeassistant")
    }

    /// Every other address in the /24 of `ip` (an IPv4 address of this device).
    public static func subnet(of ip: String) -> [String] {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return [] }
        let base = parts.prefix(3).joined(separator: ".")
        return (1...254).map { "\(base).\($0)" }.filter { $0 != ip }
    }
}
