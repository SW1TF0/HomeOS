import Foundation

public enum Seed {
    public static let demoId = "demo"
    static let floor = "floor-ground"

    /// A new home: one floor and nothing on it yet.
    public static func emptyHome() -> HomeData { HomeData(floors: [Floor(id: floor, name: "Ground floor")]) }

    /// Whether `d` is still just the sample home: only its example devices, no real connections and no scenes.
    public static func isSample(_ d: HomeData) -> Bool {
        let ids = Set(sampleHome().devices.map(\.id))
        return !d.devices.isEmpty && d.integrations.allSatisfy { $0.type == "demo" } && d.devices.allSatisfy { ids.contains($0.id) }
            && d.scenes.isEmpty
    }

    /// The sample home shown on first launch, so the app is alive before any hardware is connected.
    public static func sampleHome() -> HomeData {
        func room(_ id: String, _ name: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Room {
            Room(id: id, floorId: floor, name: name, x: x, y: y, width: w, height: h)
        }
        func dev(_ id: String, _ name: String, _ kind: DeviceKind, _ roomId: String, _ x: Double, _ y: Double, _ state: DeviceState,
                 favorite: Bool = false, caps: Set<Capability>? = nil, modes: [String]? = nil, arms: [String]? = nil) -> Device {
            Device(id: Device.idFor(demoId, "manual:\(id)"), name: name, kind: kind, integrationId: demoId, externalId: "manual:\(id)",
                   capabilities: caps, props: obj(["modes": modes.map { JSON.array($0.map(JSON.string)) },
                                                   "arms": arms.map { JSON.array($0.map(JSON.string)) }]).object ?? [:],
                   roomId: roomId, floorId: floor, mapPos: MapPos(x, y), favorite: favorite, state: state)
        }
        return HomeData(
            floors: [Floor(id: floor, name: "Ground floor")],
            rooms: [
                room("room-living", "Living", 1, 1, 15, 11),
                room("room-kitchen", "Kitchen", 16, 1, 10, 7),
                room("room-hall", "Hall", 16, 8, 10, 4),
                room("room-bedroom", "Bedroom", 1, 12, 12, 9),
                room("room-bath", "Bath", 13, 12, 6, 9),
                room("room-office", "Office", 19, 12, 7, 9),
            ],
            devices: [
                dev("ceiling", "Ceiling light", .light, "room-living", 8, 5, DeviceState(on: true, brightness: 0.72, colorTempK: 2700), favorite: true),
                dev("lamp", "Floor lamp", .light, "room-living", 3, 9, DeviceState(on: true, brightness: 0.45, color: 0xFF5A36)),
                dev("tv", "TV", .media, "room-living", 13, 9, DeviceState(on: false), favorite: true),
                dev("blinds", "Blinds", .cover, "room-living", 8, 2, DeviceState(position: 0.6)),
                dev("vacuum", "Robot vacuum", .vacuum, "room-living", 4, 4.5,
                    DeviceState(activity: Activity.docked, battery: 1, mode: "Balanced"), favorite: true,
                    modes: ["Quiet", "Balanced", "Turbo", "Max"]),
                dev("thermostat", "Thermostat", .climate, "room-hall", 21, 10,
                    DeviceState(on: true, targetTemp: 21.5, currentTemp: 20.8), favorite: true),
                dev("door", "Front door", .lock, "room-hall", 25, 10, DeviceState(locked: true), favorite: true),
                dev("alarm", "Alarm", .alarm, "room-hall", 18, 10, DeviceState(activity: Activity.disarmed),
                    favorite: true, arms: ["home", "away", "night"]),
                dev("kitchen", "Kitchen lights", .light, "room-kitchen", 21, 4,
                    DeviceState(on: false, brightness: 1, colorTempK: 4000), caps: [.onOff, .brightness, .colorTemp]),
                dev("coffee", "Coffee machine", .outlet, "room-kitchen", 24, 2, DeviceState(on: false), favorite: true),
                dev("bedside", "Bedside lamp", .light, "room-bedroom", 3, 14, DeviceState(on: false, brightness: 0.3, colorTempK: 2200)),
                dev("climate-bed", "Bedroom sensor", .sensor, "room-bedroom", 11, 19,
                    DeviceState(readings: ["Temperature": "19.6 °C", "Humidity": "48 %"])),
                dev("purifier", "Air purifier", .purifier, "room-bedroom", 7, 17,
                    DeviceState(on: false, mode: "Auto", speed: 0.4, readings: ["PM2.5": "6 µg/m³"]), modes: ["Auto", "Sleep", "Turbo"]),
                dev("fan", "Bath fan", .fan, "room-bath", 16, 15, DeviceState(on: false)),
                dev("desk", "Desk lamp", .light, "room-office", 22, 16, DeviceState(on: true, brightness: 0.9, colorTempK: 5000), favorite: true),
            ],
            integrations: [IntegrationConfig(id: demoId, type: "demo", name: "Virtual devices")])
    }
}
