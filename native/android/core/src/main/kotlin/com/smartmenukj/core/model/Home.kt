package com.smartmenukj.core.model

import com.smartmenukj.core.json.*
import kotlinx.serialization.json.*

data class Floor(val id: String, val name: String) {
    fun toJson() = jsonObjectOf("id" to id, "name" to name)

    companion object {
        fun fromJson(j: JsonObject) = Floor(j.string("id")!!, j.string("name") ?: "Floor")
    }
}

/** A room drawn on a floor plan. Coordinates are map units (one grid cell). */
data class Room(
    val id: String,
    val floorId: String,
    val name: String,
    val x: Double,
    val y: Double,
    val width: Double,
    val height: Double,
) {
    val right get() = x + width
    val bottom get() = y + height

    fun contains(p: MapPos) = p.x >= x && p.x < right && p.y >= y && p.y < bottom

    fun toJson() = jsonObjectOf(
        "id" to id, "floorId" to floorId, "name" to name, "x" to x, "y" to y, "width" to width, "height" to height,
    )

    companion object {
        fun fromJson(j: JsonObject) = Room(
            id = j.string("id")!!,
            floorId = j.string("floorId")!!,
            name = j.string("name") ?: "Room",
            x = j.double("x") ?: 0.0,
            y = j.double("y") ?: 0.0,
            width = j.double("width") ?: 4.0,
            height = j.double("height") ?: 4.0,
        )
    }
}

/** One configured connection: a Hue bridge, a Home Assistant server, an MQTT broker... */
data class IntegrationConfig(
    val id: String,
    val type: String,
    val name: String,
    val settings: JsonObject = JsonObject(emptyMap()),
    val enabled: Boolean = true,
) {
    /** A setting as trimmed text, or [fallback] when it is missing or blank. */
    fun setting(key: String, fallback: String = ""): String {
        val v = settings[key]?.textOrNull()?.trim()
        return if (v.isNullOrEmpty()) fallback else v
    }

    fun toJson() = jsonObjectOf("id" to id, "type" to type, "name" to name, "settings" to settings, "enabled" to enabled)

    companion object {
        fun fromJson(j: JsonObject) = IntegrationConfig(
            id = j.string("id")!!,
            type = j.string("type")!!,
            name = j.string("name") ?: j.string("type")!!,
            settings = j.obj("settings") ?: JsonObject(emptyMap()),
            enabled = j.bool("enabled") ?: true,
        )
    }
}

/** One device's part in a scene: the state to put it in. */
data class SceneAction(val deviceId: String, val command: DeviceCommand) {
    /** Whether this turns its device off (or closes, locks, sends home). */
    val isOff: Boolean
        get() = command.on == false || command.locked == true || command.action == DeviceAction.dock ||
            (command.on == null && command.position == 0.0)

    fun toJson(): JsonObject {
        val c = command
        return jsonObjectOf(
            "deviceId" to deviceId, "on" to c.on, "brightness" to c.brightness, "colorTempK" to c.colorTempK,
            "color" to c.color, "position" to c.position, "targetTemp" to c.targetTemp, "locked" to c.locked,
            "volume" to c.volume, "mode" to c.mode, "speed" to c.speed, "targetHumidity" to c.targetHumidity,
            "action" to c.action?.name,
        )
    }

    companion object {
        fun fromJson(j: JsonObject) = SceneAction(
            deviceId = j.string("deviceId")!!,
            command = DeviceCommand(
                on = j.bool("on"),
                brightness = j.double("brightness"),
                colorTempK = j.int("colorTempK"),
                color = j.int("color"),
                position = j.double("position"),
                targetTemp = j.double("targetTemp"),
                locked = j.bool("locked"),
                volume = j.double("volume"),
                mode = j.string("mode"),
                speed = j.double("speed"),
                targetHumidity = j.double("targetHumidity"),
                action = DeviceAction.parse(j.string("action")),
            ),
        )

        private fun isRobot(d: Device) = d.has(Capability.run) && (d.kind == DeviceKind.vacuum || d.kind == DeviceKind.mower)

        /** The command that recreates what [d] is doing now, limited to what it can do. */
        fun capture(d: Device): SceneAction {
            val s = d.state
            val on = if (d.has(Capability.onOff)) s.on else null
            val lit = on != false
            fun <T> If(c: Capability, extra: Boolean, v: T?) = if (d.has(c) && extra) v else null
            return SceneAction(
                d.id,
                DeviceCommand(
                    on = on,
                    brightness = If(Capability.brightness, lit, s.brightness),
                    colorTempK = If(Capability.colorTemp, lit && s.color == null, s.colorTempK),
                    color = If(Capability.color, lit, s.color),
                    position = If(Capability.position, true, s.position),
                    targetTemp = If(Capability.targetTemp, lit, s.targetTemp),
                    locked = If(Capability.lock, true, s.locked),
                    volume = If(Capability.volume, lit, s.volume),
                    mode = If(Capability.mode, lit, s.mode),
                    speed = If(Capability.speed, lit, s.speed),
                    targetHumidity = If(Capability.humidity, lit, s.targetHumidity),
                    action = robotOrAlarmAction(d),
                ),
            )
        }

        /**
         * Turns [d] off or on. Things that do not switch do the nearest thing: a blind closes or opens, a robot goes
         * home or cleans, a lock locks. Null when there is nothing like that (a scene never unlocks a door by "on").
         */
        fun turn(d: Device, on: Boolean): SceneAction? {
            val c = when {
                d.has(Capability.onOff) -> DeviceCommand(on = on)
                d.has(Capability.position) -> DeviceCommand(position = if (on) 1.0 else 0.0)
                d.has(Capability.lock) -> if (on) null else DeviceCommand(locked = true)
                isRobot(d) -> if (on) DeviceCommand(action = DeviceAction.start)
                else if (d.has(Capability.dock)) DeviceCommand(action = DeviceAction.dock) else null
                else -> null
            }
            return c?.let { SceneAction(d.id, it) }
        }

        private fun robotOrAlarmAction(d: Device): DeviceAction? {
            val a = d.state.activity
            if (isRobot(d)) {
                if (a == Activity.RUNNING) return DeviceAction.start
                if (d.has(Capability.dock) && a in setOf(Activity.RETURNING, Activity.DOCKED, Activity.CHARGING)) {
                    return DeviceAction.dock
                }
            }
            if (d.has(Capability.alarm) && d.props.bool("codeArmRequired") != true) {
                return DeviceAction.entries.firstOrNull { it != DeviceAction.disarm && it.alarmState == a }
            }
            return null
        }
    }
}

