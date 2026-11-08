import Foundation

/// Shelly relays, dimmers, plugs, roller shutters and H&T sensors over their local HTTP API. Supports Gen1 and Gen2+
/// (Plus / Pro / Gen3 / Gen4).
public final class ShellyDriver: HostListDriver, @unchecked Sendable {
    private func u(_ host: String, _ path: String, _ q: [(String, String)] = []) -> String {
        "http://\(host)\(path)" + (q.isEmpty ? "" : "?" + query(q))
    }

    public override func probe(_ host: String) async throws -> [Device] {
        guard let info = try await getJSON(u(host, "/shelly")), info.object != nil else { throw IntegrationError("\(host) is not a Shelly.") }
        let gen = info["gen"]?.int ?? 1
        let base = info["name"]?.string ?? info["type"]?.string ?? info["model"]?.string ?? "Shelly"
        return gen >= 2 ? try await probeGen2(host, base) : try await probeGen1(host, base)
    }

    private func props(_ host: String, _ gen: Int, _ comp: String, _ ch: Int) -> [String: JSON?] {
        ["host": JSON(host), "gen": JSON(gen), "component": JSON(comp), "channel": JSON(ch)]
    }

    private func probeGen2(_ host: String, _ base: String) async throws -> [Device] {
        let status = try await readHost(host).object ?? [:]
        let config = try? await getJSON(u(host, "/rpc/Shelly.GetConfig"))
        var out: [Device] = []
        var readings: [String: String] = [:]
        for key in status.keys.sorted() {
            let parts = key.split(separator: ":").map(String.init)
            guard parts.count == 2 else { continue }
            let comp = parts[0], ch = Int(parts[1]) ?? 0
            let label = config?[key]?["name"]?.string
            func name(_ fallback: String) -> String { label ?? (ch == 0 ? base : "\(base) \(fallback) \(ch + 1)") }
            let p = props(host, 2, comp, ch)
            switch comp {
            case "switch": out.append(makeDevice("\(host)#switch:\(ch)", name("switch"), .outlet, props: p, state: ShellyDriver.gen2State(comp, status[key])))
            case "light": out.append(makeDevice("\(host)#light:\(ch)", name("light"), .light, capabilities: [.onOff, .brightness], props: p,
                                                state: ShellyDriver.gen2State(comp, status[key])))
            case "cover": out.append(makeDevice("\(host)#cover:\(ch)", name("cover"), .cover, props: p, state: ShellyDriver.gen2State(comp, status[key])))
            case "temperature", "humidity", "devicepower": readings.merge(ShellyDriver.gen2Readings([key: status[key]!])) { $1 }
            default: break
            }
        }
        if !readings.isEmpty {
            out.append(makeDevice("\(host)#sensor", "\(base) sensor", .sensor, props: props(host, 2, "sensor", 0), state: DeviceState(readings: readings)))
        }
        return out
    }

    private func probeGen1(_ host: String, _ base: String) async throws -> [Device] {
        let status = try await readHost(host).object ?? [:]
        let mode = (try? await getJSON(u(host, "/settings")))?["mode"]?.string ?? "relay"
        var out: [Device] = []
        func add(_ comp: String, _ kind: DeviceKind, _ count: Int, _ caps: Set<Capability>?) {
            for ch in 0..<count {
                var d = makeDevice("\(host)#\(comp):\(ch)", count == 1 ? base : "\(base) \(ch + 1)", kind, capabilities: caps,
                                   props: props(host, 1, comp, ch))
                d.state = DeviceState().merging(ShellyDriver.gen1State(comp, ch, status))
                out.append(d)
            }
        }
        let relays = status["relays"]?.array?.count ?? 0
        let lights = status["lights"]?.array?.count ?? 0
        let rollers = status["rollers"]?.array?.count ?? 0
        if mode == "roller" && rollers > 0 { add("roller", .cover, rollers, nil) } else if relays > 0 { add("relay", .outlet, relays, nil) }
        if lights > 0 { add("light", .light, lights, [.onOff, .brightness]) }
        let readings = ShellyDriver.gen1Readings(status)
        if !readings.isEmpty {
            out.append(makeDevice("\(host)#sensor", "\(base) sensor", .sensor, props: props(host, 1, "sensor", 0), state: DeviceState(readings: readings)))
        }
        return out
    }

