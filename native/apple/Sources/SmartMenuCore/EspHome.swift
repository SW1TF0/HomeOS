import Foundation

/// ESPHome nodes with the `web_server:` component enabled. Entities are read from the node's event stream and controlled
/// through its REST endpoints.
public final class EspHomeDriver: HostListDriver, @unchecked Sendable {
    static let sensorDomains: Set<String> = ["sensor", "binary_sensor", "text_sensor"]

    /// Reads the "state" events a node sends right after connecting: an object of entity key ("domain/object") to its JSON.
    public override func readHost(_ host: String) async throws -> JSON {
        let box = Box()
        let status = try await http.readLines("http://\(host)/events", headers: ["Accept": "text/event-stream"], for: 2.5) { line in
            box.take(line)
        }
        if status != 200 { throw IntegrationError("\(host) answered HTTP \(status). Is web_server enabled?") }
        return .object(box.entities)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var event = ""
        private var found: [String: JSON] = [:]
        var entities: [String: JSON] { lock.lock(); defer { lock.unlock() }; return found }

        func take(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:"), event == "state",
                      let j = try? JSON.parse(line.dropFirst(5).trimmingCharacters(in: .whitespaces)),
                      let key = EspHomeDriver.entityKey(j["id"]?.string ?? "") {
                found[key] = j
            }
        }
    }

    private static func label(_ key: String, _ j: JSON) -> String {
        j["name"]?.string ?? (key.split(separator: "/", maxSplits: 1).last.map(String.init) ?? key).replacingOccurrences(of: "_", with: " ")
    }

    public override func probe(_ host: String) async throws -> [Device] {
        let entities = try await readHost(host).object ?? [:]
        if entities.isEmpty { throw IntegrationError("\(host) sent no entities. Add `web_server:` to its ESPHome config.") }
        let node = host.split(separator: ".").first.map(String.init) ?? host
        var out: [Device] = []
        var readings: [String: String] = [:]
        for (key, j) in entities.sorted(by: { $0.key < $1.key }) {
            let domain = String(key.split(separator: "/").first ?? "")
            let name = EspHomeDriver.label(key, j)
            if EspHomeDriver.sensorDomains.contains(domain) {
                readings[name] = (j["state"] ?? j["value"])?.description ?? ""
                continue
            }
            let kind: DeviceKind
            switch domain {
            case "light": kind = .light
            case "switch": kind = .toggle
            case "fan": kind = .fan
            case "cover": kind = .cover
            case "lock": kind = .lock
            default: continue
            }
            let caps: Set<Capability>? = kind == .light ? (j["brightness"] != nil ? [.onOff, .brightness] : [.onOff]) : nil
            var d = makeDevice("\(host)#\(key)", name, kind, capabilities: caps, props: ["host": JSON(host), "entity": JSON(key)])
            d.state = DeviceState().merging(state(d, from: .object(entities)) ?? DeviceState())
            out.append(d)
        }
        if !readings.isEmpty {
            out.append(makeDevice("\(host)#sensors", "\(node) sensors", .sensor, props: ["host": JSON(host), "entity": "sensors"],
                                  state: DeviceState(readings: readings)))
        }
        return out
    }

    public override func state(_ d: Device, from data: JSON) -> DeviceState? {
        guard let entities = data.object, let key = d.prop("entity") else { return nil }
        if key == "sensors" {
            var readings: [String: String] = [:]
            for (k, j) in entities where EspHomeDriver.sensorDomains.contains(String(k.split(separator: "/").first ?? "")) {
                readings[EspHomeDriver.label(k, j)] = (j["state"] ?? j["value"])?.description ?? ""
            }
            return DeviceState(readings: readings)
        }
        guard let j = entities[key] else { return .unreachable }
        let state = (j["state"]?.description ?? "").uppercased()
        let value = j["value"]
        let on: Bool = if let value, let b = value.bool, !value.isNumber { b } else { state == "ON" || state == "OPEN" }
        return DeviceState(
            on: on,
            brightness: j["brightness"]?.isNumber == true ? j["brightness"]!.double! / 255 : nil,
            position: d.kind == .cover && j["position"]?.isNumber == true ? j["position"]?.double : nil,
            locked: d.kind == .lock ? state == "LOCKED" : nil)
    }

    public override func send(_ d: Device, _ c: DeviceCommand) async throws -> DeviceState? {
        let host = d.prop("host") ?? "", entity = d.prop("entity") ?? ""
        let parts = entity.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        func post(_ action: String, _ q: [(String, String)] = []) async throws {
            let obj = parts[1].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? parts[1]
            let url = "http://\(host)/\(parts[0])/\(obj)/\(action)" + (q.isEmpty ? "" : "?" + query(q))
            let res = try await http.request("POST", url)
            if res.status >= 400 { throw IntegrationError("\(host) answered HTTP \(res.status).") }
        }
        if let p = c.position { try await post("set", [("position", String(format: "%.2f", p))]) }
        else if let l = c.locked { try await post(l ? "lock" : "unlock") }
        else if let b = c.brightness { try await post("turn_on", [("brightness", "\(Int((b * 255).rounded()))")]) }
        else if let on = c.on { try await post(on ? "turn_on" : "turn_off") }
        return nil
    }

    /// "light-desk_lamp" (web_server v1/v2) or "light/Desk Lamp" (v3) to "light/desk_lamp".
    public static func entityKey(_ id: String) -> String? {
        guard let r = id.range(of: #"^[a-z_]+[-/]"#, options: .regularExpression), r.upperBound < id.endIndex else { return nil }
        return "\(id[id.startIndex..<id.index(before: r.upperBound)])/\(id[r.upperBound...])"
    }
}
