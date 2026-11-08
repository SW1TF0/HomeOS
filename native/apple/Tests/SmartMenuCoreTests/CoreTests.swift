import XCTest
@testable import SmartMenuCore

/// Answers requests from a table of "METHOD url" to (status, body), and remembers what was asked.
final class FakeHttp: Http, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: (Int, String)] = [:]
    private(set) var calls: [String] = []

    func on(_ method: String, _ url: String, _ body: String, status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        routes["\(method) \(url)"] = (status, body)
    }

    func request(_ method: String, _ url: String, headers: [String: String], body: Data?, timeout: TimeInterval) async throws -> HttpResponse {
        lock.lock(); defer { lock.unlock() }
        calls.append("\(method) \(url)" + (body.flatMap { String(data: $0, encoding: .utf8) }.map { " " + $0 } ?? ""))
        let r = routes["\(method) \(url)"] ?? (404, "")
        return HttpResponse(status: r.0, body: Data(r.1.utf8))
    }

    func readLines(_ url: String, headers: [String: String], for seconds: TimeInterval, onLine: @escaping @Sendable (String) -> Void) async throws -> Int {
        let r: (Int, String)? = { lock.lock(); defer { lock.unlock() }; calls.append("STREAM \(url)"); return routes["STREAM \(url)"] }()
        guard let r else { return 404 }
        r.1.split(separator: "\n", omittingEmptySubsequences: false).forEach { onLine(String($0)) }
        return r.0
    }
}

final class ModelTests: XCTestCase {
    func testSampleHomeRoundTrips() throws {
        let home = Seed.sampleHome()
        let back = HomeData(json: try JSON.parse(home.json().text()))
        XCTAssertEqual(back, home)
        XCTAssertTrue(Seed.isSample(back))
    }

    func testReadsTheFlutterShape() throws {
        let text = """
        {"app":"SmartMenuKJ","version":1,"themeMode":"light","floors":[{"id":"f","name":"Ground"}],
         "rooms":[{"id":"r","floorId":"f","name":"Living","x":1,"y":1,"width":5,"height":4}],
         "devices":[{"id":"hue-1::3","name":"Lamp","kind":"light","integrationId":"hue-1","externalId":"3",
           "capabilities":["onOff","brightness"],"props":{},"roomId":"r","floorId":"f","mapPos":[2,2],"favorite":true,
           "state":{"on":true,"brightness":0.5,"reachable":true}}],
         "integrations":[{"id":"hue-1","type":"hue","name":"Hue","settings":{"host":"10.0.0.2"},"enabled":true}],
         "scenes":[{"id":"s","name":"Night","icon":"night","actions":[{"deviceId":"hue-1::3","on":false}],
           "schedule":{"hour":22,"minute":30,"days":[1,2,3]}}],
         "automations":[{"id":"a"}]}
        """
        let d = HomeData(json: try JSON.parse(text))
        XCTAssertEqual(d.themeMode, "light")
        XCTAssertEqual(d.devices.first?.state.brightness, 0.5)
        XCTAssertEqual(d.devices.first?.mapPos, MapPos(2, 2))
        XCTAssertEqual(d.scenes.first?.schedule?.time, "22:30")
        XCTAssertEqual(d.scenes.first?.actions.first?.isOff, true)
        XCTAssertEqual(d.automations.count, 1, "automations are kept for the other app")
    }

    func testDescribe() {
        var lamp = Seed.sampleHome().devices.first { $0.name == "Ceiling light" }!
        XCTAssertEqual(Describe.state(lamp), "On · 72%")
        lamp.state.on = false
        XCTAssertEqual(Describe.state(lamp), "Off")
        XCTAssertEqual(Describe.mode("fan_only"), "Fan")
    }

    func testColours() {
        let xy = ColorMath.rgbToXy(0xFF0000)
        XCTAssertEqual(xy[0], 0.64, accuracy: 0.01)
        XCTAssertEqual(ColorMath.hsvToRgb(120, 1, 1), 0x00FF00)
        XCTAssertEqual(ColorMath.rgbToHsv(0x0000FF).h, 240, accuracy: 0.5)
        XCTAssertEqual(ColorMath.parseHex("#ff8800"), 0xFF8800)
    }
}

