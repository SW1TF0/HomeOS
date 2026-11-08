package com.smartmenukj.core.model

import com.smartmenukj.core.json.*
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** What a device is, used for its icon and which controls it shows. Names match the Flutter app's saved homes. */
enum class DeviceKind(val label: String) {
    light("Light"),
    outlet("Plug"),
    toggle("Switch"),
    sensor("Sensor"),
    climate("Climate"),
    cover("Blind"),
    fan("Fan"),
    lock("Lock"),
    media("Media"),
    camera("Camera"),
    vacuum("Robot vacuum"),
    mower("Lawn mower"),
    purifier("Air purifier"),
    humidifier("Humidifier"),
    appliance("Appliance"),
    alarm("Alarm"),
    valve("Valve"),
    siren("Siren"),
    garage("Garage door"),
    button("Button"),
    other("Other");

    companion object {
        fun parse(name: String?): DeviceKind = entries.firstOrNull { it.name == name } ?: other
    }
}

/** A thing a device can do. Controls are shown only for capabilities it has. */
enum class Capability {
    onOff, brightness, colorTemp, color, position, targetTemp, lock, readings, volume, remote,
    run, dock, locate, mode, speed, humidity, alarm, press, snapshot;

    companion object {
        fun parse(name: String?): Capability? = entries.firstOrNull { it.name == name }
    }
}

/** One-off things to ask of a device: run a robot or an appliance, arm an alarm, press a button. */
enum class DeviceAction {
    start, pause, stop, dock, locate, press, armHome, armAway, armNight, armVacation, disarm;

    /** The alarm activity an arm or disarm action leads to. */
    val alarmState: String?
        get() = when (this) {
            armHome -> Activity.ARMED_HOME
            armAway -> Activity.ARMED_AWAY
            armNight -> Activity.ARMED_NIGHT
            armVacation -> Activity.ARMED_VACATION
            disarm -> Activity.DISARMED
            else -> null
        }

    companion object {
        fun parse(name: String?): DeviceAction? = entries.firstOrNull { it.name == name }
    }
}

/** What a robot, an appliance or an alarm is doing, as kept in [DeviceState.activity]. */
object Activity {
    const val RUNNING = "running"
    const val PAUSED = "paused"
    const val RETURNING = "returning"
    const val DOCKED = "docked"
    const val CHARGING = "charging"
    const val IDLE = "idle"
    const val ERROR = "error"

    const val DISARMED = "disarmed"
    const val ARMED_HOME = "armed_home"
    const val ARMED_AWAY = "armed_away"
    const val ARMED_NIGHT = "armed_night"
    const val ARMED_VACATION = "armed_vacation"
    const val ARMED_CUSTOM = "armed_custom_bypass"
    const val ARMING = "arming"
    const val PENDING = "pending"
    const val DISARMING = "disarming"
    const val TRIGGERED = "triggered"

    /** Busy doing its job, or guarding the home. */
    val busy = setOf(RUNNING, RETURNING, ARMED_HOME, ARMED_AWAY, ARMED_NIGHT, ARMED_VACATION, ARMED_CUSTOM, ARMING, PENDING, TRIGGERED)

    fun after(a: DeviceAction?): String? = when (a) {
        DeviceAction.start -> RUNNING
        DeviceAction.pause -> PAUSED
        DeviceAction.stop -> IDLE
        DeviceAction.dock -> RETURNING
        DeviceAction.locate, DeviceAction.press, null -> null
        else -> a.alarmState
    }

