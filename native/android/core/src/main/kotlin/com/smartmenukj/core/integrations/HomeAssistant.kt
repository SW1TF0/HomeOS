package com.smartmenukj.core.integrations

import com.smartmenukj.core.json.*
import com.smartmenukj.core.model.*
import com.smartmenukj.core.net.Http
import com.smartmenukj.core.util.ColorMath
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlin.math.roundToInt

/**
 * A Home Assistant server (free, self-hosted). Brings in every light, switch, cover, climate, lock, fan, media player,
 * robot vacuum, mower, alarm, valve, camera, scene and useful sensor it knows about, which covers thousands of brands,
 * Matter, Zigbee and Z-Wave included.
 */
class HomeAssistantDriver(config: IntegrationConfig, http: Http) : IntegrationDriver(config, http) {
    val baseUrl: String
        get() {
            var url = config.setting("url")
            if (url.isEmpty()) return url
            if (!url.startsWith("http")) url = "http://$url"
            return url.trimEnd('/')
        }

    private val headers get() = mapOf("Authorization" to "Bearer ${config.setting("token")}")

    private suspend fun states(): List<JsonObject> {
        if (baseUrl.isEmpty() || config.setting("token").isEmpty()) {
            throw IntegrationException("Enter the server address and a long-lived access token (Profile > Security in Home Assistant).")
        }
        val res = getJson("$baseUrl/api/states", headers) as? JsonArray ?: throw IntegrationException("Unexpected reply from Home Assistant.")
        return res.mapNotNull { it.asObj() }
    }

    override suspend fun discover(): List<Device> {
        val all = states()
        // A robot's battery shows on the robot, not as a sensor of its own.
        val robotBatteries = all.filter { domain(it) in setOf("vacuum", "lawn_mower") }
            .mapNotNull { batterySensorOf(it.string("entity_id")!!, all)?.string("entity_id") }.toSet()
        return all.mapNotNull { e ->
            val kind = kindFor(e) ?: return@mapNotNull null
            val id = e.string("entity_id")!!
            if (id in robotBatteries) return@mapNotNull null
            makeDevice(id, attrs(e).string("friendly_name") ?: id, kind, capabilitiesFor(e, kind), propsFor(e),
                withBattery(id, parseState(e), all))
        }
    }

    override suspend fun refreshAll(devices: List<Device>): Map<String, DeviceState> = try {
        val all = states()
        val byId = all.associateBy { it.string("entity_id") }
        devices.associate { d ->
            val e = byId[d.externalId]
            d.id to d.state.merge(if (e == null) DeviceState.unreachable else withBattery(d.externalId, parseState(e), all))
        }
    } catch (e: Exception) {
        devices.associate { it.id to it.state.merge(DeviceState.unreachable) }
    }

    override suspend fun refresh(device: Device): DeviceState? =
        getJson("$baseUrl/api/states/${device.externalId}", headers).asObj()?.let(::parseState)

    private suspend fun call(domain: String, service: String, data: Map<String, Any?>) {
        sendJson("POST", "$baseUrl/api/services/$domain/$service", data.filterValues { it != null }, headers)
    }

