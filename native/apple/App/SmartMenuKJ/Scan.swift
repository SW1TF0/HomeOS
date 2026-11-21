import Foundation
import Network
import SmartMenuCore

/// Scan network: Bonjour (mDNS), the free Hue discovery service, and a knock on every address of the home Wi-Fi.
@MainActor
final class Scan: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var found: [FoundService] = []
    private let scanner = NetworkScanner(http: URLSessionHttp())

    /// This device's IPv4 address on Wi-Fi or Ethernet, or nil when it has none.
    nonisolated static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var best: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254") { if name == "en0" { return ip }; best = best ?? ip }
            }
        }
        return best
    }

    func run(skip: @escaping (FoundService) -> Bool) {
        guard !running else { return }
        running = true
        found = []
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for f in await self.scanner.hueCloud() { await self.add(f, skip) } }
                group.addTask { await self.bonjour(skip) }
                if let ip = Scan.localAddress() {
                    group.addTask { await self.sweep(NetworkScanner.subnet(of: ip), skip) }
                }
            }
            running = false
        }
    }

    private func add(_ f: FoundService, _ skip: (FoundService) -> Bool) {
        if !skip(f) && !found.contains(where: { $0.id == f.id }) { found.append(f) }
    }

    func remove(_ f: FoundService) { found.removeAll { $0.id == f.id } }

    private nonisolated func sweep(_ hosts: [String], _ skip: @escaping (FoundService) -> Bool) async {
        for batch in stride(from: 0, to: hosts.count, by: 48).map({ Array(hosts[$0..<min($0 + 48, hosts.count)]) }) {
            await withTaskGroup(of: Void.self) { group in
                for h in batch {
                    group.addTask {
                        if await Scan.knock(h, 80), let f = await self.scanner.identify(h) { await self.add(f, skip) }
                        if await Scan.knock(h, 8123), let f = await self.scanner.identifyHomeAssistant(h) { await self.add(f, skip) }
                    }
                }
            }
        }
    }

    /// Whether `host` takes a TCP connection on `port` within a moment.
    nonisolated static func knock(_ host: String, _ port: UInt16) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let once = Once()
            let finish = { (ok: Bool) in
                if once.take() { conn.cancel(); cont.resume(returning: ok) }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                case .waiting: finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { finish(false) }
        }
    }

    private nonisolated func bonjour(_ skip: @escaping (FoundService) -> Bool) async {
        let types = ["_hue._tcp", "_shelly._tcp", "_wled._tcp", "_esphomelib._tcp", "_home-assistant._tcp", "_http._tcp"]
        var browsers: [NWBrowser] = []
        for type in types {
            let b = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            b.browseResultsChangedHandler = { results, _ in
                for r in results {
                    guard case let .service(name, _, _, _) = r.endpoint,
                          let integration = NetworkScanner.type(forService: type, name: name) else { continue }
                    Task { if let host = await Scan.resolve(r.endpoint) { await self.add(FoundService(name: name, host: host.0, port: host.1, integrationType: integration), skip) } }
                }
            }
            b.start(queue: .global())
            browsers.append(b)
        }
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        for b in browsers { b.cancel() }
    }

    /// The IPv4 address and port behind a Bonjour service.
    nonisolated static func resolve(_ endpoint: NWEndpoint) async -> (String, Int)? {
        await withCheckedContinuation { (cont: CheckedContinuation<(String, Int)?, Never>) in
            let params = NWParameters.tcp
            if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
            let conn = NWConnection(to: endpoint, using: params)
            let once = Once()
            let finish = { (r: (String, Int)?) in
                if once.take() { conn.cancel(); cont.resume(returning: r) }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint {
                        var h = "\(host)"
                        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                        finish((h, Int(port.rawValue)))
                    } else { finish(nil) }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
    }
}

/// Lets exactly one caller through.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