final class DriverTests: XCTestCase {
    func testHueFindsAndSwitchesLights() async throws {
        let http = FakeHttp()
        http.on("GET", "http://10.0.0.2/api/key/lights", """
        {"1":{"name":"Desk","type":"Extended color light","modelid":"LCT015",
              "state":{"on":true,"bri":254,"ct":366,"xy":[0.4,0.4],"colormode":"ct","reachable":true}}}
        """)
        http.on("PUT", "http://10.0.0.2/api/key/lights/1/state", #"[{"success":{}}]"#)
        let hue = HueDriver(config: IntegrationConfig(id: "hue", type: "hue", name: "Hue", settings: ["host": "10.0.0.2", "username": "key"]), http: http)
        let found = try await hue.discover()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].state.brightness, 1)
        XCTAssertEqual(found[0].state.colorTempK, 2732)
        XCTAssertTrue(found[0].has(.color))
        _ = try await hue.send(found[0], DeviceCommand(brightness: 0.5))
        XCTAssertTrue(http.calls.last!.contains(#""bri":128"#), http.calls.last!)
    }

    func testShellyGen2() async throws {
        let http = FakeHttp()
        http.on("GET", "http://10.0.0.5/shelly", #"{"gen":2,"name":"Plug"}"#)
        http.on("GET", "http://10.0.0.5/rpc/Shelly.GetStatus", #"{"switch:0":{"output":true,"apower":12.5},"temperature:0":{"tC":21.5}}"#)
        let shelly = ShellyDriver(config: IntegrationConfig(id: "s", type: "shelly", name: "Shelly", settings: ["hosts": "10.0.0.5"]), http: http)
        let found = try await shelly.discover()
        XCTAssertEqual(found.map(\.kind), [.outlet, .sensor])
        XCTAssertEqual(found[0].state.on, true)
        XCTAssertEqual(found[0].state.readings["Power"], "12.5 W")
        XCTAssertEqual(found[1].state.readings["Temperature"], "21.5 °C")
    }

    func testTasmotaAndEspHome() async throws {
        let http = FakeHttp()
        http.on("GET", "http://10.0.0.7/cm?cmnd=Status%200", #"{"Status":{"DeviceName":"Strip","FriendlyName":["Strip"]},"StatusSTS":{"POWER":"ON","Dimmer":40}}"#)
        let tas = TasmotaDriver(config: IntegrationConfig(id: "t", type: "tasmota", name: "T", settings: ["hosts": "10.0.0.7"]), http: http)
        let t = try await tas.discover()
        XCTAssertEqual(t.first?.state.brightness, 0.4)

        http.on("STREAM", "http://10.0.0.8/events", """
        event: state
        data: {"id":"light-desk","name":"Desk","state":"ON","brightness":255}
        event: state
        data: {"id":"sensor-temp","name":"Temp","state":"20.1 °C","value":20.1}
        """)
        let esp = EspHomeDriver(config: IntegrationConfig(id: "e", type: "esphome", name: "E", settings: ["hosts": "10.0.0.8"]), http: http)
        let e = try await esp.discover()
        XCTAssertEqual(e.first { $0.kind == .light }?.state.brightness, 1)
        XCTAssertEqual(e.first { $0.kind == .sensor }?.state.readings["Temp"], "20.1 °C")
    }

    func testHomeAssistantKinds() {
        let vac: JSON = ["entity_id": "vacuum.robo", "state": "cleaning",
                         "attributes": ["friendly_name": "Robo", "supported_features": 16440, "fan_speed_list": ["low", "max"], "battery_level": 80]]
        XCTAssertEqual(HomeAssistantDriver.kind(for: vac), .vacuum)
        let caps = HomeAssistantDriver.capabilities(for: vac, .vacuum)
        XCTAssertEqual(caps, [.run, .dock, .mode])
        let s = HomeAssistantDriver.parseState(vac)
        XCTAssertEqual(s.activity, Activity.running)
        XCTAssertEqual(s.battery, 0.8)
    }
}

@MainActor
final class StoreTests: XCTestCase {
    private var n = 0
    private func store(_ http: FakeHttp = FakeHttp(), _ storage: MemoryStorage = MemoryStorage()) -> HomeStore {
        let s = HomeStore(storage: storage, http: http, saveDelay: 0, newId: { [unowned self] in n += 1; return "id\(n)" })
        s.load()
        return s
    }

    func testStartsWithTheSampleHome() {
        let s = store()
        XCTAssertTrue(Seed.isSample(s.data))
        XCTAssertEqual(s.homes.count, 1)
    }

    func testVirtualDevicesSwitch() async {
        let s = store()
        let lamp = s.data.devices.first { $0.name == "Bedside lamp" }!
        let ok = await s.send(lamp.id, DeviceCommand(on: true, brightness: 0.6))
        XCTAssertTrue(ok)
        XCTAssertEqual(s.data.device(lamp.id)?.state.brightness, 0.6)
    }

    func testFailedCommandsGoBack() async {
        let http = FakeHttp()
        let s = store(http)
        var messages: [String] = []
        s.onMessage = { messages.append($0) }
        let cfg = s.addIntegration("shelly", settings: ["hosts": "10.0.0.5"])!
        http.on("GET", "http://10.0.0.5/shelly", #"{"gen":2,"name":"Plug"}"#)
        http.on("GET", "http://10.0.0.5/rpc/Shelly.GetStatus", #"{"switch:0":{"output":false}}"#)
        let added = await s.sync(cfg.id)
        XCTAssertEqual(added, 1)
        let plug = s.data.devices.first { $0.integrationId == cfg.id }!
        XCTAssertNil(plug.roomId)
        let ok = await s.send(plug.id, DeviceCommand(on: true))
        XCTAssertFalse(ok)
        XCTAssertEqual(s.data.device(plug.id)?.state.on, false)
        XCTAssertTrue(messages.last?.hasPrefix("Plug:") == true)
        s.setRoom(plug.id, "room-kitchen")
        let again = await s.sync(cfg.id)
        XCTAssertEqual(again, 0)
        XCTAssertEqual(s.data.device(plug.id)?.roomId, "room-kitchen")
        s.removeIntegration(cfg.id)
        XCTAssertNil(s.data.device(plug.id))
    }

    func testRoomsMoveWithTheirDevicesAndUndo() {
        let s = store()
        let living = s.data.room("room-living")!
        let ceiling = s.data.devices.first { $0.name == "Ceiling light" }!
        s.setRoomRect(living.id, x: living.x + 2.2, y: living.y, w: living.width, h: living.height)
        XCTAssertEqual(s.data.room(living.id)?.x, 3)
        XCTAssertEqual(s.data.device(ceiling.id)?.mapPos?.x, ceiling.mapPos!.x + 2)
        s.undoLayout()
        XCTAssertEqual(s.data.room(living.id), living)
        XCTAssertEqual(s.data.device(ceiling.id)?.mapPos, ceiling.mapPos)
    }

    func testBackupBringsEveryHomeBack() throws {
        let s = store()
        s.addHome("Cabin")
        let backup = s.exportAll()
        let other = store(FakeHttp(), MemoryStorage())
        let n = try other.importAll(backup)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(other.homes.map(\.name).sorted(), ["Cabin", "My home"])
    }
}
