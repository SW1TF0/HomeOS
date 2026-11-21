package com.smartmenukj.core.model

import com.smartmenukj.core.util.ColorMath
import kotlin.math.roundToInt

/** Words for showing devices on screen. */
object Describe {
    /** "Cleaning", "Going home", "Armed away"... for [DeviceState.activity]. */
    fun activity(kind: DeviceKind, activity: String?): String = when (activity) {
        null -> if (kind == DeviceKind.alarm) "Unknown" else "Ready"
        Activity.RUNNING -> when (kind) {
            DeviceKind.vacuum -> "Cleaning"
            DeviceKind.mower -> "Mowing"
            else -> "Running"
        }
        Activity.PAUSED -> "Paused"
        Activity.RETURNING -> "Going home"
        Activity.DOCKED -> "Docked"
        Activity.CHARGING -> "Charging"
        Activity.IDLE -> "Idle"
        Activity.ERROR -> "Needs help"
        Activity.DISARMED -> "Disarmed"
        Activity.ARMED_HOME -> "Armed home"
        Activity.ARMED_AWAY -> "Armed away"
        Activity.ARMED_NIGHT -> "Armed night"
        Activity.ARMED_VACATION -> "Armed vacation"
        Activity.ARMED_CUSTOM -> "Armed"
        Activity.ARMING -> "Arming"
        Activity.PENDING -> "Entry delay"
        Activity.DISARMING -> "Disarming"
        Activity.TRIGGERED -> "ALARM"
        else -> mode(activity)
    }

    /** "fan_only" -> "Fan", "heat_cool" -> "Heat/cool". */
    fun mode(mode: String): String {
        val m = mode.trim()
        if (m.isEmpty()) return m
        val known = mapOf("heat_cool" to "Heat/cool", "fan_only" to "Fan", "dry" to "Dry", "auto" to "Auto", "off" to "Off")
        known[m.lowercase()]?.let { return it }
        return m.replace('_', ' ').replaceFirstChar { it.uppercase() }
    }

    private fun pct(v: Double) = "${(v * 100).roundToInt()}%"
    private fun one(v: Double) = "%.1f".format(java.util.Locale.ROOT, v)

    /** One-line description of a device's state, e.g. "On · 72%". */
    fun state(d: Device): String {
        val s = d.state
        if (!s.reachable) return "Not responding"
        return when (d.kind) {
            DeviceKind.cover, DeviceKind.garage -> {
                if (s.position == null && s.on != null) return if (s.on) "Open" else "Closed"
                val p = s.position ?: 0.0
                if (p <= 0.01) "Closed" else if (p >= 0.99) "Open" else "Open ${pct(p)}"
            }
            DeviceKind.valve -> if (s.on == null) s.readings.values.firstOrNull() ?: "Unknown" else if (s.on) "Open" else "Closed"
            DeviceKind.siren -> when (s.on) { true -> "Sounding"; false -> "Off"; null -> "Unknown" }
            DeviceKind.vacuum, DeviceKind.mower, DeviceKind.appliance -> listOfNotNull(
                s.readings["Error"]?.takeIf { s.activity == Activity.ERROR } ?: activity(d.kind, s.activity),
                s.battery?.let(::pct),
            ).joinToString(" · ")
            DeviceKind.alarm -> activity(d.kind, s.activity)
            DeviceKind.button -> "Tap to run"
            DeviceKind.camera -> s.readings.values.firstOrNull() ?: "Camera"
            DeviceKind.humidifier -> listOfNotNull(
                s.currentHumidity?.let { "${it.roundToInt()}%" },
                if (s.on == false) "Off" else s.targetHumidity?.let { "set ${it.roundToInt()}%" },
            ).joinToString(" · ").ifEmpty { if (s.on == true) "On" else "Off" }
            DeviceKind.lock -> when (s.locked) { null -> "Unknown"; true -> "Locked"; false -> "Unlocked" }
            DeviceKind.climate -> {
                val m = if (d.has(Capability.mode) && s.mode != null) mode(s.mode) else "set"
                listOfNotNull(
                    s.currentTemp?.let { "${one(it)}°" },
                    if (s.on == false) "Off" else s.targetTemp?.let { "$m ${one(it)}°" },
                ).joinToString(" · ").ifEmpty { "Climate" }
            }
            DeviceKind.sensor -> if (s.readings.isEmpty()) "No readings yet" else s.readings.values.take(2).joinToString(" · ")
            DeviceKind.media -> listOfNotNull(
                s.on?.let { if (it) "On" else "Off" },
                if (s.on != false && s.muted == true) "Muted" else if (s.on != false) s.volume?.let { "Vol ${(it * 100).roundToInt()}" } else null,
                s.readings["Playing"]?.takeIf { s.on != false && it != "Nothing" },
            ).joinToString(" · ").ifEmpty { s.readings.values.firstOrNull() ?: "Unknown" }
            else -> when {
                s.on == null -> s.readings.values.firstOrNull() ?: "Unknown"
                !s.on -> "Off"
                d.has(Capability.brightness) && s.brightness != null -> "On · ${pct(s.brightness)}"
                d.has(Capability.mode) && s.mode != null -> "On · ${mode(s.mode)}"
                d.has(Capability.speed) && s.speed != null -> "On · ${pct(s.speed)}"
                else -> "On"
            }
        }
    }

    /** A device's temperature reading in °C, from a thermostat or a sensor. */
    fun temperature(d: Device): Double? {
        if (!d.state.reachable) return null
        d.state.currentTemp?.let { return it }
        val raw = d.state.readings["Temperature"] ?: return null
        return Regex("-?\\d+(\\.\\d+)?").find(raw)?.value?.toDoubleOrNull()
    }

    fun averageTemperature(devices: List<Device>): Double? = devices.mapNotNull(::temperature).takeIf { it.isNotEmpty() }?.average()

    /** The colour (0xRRGGBB) a light gives off, for the glow on tiles and the map. */
    fun lightColor(d: Device): Int? {
        if (d.kind != DeviceKind.light || d.state.on != true) return null
        d.state.color?.let { return it }
        return d.state.colorTempK?.let(ColorMath::kelvinToRgb)
    }

    /** Whether a tap switches the device (instead of opening its controls). */
    fun tapToggles(d: Device) = d.has(Capability.lock) || d.has(Capability.onOff) || d.has(Capability.position) ||
        d.has(Capability.press) || (d.has(Capability.run) && (d.kind == DeviceKind.vacuum || d.kind == DeviceKind.mower))

    /** The 0..1 level a tile can drag: brightness, blind position, volume, fan speed. */
    fun level(d: Device): Double? = when {
        d.has(Capability.brightness) -> if (d.state.on == false) 0.0 else d.state.brightness
        d.has(Capability.position) -> d.state.position
        d.has(Capability.speed) -> if (d.state.on == false) 0.0 else d.state.speed
        d.has(Capability.volume) -> d.state.volume
        else -> null
    }

    fun levelCommand(d: Device, v: Double): DeviceCommand? = when {
        d.has(Capability.brightness) -> if (v <= 0.01) DeviceCommand(on = false) else DeviceCommand(brightness = v)
        d.has(Capability.position) -> DeviceCommand(position = v)
        d.has(Capability.speed) -> if (v <= 0.01) DeviceCommand(on = false) else DeviceCommand(speed = v)
        d.has(Capability.volume) -> DeviceCommand(volume = v)
        else -> null
    }
}