    fun label(a: String?): String = when (a) {
        RUNNING -> "Running"
        PAUSED -> "Paused"
        RETURNING -> "Going home"
        DOCKED -> "Docked"
        CHARGING -> "Charging"
        IDLE -> "Idle"
        ERROR -> "Problem"
        DISARMED -> "Disarmed"
        ARMED_HOME -> "Armed home"
        ARMED_AWAY -> "Armed away"
        ARMED_NIGHT -> "Armed night"
        ARMED_VACATION -> "Armed vacation"
        ARMED_CUSTOM -> "Armed"
        ARMING -> "Arming"
        PENDING -> "Pending"
        DISARMING -> "Disarming"
        TRIGGERED -> "Triggered"
        null -> "—"
        else -> a.replace('_', ' ').replaceFirstChar { it.uppercase() }
    }
}

/** Buttons of a TV / media remote. Drivers map them to their own key codes. */
enum class RemoteKey {
    power, volumeUp, volumeDown, mute, channelUp, channelDown, up, down, left, right, ok, back, home, menu,
    playPause, stop, rewind, forward, source;

    companion object {
        fun parse(name: String?): RemoteKey? = entries.firstOrNull { it.name == name }
    }
}

fun defaultCapabilities(kind: DeviceKind): Set<Capability> = when (kind) {
    DeviceKind.light -> setOf(Capability.onOff, Capability.brightness, Capability.colorTemp, Capability.color)
    DeviceKind.outlet, DeviceKind.toggle, DeviceKind.fan, DeviceKind.valve, DeviceKind.siren -> setOf(Capability.onOff)
    DeviceKind.media -> setOf(Capability.onOff, Capability.volume, Capability.remote)
    DeviceKind.sensor -> setOf(Capability.readings)
    DeviceKind.climate -> setOf(Capability.onOff, Capability.targetTemp)
    DeviceKind.cover, DeviceKind.garage -> setOf(Capability.position)
    DeviceKind.lock -> setOf(Capability.lock)
    DeviceKind.vacuum -> setOf(Capability.run, Capability.dock, Capability.locate, Capability.mode)
    DeviceKind.mower -> setOf(Capability.run, Capability.dock)
    DeviceKind.purifier -> setOf(Capability.onOff, Capability.speed, Capability.mode)
    DeviceKind.humidifier -> setOf(Capability.onOff, Capability.humidity)
    DeviceKind.appliance -> setOf(Capability.run)
    DeviceKind.alarm -> setOf(Capability.alarm)
    DeviceKind.button -> setOf(Capability.press)
    DeviceKind.camera, DeviceKind.other -> emptySet()
}

/** A requested change. Null fields are left as they are. */
data class DeviceCommand(
    val on: Boolean? = null,
    /** 0..1 */
    val brightness: Double? = null,
    val colorTempK: Int? = null,
    /** 0xRRGGBB */
    val color: Int? = null,
    /** 0 (closed) .. 1 (open) */
    val position: Double? = null,
    val targetTemp: Double? = null,
    val locked: Boolean? = null,
    /** 0..1 */
    val volume: Double? = null,
    val muted: Boolean? = null,
    /** A remote button press. Does not change the stored state by itself. */
    val key: RemoteKey? = null,
    val action: DeviceAction? = null,
    /** One of the device's `props.modes`. */
    val mode: String? = null,
    /** 0..1 */
    val speed: Double? = null,
    /** Percent. */
    val targetHumidity: Double? = null,
    /** An alarm code, sent with arm and disarm. Never saved. */
    val code: String? = null,
) {
    override fun toString(): String =
        "DeviceCommand(on=$on, brightness=$brightness, ct=$colorTempK, color=$color, position=$position, " +
            "target=$targetTemp, locked=$locked, volume=$volume, muted=$muted, key=$key, action=$action, mode=$mode, " +
            "speed=$speed, humidity=$targetHumidity${if (code == null) "" else ", code=****"})"
}