    override suspend fun send(device: Device, command: DeviceCommand): DeviceState? {
        val c = command
        val id = device.externalId
        val domain = id.substringBefore('.')
        val target = mapOf("entity_id" to id)
        val action = c.action
        when (domain) {
            "light" -> if (c.on == false) call("light", "turn_off", target) else call("light", "turn_on", target + mapOf(
                "brightness_pct" to c.brightness?.let { (it * 100).roundToInt() },
                "color_temp_kelvin" to c.colorTempK,
                "rgb_color" to c.color?.let { ColorMath.channels(it).toList() },
            ))
            "cover" -> when {
                c.position != null -> call("cover", "set_cover_position", target + ("position" to (c.position * 100).roundToInt()))
                c.on != null -> call("cover", if (c.on) "open_cover" else "close_cover", target)
            }
            "climate", "water_heater" -> {
                // Switch on first: turning on picks a mode by itself, which the chosen mode then replaces.
                if (c.on == true) call(domain, "turn_on", target)
                c.mode?.let {
                    if (domain == "climate") call(domain, "set_hvac_mode", target + ("hvac_mode" to it))
                    else call(domain, "set_operation_mode", target + ("operation_mode" to it))
                }
                c.targetTemp?.let { call(domain, "set_temperature", target + ("temperature" to it)) }
                if (c.on == false) call(domain, "turn_off", target)
            }
            "humidifier" -> {
                if (c.on == true) call(domain, "turn_on", target)
                c.mode?.let { call(domain, "set_mode", target + ("mode" to it)) }
                c.targetHumidity?.let { call(domain, "set_humidity", target + ("humidity" to it.roundToInt())) }
                if (c.on == false) call(domain, "turn_off", target)
            }
            "fan" -> if (c.on == false) call("fan", "turn_off", target) else {
                c.speed?.let { call("fan", "set_percentage", target + ("percentage" to (it * 100).roundToInt().coerceIn(1, 100))) }
                c.mode?.let { call("fan", "set_preset_mode", target + ("preset_mode" to it)) }
                if (c.on == true && c.speed == null && c.mode == null) call("fan", "turn_on", target)
            }
            "lock" -> c.locked?.let { call("lock", if (it) "lock" else "unlock", target) }
            "media_player" -> {
                c.on?.let { call(domain, if (it) "turn_on" else "turn_off", target) }
                c.volume?.let { call(domain, "volume_set", target + ("volume_level" to it)) }
                c.muted?.let { call(domain, "volume_mute", target + ("is_volume_muted" to it)) }
                c.mode?.let { call(domain, "select_source", target + ("source" to it)) }
                if (c.key == RemoteKey.mute) {
                    // The screen has already flipped it, so this is the wanted state.
                    call(domain, "volume_mute", target + ("is_volume_muted" to (device.state.muted ?: true)))
                } else if (c.key != null) {
                    val service = when (c.key) {
                        RemoteKey.power -> "toggle"
                        RemoteKey.volumeUp -> "volume_up"
                        RemoteKey.volumeDown -> "volume_down"
                        RemoteKey.playPause -> "media_play_pause"
                        RemoteKey.stop -> "media_stop"
                        RemoteKey.rewind -> "media_previous_track"
                        RemoteKey.forward -> "media_next_track"
                        else -> null
                    }
                    service?.let { call(domain, it, target) }
                }
            }
            "vacuum" -> {
                c.mode?.let { call(domain, "set_fan_speed", target + ("fan_speed" to it)) }
                when (action) {
                    DeviceAction.start -> "start"
                    DeviceAction.pause -> "pause"
                    DeviceAction.stop -> "stop"
                    DeviceAction.dock -> "return_to_base"
                    DeviceAction.locate -> "locate"
                    else -> null
                }?.let { call(domain, it, target) }
            }
            "lawn_mower" -> when (action) {
                DeviceAction.start -> "start_mowing"
                DeviceAction.pause -> "pause"
                DeviceAction.dock -> "dock"
                else -> null
            }?.let { call(domain, it, target) }
            "alarm_control_panel" -> when (action) {
                DeviceAction.armHome -> "alarm_arm_home"
                DeviceAction.armAway -> "alarm_arm_away"
                DeviceAction.armNight -> "alarm_arm_night"
                DeviceAction.armVacation -> "alarm_arm_vacation"
                DeviceAction.disarm -> "alarm_disarm"
                else -> null
            }?.let { call(domain, it, target + ("code" to c.code)) }
            "valve" -> c.on?.let { call(domain, if (it) "open_valve" else "close_valve", target) }
            "scene", "script" -> if (action == DeviceAction.press) call(domain, "turn_on", target)
            "input_button" -> if (action == DeviceAction.press) call(domain, "press", target)
            else -> c.on?.let { call(domain, if (it) "turn_on" else "turn_off", target) }
        }
        return null
    }

