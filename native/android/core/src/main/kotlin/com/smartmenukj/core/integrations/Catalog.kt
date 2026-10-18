package com.smartmenukj.core.integrations

import com.smartmenukj.core.model.IntegrationConfig
import com.smartmenukj.core.net.Http

/** A kind of integration the user can add. */
data class IntegrationSpec(
    val type: String,
    val name: String,
    val tagline: String,
    val description: String,
    /** A key the app turns into an icon. */
    val icon: String,
    val fields: List<SettingField>,
    val create: (IntegrationConfig, Http) -> IntegrationDriver,
    val canPair: Boolean = false,
    /** Whether devices can be made by hand (virtual devices). */
    val manualDevices: Boolean = false,
    /** Whether the app should poll it for state. */
    val polls: Boolean = true,
)

private val hostsField = SettingField("hosts", "Device addresses",
    hint = "One IP or hostname per line, e.g. 192.168.1.40", multiline = true, required = true)

object Catalog {
    val specs: List<IntegrationSpec> = listOf(
        IntegrationSpec(
            type = "homeassistant",
            name = "Home Assistant",
            tagline = "Thousands of brands, Matter, Zigbee, Z-Wave",
            description = "Connect a free, self-hosted Home Assistant server and control everything it knows: Matter and " +
                "Thread devices, Zigbee, Z-Wave, Google Nest, Sonos, IKEA, Xiaomi, Tuya, TP-Link, thermostats, locks and " +
                "more. Create a long-lived access token in Home Assistant under Profile > Security.",
            icon = "hub",
            fields = listOf(
                SettingField("url", "Server address", hint = "http://homeassistant.local:8123", required = true),
                SettingField("token", "Long-lived access token", secret = true, required = true),
            ),
            create = ::HomeAssistantDriver,
        ),
        IntegrationSpec(
            type = "hue",
            name = "Philips Hue",
            tagline = "Hue bridge, local, no account",
            description = "Controls lights and plugs on a Hue bridge over your home network. Enter the bridge address (or " +
                "use Scan network), press the round link button on the bridge, then tap Pair.",
            icon = "bulb",
            fields = listOf(
                SettingField("host", "Bridge address", hint = "192.168.1.20", required = true),
                SettingField("username", "App key", hint = "Filled in by Pair", secret = true),
            ),
            create = ::HueDriver,
            canPair = true,
        ),
        IntegrationSpec(
            type = "shelly",
            name = "Shelly",
            tagline = "Relays, plugs, dimmers, shutters",
            description = "Shelly Gen1, Plus, Pro, Gen3 and Gen4 devices over their local HTTP API. No Shelly cloud needed.",
            icon = "plug",
            fields = listOf(hostsField),
            create = ::ShellyDriver,
        ),
        IntegrationSpec(
            type = "tasmota",
            name = "Tasmota",
            tagline = "Open firmware plugs, bulbs, sensors",
            description = "Thousands of plugs, bulbs and switches flashed with the open Tasmota firmware, over HTTP.",
            icon = "power",
            fields = listOf(hostsField, SettingField("password", "Web password (if set)", secret = true)),
            create = ::TasmotaDriver,
        ),
        IntegrationSpec(
            type = "wled",
            name = "WLED",
            tagline = "LED strips",
            description = "LED strips and lamps running the open WLED firmware.",
            icon = "strip",
            fields = listOf(hostsField),
            create = ::WledDriver,
        ),
        IntegrationSpec(
            type = "esphome",
            name = "ESPHome",
            tagline = "DIY boards with web_server",
            description = "ESPHome devices with the `web_server:` component enabled. Lights, switches, fans, covers, locks and sensors.",
            icon = "chip",
            fields = listOf(hostsField),
            create = ::EspHomeDriver,
        ),
        IntegrationSpec(
            type = "demo",
            name = "Virtual devices",
            tagline = "Try the app, plan before you buy",
            description = "Devices that live only in SmartMenuKJ. Use them to try the app or to plan a room before the hardware arrives.",
            icon = "virtual",
            fields = emptyList(),
            create = ::DemoDriver,
            manualDevices = true,
            polls = false,
        ),
    )

    fun spec(type: String): IntegrationSpec? = specs.firstOrNull { it.type == type }

    /** Names of connections the Flutter app has that this app cannot drive yet; their devices are kept as they are. */
    val laterNames = mapOf(
        "lan" to "Network devices (TVs, Kasa, Yeelight, WeMo)",
        "matter" to "Matter",
        "mqtt" to "MQTT & Zigbee2MQTT",
        "camera" to "Cameras",
    )
}