/** The last known state of a device. */
data class DeviceState(
    val on: Boolean? = null,
    val brightness: Double? = null,
    val colorTempK: Int? = null,
    val color: Int? = null,
    val position: Double? = null,
    val targetTemp: Double? = null,
    val currentTemp: Double? = null,
    val locked: Boolean? = null,
    val volume: Double? = null,
    val muted: Boolean? = null,
    /** What a robot, an appliance or an alarm is doing (see [Activity]). */
    val activity: String? = null,
    /** 0..1 */
    val battery: Double? = null,
    val mode: String? = null,
    /** 0..1 */
    val speed: Double? = null,
    val targetHumidity: Double? = null,
    val currentHumidity: Double? = null,
    val readings: Map<String, String> = emptyMap(),
    val reachable: Boolean = true,
) {
    /** Whether the device counts as "active" for summaries and the map. */
    val isActive: Boolean
        get() = on == true || (position != null && position > 0.01 && on == null) || locked == false ||
            activity in Activity.busy

    fun applyCommand(c: DeviceCommand) = DeviceState(
        on = c.on ?: if ((c.brightness ?: c.speed ?: 0.0) > 0) true
        else if (c.key == RemoteKey.power && on != null) !on else on,
        brightness = c.brightness ?: brightness,
        colorTempK = c.colorTempK ?: if (c.color != null) null else colorTempK,
        color = c.color ?: if (c.colorTempK != null) null else color,
        position = c.position ?: position,
        targetTemp = c.targetTemp ?: targetTemp,
        currentTemp = currentTemp,
        locked = c.locked ?: locked,
        volume = c.volume ?: volume,
        muted = c.muted ?: if (c.key == RemoteKey.mute && muted != null) !muted else muted,
        activity = Activity.after(c.action) ?: activity,
        battery = battery,
        mode = c.mode ?: mode,
        speed = c.speed ?: speed,
        targetHumidity = c.targetHumidity ?: targetHumidity,
        currentHumidity = currentHumidity,
        readings = readings,
        reachable = reachable,
    )

    /**
     * Overlays the known fields of [other] on this state. An empty mode or reading in [other] is a device saying it
     * has none any more, so it is removed.
     */
    fun merge(other: DeviceState) = DeviceState(
        on = other.on ?: on,
        brightness = other.brightness ?: brightness,
        colorTempK = other.colorTempK ?: colorTempK,
        color = other.color ?: color,
        position = other.position ?: position,
        targetTemp = other.targetTemp ?: targetTemp,
        currentTemp = other.currentTemp ?: currentTemp,
        locked = other.locked ?: locked,
        volume = other.volume ?: volume,
        muted = other.muted ?: muted,
        activity = other.activity ?: activity,
        battery = other.battery ?: battery,
        mode = if (other.mode == null) mode else other.mode.ifEmpty { null },
        speed = other.speed ?: speed,
        targetHumidity = other.targetHumidity ?: targetHumidity,
        currentHumidity = other.currentHumidity ?: currentHumidity,
        readings = if (other.readings.isEmpty()) readings else (readings + other.readings).filterValues { it.isNotEmpty() },
        reachable = other.reachable,
    )

    fun toJson(): JsonObject = buildJsonObject {
        on?.let { put("on", it) }
        brightness?.let { put("brightness", it) }
        colorTempK?.let { put("colorTempK", it) }
        color?.let { put("color", it) }
        position?.let { put("position", it) }
        targetTemp?.let { put("targetTemp", it) }
        currentTemp?.let { put("currentTemp", it) }
        locked?.let { put("locked", it) }
        volume?.let { put("volume", it) }
        muted?.let { put("muted", it) }
        activity?.let { put("activity", it) }
        battery?.let { put("battery", it) }
        mode?.let { put("mode", it) }
        speed?.let { put("speed", it) }
        targetHumidity?.let { put("targetHumidity", it) }
        currentHumidity?.let { put("currentHumidity", it) }
        if (readings.isNotEmpty()) put("readings", JsonObject(readings.mapValues { JsonPrimitive(it.value) }))
        put("reachable", reachable)
    }

    companion object {
        val unreachable = DeviceState(reachable = false)

        fun fromJson(j: JsonObject) = DeviceState(
            on = j.bool("on"),
            brightness = j.double("brightness"),
            colorTempK = j.int("colorTempK"),
            color = j.int("color"),
            position = j.double("position"),
            targetTemp = j.double("targetTemp"),
            currentTemp = j.double("currentTemp"),
            locked = j.bool("locked"),
            volume = j.double("volume"),
            muted = j.bool("muted"),
            activity = j.string("activity"),
            battery = j.double("battery"),
            mode = j.string("mode"),
            speed = j.double("speed"),
            targetHumidity = j.double("targetHumidity"),
            currentHumidity = j.double("currentHumidity"),
            readings = j.obj("readings")?.mapValues { it.value.text() } ?: emptyMap(),
            reachable = j.bool("reachable") ?: true,
        )
    }
}