    companion object {
        private val sensorClasses = setOf(
            "temperature", "humidity", "motion", "occupancy", "presence", "door", "window", "opening", "garage_door",
            "power", "energy", "battery", "illuminance", "moisture", "smoke", "gas", "carbon_monoxide", "carbon_dioxide",
            "co2", "pm25", "pm10", "pm1", "volatile_organic_compounds", "aqi", "pressure", "atmospheric_pressure",
            "vibration", "sound",
        )

        /** Words in the name of a fan that is really an air purifier. */
        private val purifierWords = listOf("purif", "air clean", "luftrein", "пречиств", "очист", "depurat", "oczyszcz")

        fun domain(e: JsonObject) = e.string("entity_id")!!.substringBefore('.')
        private fun attrs(e: JsonObject) = e.obj("attributes") ?: JsonObject(emptyMap())
        private fun features(a: JsonObject) = a.int("supported_features") ?: 0
        private fun strings(a: JsonObject, key: String) = a.list(key)?.map { it.text() } ?: emptyList()

        fun kindFor(e: JsonObject): DeviceKind? {
            val id = e.string("entity_id")!!
            val a = attrs(e)
            return when (domain(e)) {
                "light" -> DeviceKind.light
                "switch" -> if (a.string("device_class") == "outlet") DeviceKind.outlet else DeviceKind.toggle
                "input_boolean" -> DeviceKind.toggle
                "fan" -> if (purifierWords.any { "$id ${a.string("friendly_name") ?: ""}".lowercase().contains(it) }) {
                    DeviceKind.purifier
                } else DeviceKind.fan
                "cover" -> if (a.string("device_class") in setOf("garage", "gate")) DeviceKind.garage else DeviceKind.cover
                "climate", "water_heater" -> DeviceKind.climate
                "humidifier" -> DeviceKind.humidifier
                "lock" -> DeviceKind.lock
                "media_player" -> DeviceKind.media
                "camera" -> DeviceKind.camera
                "vacuum" -> DeviceKind.vacuum
                "lawn_mower" -> DeviceKind.mower
                "alarm_control_panel" -> DeviceKind.alarm
                "valve" -> DeviceKind.valve
                "siren" -> DeviceKind.siren
                // Device "button" entities are left out: most restart or reset something.
                "scene", "script", "input_button" -> DeviceKind.button
                "sensor", "binary_sensor" -> if (a.string("device_class") in sensorClasses) DeviceKind.sensor else null
                else -> null
            }
        }

        private fun climateModes(a: JsonObject) = strings(a, "hvac_modes").filter { it != "off" }

        /** Remote keys a media player has, by its supported features. */
        private fun mediaKeys(f: Int) = buildList {
            if (f and (4 or 1024) != 0) addAll(listOf("volumeUp", "volumeDown"))
            if (f and 8 != 0) add("mute")
            if (f and (1 or 16384) != 0) add("playPause")
            if (f and 4096 != 0) add("stop")
            if (f and 16 != 0) add("rewind")
            if (f and 32 != 0) add("forward")
        }

        fun capabilitiesFor(e: JsonObject, kind: DeviceKind): Set<Capability> {
            val a = attrs(e)
            val f = features(a)
            fun s(vararg c: Capability?) = c.filterNotNull().toSet()
            return when (domain(e)) {
                "light" -> {
                    val modes = strings(a, "supported_color_modes").toSet()
                    s(Capability.onOff,
                        if (modes.any { it != "onoff" }) Capability.brightness else null,
                        if ("color_temp" in modes) Capability.colorTemp else null,
                        if (modes.any { it in setOf("hs", "xy", "rgb", "rgbw", "rgbww") }) Capability.color else null)
                }
                "cover" -> s(Capability.position, if (f and 4 == 0) Capability.onOff else null)
                "fan" -> s(Capability.onOff, if (f and 1 != 0) Capability.speed else null,
                    if (f and 8 != 0 && strings(a, "preset_modes").isNotEmpty()) Capability.mode else null)
                "humidifier" -> s(Capability.onOff, Capability.humidity,
                    if (strings(a, "available_modes").isNotEmpty()) Capability.mode else null)
                "climate" -> s(Capability.onOff, Capability.targetTemp, if (climateModes(a).size > 1) Capability.mode else null)
                "water_heater" -> s(if (f and 8 != 0) Capability.onOff else null, Capability.targetTemp,
                    if (f and 2 != 0 && strings(a, "operation_list").isNotEmpty()) Capability.mode else null)
                "vacuum" -> s(Capability.run, if (f and 16 != 0) Capability.dock else null,
                    if (f and 512 != 0) Capability.locate else null,
                    if (f and 32 != 0 && strings(a, "fan_speed_list").isNotEmpty()) Capability.mode else null)
                "lawn_mower" -> s(Capability.run, if (f and 4 != 0) Capability.dock else null)
                "media_player" -> s(if (f and (128 or 256) != 0) Capability.onOff else null,
                    if (f and 4 != 0) Capability.volume else null,
                    if (mediaKeys(f).isNotEmpty()) Capability.remote else null,
                    if (f and 2048 != 0 && strings(a, "source_list").isNotEmpty()) Capability.mode else null)
                "alarm_control_panel" -> s(Capability.alarm)
                "valve", "siren" -> s(Capability.onOff)
                "camera" -> s(Capability.snapshot)
                "scene", "script", "input_button" -> s(Capability.press)
                else -> defaultCapabilities(kind)
            }
        }

        /** What the app needs to know besides the state: modes to pick from, how an alarm is armed... */
        fun propsFor(e: JsonObject): Map<String, Any?> {
            val domain = domain(e)
            val a = attrs(e)
            val f = features(a)
            val arms = buildList {
                if (f and 1 != 0) add("home")
                if (f and 2 != 0) add("away")
                if (f and 4 != 0) add("night")
                if (f and 32 != 0) add("vacation")
            }
            val modes = when (domain) {
                "fan" -> strings(a, "preset_modes")
                "humidifier" -> strings(a, "available_modes")
                "climate" -> climateModes(a)
                "water_heater" -> strings(a, "operation_list").filter { it != "off" }
                "vacuum" -> strings(a, "fan_speed_list")
                "media_player" -> strings(a, "source_list")
                else -> emptyList()
            }
            val out = mutableMapOf<String, Any?>("domain" to domain)
            if (modes.isNotEmpty()) out["modes"] = modes
            if (domain == "humidifier") {
                out["minHumidity"] = a.double("min_humidity") ?: 30.0
                out["maxHumidity"] = a.double("max_humidity") ?: 80.0
            }
            if (domain == "vacuum" && f and 8 == 0) out["noStop"] = true
            if (domain == "media_player") out["keys"] = mediaKeys(f)
            if (domain == "alarm_control_panel") {
                if (arms.isNotEmpty()) out["arms"] = arms
                out["codeFormat"] = a.string("code_format")
                out["codeArmRequired"] = a.bool("code_arm_required") ?: true
            }
            return out
        }

        fun parseState(e: JsonObject): DeviceState {
            val id = e.string("entity_id")!!
            val domain = id.substringBefore('.')
            val state = e["state"].text()
            val a = attrs(e)
            val reachable = state != "unavailable"
            return when (domain) {
                "sensor", "binary_sensor" -> {
                    val label = a.string("friendly_name") ?: id
                    val unit = a.string("unit_of_measurement")
                    val value = if (domain == "binary_sensor") (if (state == "on") "Detected" else "Clear") else state
                    DeviceState(readings = mapOf(label to if (unit == null) value else "$value $unit"), reachable = reachable)
                }
                "cover" -> {
                    val open = state == "open" || state == "opening"
                    DeviceState(position = a.double("current_position")?.let { it / 100 } ?: if (open) 1.0 else 0.0,
                        on = open, reachable = reachable)
                }
                "climate", "water_heater" -> DeviceState(
                    on = state != "off",
                    targetTemp = a.double("temperature"),
                    currentTemp = a.double("current_temperature"),
                    mode = if (state == "off" || !reachable) null
                    else if (domain == "water_heater") a.string("operation_mode") ?: state else state,
                    reachable = reachable,
                )
                "humidifier" -> DeviceState(on = state == "on", targetHumidity = a.double("humidity"),
                    currentHumidity = a.double("current_humidity"), mode = a.string("mode"), reachable = reachable)
                "fan" -> {
                    val pct = a.double("percentage")
                    DeviceState(on = state == "on", speed = if (state == "on" && pct != null && pct > 0) pct / 100 else null,
                        mode = a.string("preset_mode") ?: "", reachable = reachable)
                }
                "lock" -> DeviceState(locked = state == "locked", reachable = reachable)
                "media_player" -> {
                    val title = a.string("media_title")
                    val artist = a.string("media_artist")
                    val on = state !in setOf("off", "standby", "unavailable")
                    DeviceState(on = on, volume = a.double("volume_level"), muted = a.bool("is_volume_muted"),
                        mode = a.string("source"),
                        readings = mapOf("Playing" to if (!on || title == null) "Nothing" else if (artist == null) title else "$artist - $title"),
                        reachable = reachable)
                }
                "vacuum" -> {
                    val activity = when (state) {
                        "cleaning" -> Activity.RUNNING
                        "paused" -> Activity.PAUSED
                        "returning" -> Activity.RETURNING
                        "docked" -> Activity.DOCKED
                        "idle" -> Activity.IDLE
                        "error" -> Activity.ERROR
                        else -> null
                    }
                    val status = a.string("status")
                    DeviceState(activity = activity, battery = a.double("battery_level")?.coerceIn(0.0, 100.0)?.let { it / 100 },
                        mode = a.string("fan_speed"),
                        readings = mapOf("Error" to if (activity == Activity.ERROR && status != null) status else ""),
                        reachable = reachable)
                }
                "lawn_mower" -> DeviceState(activity = when (state) {
                    "mowing" -> Activity.RUNNING
                    "paused" -> Activity.PAUSED
                    "returning" -> Activity.RETURNING
                    "docked" -> Activity.DOCKED
                    "error" -> Activity.ERROR
                    else -> null
                }, reachable = reachable)
                "alarm_control_panel" -> DeviceState(activity = if (reachable && state != "unknown") state else null, reachable = reachable)
                "valve" -> DeviceState(on = state == "open" || state == "opening", reachable = reachable)
                "scene", "script", "input_button", "camera" -> DeviceState(reachable = reachable)
                "light" -> {
                    val rgb = a.list("rgb_color")
                    val mode = a.string("color_mode")
                    DeviceState(
                        on = state == "on",
                        brightness = a.double("brightness")?.let { it / 255 },
                        colorTempK = if (mode == "color_temp") a.int("color_temp_kelvin") else null,
                        color = if (mode != "color_temp" && rgb != null && rgb.size == 3) {
                            ColorMath.rgb(rgb[0].number()!!.toInt(), rgb[1].number()!!.toInt(), rgb[2].number()!!.toInt())
                        } else null,
                        reachable = reachable,
                    )
                }
                else -> DeviceState(on = state == "on", reachable = reachable)
            }
        }

        /** The battery sensor of a robot (`sensor.<robot>_battery`). */
        private fun batterySensorOf(robotId: String, all: List<JsonObject>): JsonObject? {
            val obj = robotId.substringAfter('.')
            return all.firstOrNull { it.string("entity_id")!!.startsWith("sensor.$obj") && attrs(it).string("device_class") == "battery" }
        }

        private fun withBattery(id: String, s: DeviceState, all: List<JsonObject>): DeviceState {
            if (s.battery != null || !(id.startsWith("vacuum.") || id.startsWith("lawn_mower."))) return s
            val level = batterySensorOf(id, all)?.get("state").textOrNull()?.toDoubleOrNull() ?: return s
            return s.merge(DeviceState(battery = level.coerceIn(0.0, 100.0) / 100, reachable = s.reachable))
        }
    }
}