    /// Gen2 answers /rpc; Gen1 answers /status.
    public override func readHost(_ host: String) async throws -> JSON {
        if let j = try? await getJSON(u(host, "/rpc/Shelly.GetStatus")), j.object != nil { return j }
        guard let j = try await getJSON(u(host, "/status")), j.object != nil else { throw IntegrationError("\(host) sent no status.") }
        return j
    }

    public override func state(_ d: Device, from data: JSON) -> DeviceState? {
        guard let status = data.object, let comp = d.prop("component") else { return nil }
        let ch = d.props["channel"]?.int ?? 0
        if d.props["gen"]?.int == 1 {
            return comp == "sensor" ? DeviceState(readings: ShellyDriver.gen1Readings(status)) : ShellyDriver.gen1State(comp, ch, status)
        }
        if comp == "sensor" { return DeviceState(readings: ShellyDriver.gen2Readings(status)) }
        return ShellyDriver.gen2State(comp, status["\(comp):\(ch)"])
    }

    public override func send(_ d: Device, _ c: DeviceCommand) async throws -> DeviceState? {
        let host = d.prop("host") ?? "", comp = d.prop("component") ?? ""
        let ch = "\(d.props["channel"]?.int ?? 0)"
        func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()).clamped(1, 100))" }
        if d.props["gen"]?.int == 1 {
            switch comp {
            case "roller":
                if let p = c.position { _ = try await getJSON(u(host, "/roller/\(ch)", [("go", "to_pos"), ("roller_pos", "\(Int((p * 100).rounded()))")])) }
            case "light":
                var q: [(String, String)] = []
                if let b = c.brightness { q = [("turn", "on"), ("brightness", pct(b))] } else if let on = c.on { q = [("turn", on ? "on" : "off")] }
                _ = try await getJSON(u(host, "/light/\(ch)", q))
            default:
                if let on = c.on { _ = try await getJSON(u(host, "/relay/\(ch)", [("turn", on ? "on" : "off")])) }
            }
            return nil
        }
        switch comp {
        case "cover":
            if let p = c.position { _ = try await getJSON(u(host, "/rpc/Cover.GoToPosition", [("id", ch), ("pos", "\(Int((p * 100).rounded()))")])) }
        case "light":
            var q = [("id", ch)]
            if let b = c.brightness { q += [("on", "true"), ("brightness", pct(b))] } else if let on = c.on { q.append(("on", "\(on)")) }
            _ = try await getJSON(u(host, "/rpc/Light.Set", q))
        default:
            if let on = c.on { _ = try await getJSON(u(host, "/rpc/Switch.Set", [("id", ch), ("on", "\(on)")])) }
        }
        return nil
    }

    public static func gen2State(_ comp: String, _ s: JSON?) -> DeviceState {
        let st = s ?? [:]
        switch comp {
        case "cover": return DeviceState(position: (st["current_pos"]?.double ?? 0) / 100)
        case "light": return DeviceState(on: st["output"]?.bool, brightness: st["brightness"]?.double.map { $0 / 100 })
        default: return DeviceState(on: st["output"]?.bool, readings: st["apower"].map { ["Power": "\($0.description) W"] } ?? [:])
        }
    }

    public static func gen2Readings(_ status: [String: JSON]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, m) in status where m.object != nil {
            if k.hasPrefix("temperature:"), let t = m["tC"] { out["Temperature"] = "\(t.description) °C" }
            if k.hasPrefix("humidity:"), let h = m["rh"] { out["Humidity"] = "\(h.description) %" }
            if k.hasPrefix("devicepower:"), let b = m["battery"]?["percent"] { out["Battery"] = "\(b.description) %" }
        }
        return out
    }

    public static func gen1State(_ comp: String, _ ch: Int, _ status: [String: JSON]) -> DeviceState {
        func item(_ key: String) -> JSON { status[key]?[ch] ?? [:] }
        switch comp {
        case "roller": return DeviceState(position: (item("rollers")["current_pos"]?.double ?? 0) / 100)
        case "light": return DeviceState(on: item("lights")["ison"]?.bool, brightness: item("lights")["brightness"]?.double.map { $0 / 100 })
        default: return DeviceState(on: item("relays")["ison"]?.bool)
        }
    }

    public static func gen1Readings(_ status: [String: JSON]) -> [String: String] {
        var out: [String: String] = [:]
        if let t = status["tmp"], let v = t["value"] { out["Temperature"] = "\(v.description) °\(t["units"]?.string ?? "C")" }
        if let v = status["hum"]?["value"] { out["Humidity"] = "\(v.description) %" }
        if let v = status["bat"]?["value"] { out["Battery"] = "\(v.description) %" }
        return out
    }
}
