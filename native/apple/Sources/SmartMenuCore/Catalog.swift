import Foundation

/// A kind of integration the user can add.
public struct IntegrationSpec: Sendable {
    public var type: String
    public var name: String
    public var tagline: String
    public var description: String
    /// A key the app turns into an icon.
    public var icon: String
    public var fields: [SettingField]
    public var driver: IntegrationDriver.Type
    public var canPair = false
    /// Whether devices can be made by hand (virtual devices).
    public var manualDevices = false
    /// Whether the app should poll it for state.
    public var polls = true

    public func create(_ config: IntegrationConfig, _ http: Http) -> IntegrationDriver { driver.init(config: config, http: http) }
}

private let hostsField = SettingField("hosts", "Device addresses", hint: "One IP or hostname per line, e.g. 192.168.1.40",
                                      multiline: true, required: true)

public enum Catalog {
    public static let specs: [IntegrationSpec] = [
        IntegrationSpec(
            type: "homeassistant", name: "Home Assistant", tagline: "Thousands of brands, Matter, Zigbee, Z-Wave",
            description: "Connect a free, self-hosted Home Assistant server and control everything it knows: Matter and "
                + "Thread devices, Zigbee, Z-Wave, Google Nest, Sonos, IKEA, Xiaomi, Tuya, TP-Link, thermostats, locks and "
                + "more. Create a long-lived access token in Home Assistant under Profile > Security.",
            icon: "hub",
            fields: [SettingField("url", "Server address", hint: "http://homeassistant.local:8123", required: true),
                     SettingField("token", "Long-lived access token", secret: true, required: true)],
            driver: HomeAssistantDriver.self),
        IntegrationSpec(
            type: "hue", name: "Philips Hue", tagline: "Hue bridge, local, no account",
            description: "Controls lights and plugs on a Hue bridge over your home network. Enter the bridge address (or "
                + "use Scan network), press the round link button on the bridge, then tap Pair.",
            icon: "bulb",
            fields: [SettingField("host", "Bridge address", hint: "192.168.1.20", required: true),
                     SettingField("username", "App key", hint: "Filled in by Pair", secret: true)],
            driver: HueDriver.self, canPair: true),
        IntegrationSpec(
            type: "shelly", name: "Shelly", tagline: "Relays, plugs, dimmers, shutters",
            description: "Shelly Gen1, Plus, Pro, Gen3 and Gen4 devices over their local HTTP API. No Shelly cloud needed.",
            icon: "plug", fields: [hostsField], driver: ShellyDriver.self),
        IntegrationSpec(
            type: "tasmota", name: "Tasmota", tagline: "Open firmware plugs, bulbs, sensors",
            description: "Thousands of plugs, bulbs and switches flashed with the open Tasmota firmware, over HTTP.",
            icon: "power", fields: [hostsField, SettingField("password", "Web password (if set)", secret: true)],
            driver: TasmotaDriver.self),
        IntegrationSpec(
            type: "wled", name: "WLED", tagline: "LED strips",
            description: "LED strips and lamps running the open WLED firmware.",
            icon: "strip", fields: [hostsField], driver: WledDriver.self),
        IntegrationSpec(
            type: "esphome", name: "ESPHome", tagline: "DIY boards with web_server",
            description: "ESPHome devices with the `web_server:` component enabled. Lights, switches, fans, covers, locks and sensors.",
            icon: "chip", fields: [hostsField], driver: EspHomeDriver.self),
        IntegrationSpec(
            type: "demo", name: "Virtual devices", tagline: "Try the app, plan before you buy",
            description: "Devices that live only in SmartHomeKJ. Use them to try the app or to plan a room before the hardware arrives.",
            icon: "virtual", fields: [], driver: DemoDriver.self, manualDevices: true, polls: false),
    ]

    public static func spec(_ type: String) -> IntegrationSpec? { specs.first { $0.type == type } }

    /// Names of connections the Flutter app has that this app cannot drive yet; their devices are kept as they are.
    public static let laterNames: [String: String] = [
        "lan": "Network devices (TVs, Kasa, Yeelight, WeMo)",
        "matter": "Matter",
        "mqtt": "MQTT & Zigbee2MQTT",
        "camera": "Cameras",
    ]
}
