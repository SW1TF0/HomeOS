import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HttpResponse: Sendable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
    public var text: String { String(data: body, encoding: .utf8) ?? "" }
}

/// The app's way onto the network, so tests can answer for devices.
public protocol Http: Sendable {
    func request(_ method: String, _ url: String, headers: [String: String], body: Data?, timeout: TimeInterval) async throws -> HttpResponse
    /// Reads the lines of a stream (server-sent events) for a while, then hangs up. Returns the HTTP status.
    func readLines(_ url: String, headers: [String: String], for seconds: TimeInterval, onLine: @escaping @Sendable (String) -> Void) async throws -> Int
}

public extension Http {
    func request(_ method: String, _ url: String, headers: [String: String] = [:], body: Data? = nil) async throws -> HttpResponse {
        try await request(method, url, headers: headers, body: body, timeout: 6)
    }
}

public final class URLSessionHttp: Http {
    private let session: URLSession

    public init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        session = URLSession(configuration: c)
    }

    public func request(_ method: String, _ url: String, headers: [String: String], body: Data?, timeout: TimeInterval) async throws -> HttpResponse {
        guard let u = URL(string: url) else { throw IntegrationError("\(url) is not an address.") }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = method
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = body
        let (data, res) = try await session.data(for: r)
        return HttpResponse(status: (res as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    public func readLines(_ url: String, headers: [String: String], for seconds: TimeInterval, onLine: @escaping @Sendable (String) -> Void) async throws -> Int {
        guard let u = URL(string: url) else { throw IntegrationError("\(url) is not an address.") }
        var r = URLRequest(url: u, timeoutInterval: 6)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        #if canImport(FoundationNetworking)
        let (data, res) = try await session.data(for: r)
        String(data: data, encoding: .utf8)?.split(separator: "\n", omittingEmptySubsequences: false).forEach { onLine(String($0)) }
        return (res as? HTTPURLResponse)?.statusCode ?? 0
        #else
        let (bytes, res) = try await session.bytes(for: r)
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 { return status }
        let reader = Task {
            for try await line in bytes.lines { onLine(line) }
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        reader.cancel()
        return status
        #endif
    }
}

public struct IntegrationError: Error, LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// A field on an integration's settings form.
public struct SettingField: Sendable {
    public var key: String, label: String, hint = "", secret = false, multiline = false, required = false
    public var defaultValue: String?
    public init(_ key: String, _ label: String, hint: String = "", secret: Bool = false, multiline: Bool = false,
                required: Bool = false, defaultValue: String? = nil) {
        self.key = key; self.label = label; self.hint = hint; self.secret = secret; self.multiline = multiline
        self.required = required; self.defaultValue = defaultValue
    }
}

/// Talks to one configured integration.
public class IntegrationDriver: @unchecked Sendable {
    public let config: IntegrationConfig
    public let http: Http

    public required init(config: IntegrationConfig, http: Http) {
        self.config = config
        self.http = http
    }

    public func discover() async throws -> [Device] { [] }
    public func refresh(_ d: Device) async throws -> DeviceState? { nil }
    public func send(_ d: Device, _ c: DeviceCommand) async throws -> DeviceState? { nil }
    public func pair() async throws -> [String: String] { throw IntegrationError("\(config.name) does not need pairing.") }

    public func refreshAll(_ devices: [Device]) async -> [String: DeviceState] {
        var out: [String: DeviceState] = [:]
        for d in devices {
            if let s = try? await refresh(d) { out[d.id] = d.state.merging(s) } else { out[d.id] = d.state.merging(.unreachable) }
        }
        return out
    }

    public func makeDevice(_ externalId: String, _ name: String, _ kind: DeviceKind, capabilities: Set<Capability>? = nil,
                           props: [String: JSON?] = [:], state: DeviceState = DeviceState()) -> Device {
        Device(id: Device.idFor(config.id, externalId), name: name, kind: kind, integrationId: config.id, externalId: externalId,
               capabilities: capabilities, props: obj(props).object ?? [:], state: DeviceState().merging(state))
    }

    public func getJSON(_ url: String, headers: [String: String] = [:]) async throws -> JSON? {
        try decode(url, try await http.request("GET", url, headers: headers))
    }

    public func sendJSON(_ method: String, _ url: String, _ body: JSON?, headers: [String: String] = [:]) async throws -> JSON? {
        let data = body.map { Data($0.text().utf8) }
        return try decode(url, try await http.request(method, url, headers: ["Content-Type": "application/json"].merging(headers) { $1 }, body: data))
    }

    private func decode(_ url: String, _ res: HttpResponse) throws -> JSON? {
        let host = IntegrationDriver.host(of: url)
        if res.status == 401 || res.status == 403 {
            throw IntegrationError("\(host) refused access (HTTP \(res.status)). Check the token or password.")
        }
        if res.status >= 400 { throw IntegrationError("\(host) answered HTTP \(res.status).") }
        if res.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return (try? JSON.parse(res.body)) ?? .string(res.text)
    }

    public static func host(of url: String) -> String {
        let afterScheme = url.components(separatedBy: "://").last ?? url
        return String(afterScheme.split(separator: "/").first ?? "").components(separatedBy: "@").last ?? ""
    }
}

/// Splits a "hosts" setting (one per line or comma separated) into hosts.
public func parseHosts(_ raw: String) -> [String] {
    var out: [String] = []
    for part in raw.split(whereSeparator: { " \n\t,;\r".contains($0) }) {
        var h = String(part)
        for p in ["http://", "https://"] where h.hasPrefix(p) { h.removeFirst(p.count) }
        while h.hasSuffix("/") { h.removeLast() }
        if !h.isEmpty, !out.contains(h) { out.append(h) }
    }
    return out
}

public func query(_ params: [(String, String)]) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+?/ ")
    return params.map { "\($0.0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
        .joined(separator: "&")
}

/// Base for devices that are each reached at their own LAN address (Shelly, Tasmota, WLED, ESPHome).
public class HostListDriver: IntegrationDriver, @unchecked Sendable {
    public var hosts: [String] { parseHosts(config.setting("hosts")) }

    public func probe(_ host: String) async throws -> [Device] { [] }
    public func readHost(_ host: String) async throws -> JSON { .null }
    public func state(_ d: Device, from data: JSON) -> DeviceState? { nil }

    public override func discover() async throws -> [Device] {
        if hosts.isEmpty { throw IntegrationError("Add at least one device address (for example 192.168.1.40).") }
        var out: [Device] = []
        var errors: [String] = []
        for h in hosts {
            do { out += try await probe(h) } catch { errors.append("\(h): \(error)") }
        }
        if out.isEmpty, !errors.isEmpty { throw IntegrationError("Could not reach \(errors.joined(separator: "; "))") }
        return out
    }

    public override func refreshAll(_ devices: [Device]) async -> [String: DeviceState] {
        var cache: [String: JSON?] = [:]
        var out: [String: DeviceState] = [:]
        for d in devices {
            let host = d.prop("host") ?? ""
            if cache[host] == nil { cache[host] = .some(try? await readHost(host)) }
            if let data = cache[host] ?? nil { out[d.id] = d.state.merging(state(d, from: data) ?? DeviceState()) }
            else { out[d.id] = d.state.merging(.unreachable) }
        }
        return out
    }

    public override func refresh(_ d: Device) async throws -> DeviceState? { state(d, from: try await readHost(d.prop("host") ?? "")) }
}