/** When a scene runs by itself: a time of day on some weekdays (1 = Monday). */
data class SceneSchedule(val hour: Int, val minute: Int, val days: Set<Int> = (1..7).toSet()) {
    val time: String get() = "%02d:%02d".format(hour, minute)

    val daysLabel: String
        get() = when {
            days.size == 7 -> "Every day"
            days == setOf(1, 2, 3, 4, 5) -> "Weekdays"
            days == setOf(6, 7) -> "Weekends"
            else -> days.sorted().joinToString(" ") { listOf("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")[it - 1] }
        }

    fun toJson() = jsonObjectOf("hour" to hour, "minute" to minute, "days" to days.sorted())

    companion object {
        fun fromJson(j: JsonObject) = SceneSchedule(
            hour = j.int("hour") ?: 0,
            minute = j.int("minute") ?: 0,
            days = j.list("days")?.mapNotNull { it.number()?.toInt() }?.toSet() ?: (1..7).toSet(),
        )
    }
}

/** A named set of device states applied with one tap, e.g. "Movie night". */
data class Scene(
    val id: String,
    val name: String,
    val icon: String = "auto",
    val actions: List<SceneAction> = emptyList(),
    val schedule: SceneSchedule? = null,
) {
    fun toJson() = jsonObjectOf(
        "id" to id, "name" to name, "icon" to icon, "actions" to actions.map { it.toJson() },
        "schedule" to schedule?.toJson(),
    )

    companion object {
        fun fromJson(j: JsonObject) = Scene(
            id = j.string("id")!!,
            name = j.string("name") ?: "Scene",
            icon = j.string("icon") ?: "auto",
            actions = j.list("actions")?.mapNotNull { it.asObj()?.let(SceneAction::fromJson) } ?: emptyList(),
            schedule = j.obj("schedule")?.let(SceneSchedule::fromJson),
        )

        /** Ready-made scenes offered when creating one: name and icon. */
        val templates = listOf(
            "All off" to "off", "Good morning" to "morning", "Movie night" to "movie", "Good night" to "night",
            "Away" to "away", "Dinner" to "dinner", "Focus" to "focus",
        )
    }
}

/**
 * Everything the app stores about one home. Saved locally as JSON in the same shape as the Flutter app, so homes move
 * between the two. Parts this app does not use yet (automations) are kept as they are.
 */
data class HomeData(
    val floors: List<Floor> = emptyList(),
    val rooms: List<Room> = emptyList(),
    val devices: List<Device> = emptyList(),
    val integrations: List<IntegrationConfig> = emptyList(),
    val scenes: List<Scene> = emptyList(),
    val automations: JsonArray = JsonArray(emptyList()),
    val themeMode: String = "dark",
) {
    fun device(id: String) = devices.firstOrNull { it.id == id }
    fun room(id: String?) = rooms.firstOrNull { it.id == id }
    fun integration(id: String) = integrations.firstOrNull { it.id == id }
    fun roomsOn(floorId: String) = rooms.filter { it.floorId == floorId }
    fun devicesIn(roomId: String) = devices.filter { it.roomId == roomId }

    fun toJson(withState: Boolean = true): JsonObject = buildJsonObject {
        put("app", "SmartMenuKJ")
        put("version", SCHEMA_VERSION)
        put("themeMode", themeMode)
        put("floors", JsonArray(floors.map { it.toJson() }))
        put("rooms", JsonArray(rooms.map { it.toJson() }))
        put("devices", JsonArray(devices.map { it.toJson(withState) }))
        put("integrations", JsonArray(integrations.map { it.toJson() }))
        put("scenes", JsonArray(scenes.map { it.toJson() }))
        if (automations.isNotEmpty()) put("automations", automations)
    }

    companion object {
        const val SCHEMA_VERSION = 1

        fun fromJson(j: JsonObject): HomeData {
            fun list(k: String) = j.list(k)?.mapNotNull { it.asObj() } ?: emptyList()
            fun <T> each(k: String, f: (JsonObject) -> T) = list(k).mapNotNull { runCatching { f(it) }.getOrNull() }
            return HomeData(
                themeMode = j.string("themeMode") ?: "dark",
                floors = each("floors", Floor::fromJson),
                rooms = each("rooms", Room::fromJson),
                devices = each("devices", Device::fromJson),
                integrations = each("integrations", IntegrationConfig::fromJson),
                scenes = each("scenes", Scene::fromJson),
                automations = j.list("automations") ?: JsonArray(emptyList()),
            )
        }
    }
}

/** A home in the list of homes. Its data is saved on its own. */
data class HomeEntry(val id: String, val name: String) {
    fun toJson() = jsonObjectOf("id" to id, "name" to name)

    companion object {
        fun fromJson(j: JsonObject) = HomeEntry(j.string("id")!!, j.string("name") ?: "Home")
    }
}