/** A point on a floor plan, in map units (one grid cell). */
data class MapPos(val x: Double, val y: Double)

data class Device(
    val id: String,
    val name: String,
    val kind: DeviceKind,
    val integrationId: String,
    /** The device's address inside its integration (a Hue light id, an entity id, a host...). */
    val externalId: String,
    val capabilities: Set<Capability> = defaultCapabilities(kind),
    /** Integration-specific details (host, channel, topics...). */
    val props: JsonObject = JsonObject(emptyMap()),
    val roomId: String? = null,
    val floorId: String? = null,
    /** Position on its floor's map. Null when not placed yet. */
    val mapPos: MapPos? = null,
    val favorite: Boolean = false,
    val state: DeviceState = DeviceState(),
) {
    fun has(c: Capability) = c in capabilities

    /** Counts towards "3 on" summaries. Locks and alarms are about safety, not power. */
    val countsAsOn: Boolean get() = state.isActive && kind != DeviceKind.lock && kind != DeviceKind.alarm

    /** The choices of [Capability.mode] (suction powers, presets, inputs...). */
    val modes: List<String> get() = props.list("modes")?.map { it.text() } ?: emptyList()

    fun prop(key: String): String? = props.string(key)

    fun toJson(withState: Boolean = true): JsonObject = buildJsonObject {
        put("id", id)
        put("name", name)
        put("kind", kind.name)
        put("integrationId", integrationId)
        put("externalId", externalId)
        put("capabilities", jsonArrayOf(capabilities.map { JsonPrimitive(it.name) }))
        put("props", props)
        roomId?.let { put("roomId", it) }
        floorId?.let { put("floorId", it) }
        mapPos?.let { put("mapPos", jsonArrayOf(listOf(JsonPrimitive(it.x), JsonPrimitive(it.y)))) }
        put("favorite", favorite)
        if (withState) put("state", state.toJson())
    }

    companion object {
        /**
         * Stable id built from the integration and the device's id inside it, so re-syncing an integration updates
         * devices instead of duplicating them.
         */
        fun idFor(integrationId: String, externalId: String) = "$integrationId::$externalId"

        fun fromJson(j: JsonObject): Device {
            val kind = DeviceKind.parse(j.string("kind"))
            val pos = j.list("mapPos")
            return Device(
                id = j.string("id")!!,
                name = j.string("name") ?: "Device",
                kind = kind,
                integrationId = j.string("integrationId")!!,
                externalId = j.string("externalId")!!,
                capabilities = j.list("capabilities")?.mapNotNull { Capability.parse(it.text()) }?.toSet()
                    ?: defaultCapabilities(kind),
                props = j.obj("props") ?: JsonObject(emptyMap()),
                roomId = j.string("roomId"),
                floorId = j.string("floorId"),
                mapPos = if (pos != null && pos.size >= 2) MapPos(pos[0].number() ?: 0.0, pos[1].number() ?: 0.0) else null,
                favorite = j.bool("favorite") ?: false,
                state = j.obj("state")?.let { DeviceState.fromJson(it) } ?: DeviceState(),
            )
        }
    }
}
