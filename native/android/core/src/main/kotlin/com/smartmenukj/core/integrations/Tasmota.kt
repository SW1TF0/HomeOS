package com.smartmenukj.core.integrations

import com.smartmenukj.core.json.*
import com.smartmenukj.core.model.*
import com.smartmenukj.core.net.Http
import com.smartmenukj.core.util.ColorMath
import kotlinx.serialization.json.JsonObject
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.roundToInt

/** Devices running the open Tasmota firmware, over its HTTP command API. */
class TasmotaDriver(config: IntegrationConfig, http: Http) : HostListDriver(config, http) {
    private val password get() = config.setting("password")

    private suspend fun cmd(host: String, command: String): JsonObject? {
        val q = mutableMapOf<String, String>()
        if (password.isNotEmpty()) { q["user"] = "admin"; q["password"] = password }
        q["cmnd"] = command
        return getJson("http://$host/cm?" + query(q)).asObj()
    }

    override suspend fun readHost(host: String): Any? = cmd(host, "Status 0")

    override suspend fun probe(host: String): List<Device> {
        val data = readHost(host) as? JsonObject ?: throw IntegrationException("$host is not a Tasmota device.")
        val status = data.obj("Status") ?: JsonObject(emptyMap())
        val sts = data.obj("StatusSTS") ?: JsonObject(emptyMap())
        val names = status.list("FriendlyName")?.map { it.text() } ?: emptyList()
        val deviceName = status.string("DeviceName") ?: names.firstOrNull() ?: "Tasmota"
        val powerKeys = sts.keys.filter { Regex("^POWER\\d*$").matches(it) }.sorted()
        val isLight = "Dimmer" in sts
        val out = mutableListOf<Device>()
        for (key in powerKeys) {
            val idx = if (key == "POWER") 1 else key.substring(5).toInt()
            val caps = mutableSetOf(Capability.onOff)
            if (isLight && idx == 1) {
                caps += Capability.brightness
                if ("CT" in sts) caps += Capability.colorTemp
                if ("HSBColor" in sts) caps += Capability.color
            }
            val name = names.getOrNull(idx - 1)?.takeIf { it.isNotEmpty() }
                ?: if (powerKeys.size == 1) deviceName else "$deviceName $idx"
            val d = makeDevice("$host#$idx", name, if (isLight && idx == 1) DeviceKind.light else DeviceKind.outlet, caps,
                mapOf("host" to host, "channel" to idx))
            out += d.copy(state = DeviceState().merge(stateFrom(d, data) ?: DeviceState()))
        }
        val readings = readings(data.obj("StatusSNS"))
        if (readings.isNotEmpty()) {
            out += makeDevice("$host#sensor", "$deviceName sensor", DeviceKind.sensor,
                props = mapOf("host" to host, "channel" to 0), state = DeviceState(readings = readings))
        }
        return out
    }

    override fun stateFrom(device: Device, hostData: Any?): DeviceState? {
        val map = hostData as? JsonObject ?: return null
        val idx = device.props.int("channel") ?: 1
        if (idx == 0) return DeviceState(readings = readings(map.obj("StatusSNS")))
        val sts = map.obj("StatusSTS") ?: map
        val power = sts["POWER$idx"] ?: if (idx == 1) sts["POWER"] else null
        val hsb = sts.string("HSBColor")
        val white = sts.double("White")
        return DeviceState(
            on = power?.let { it.text() == "ON" },
            brightness = if (device.has(Capability.brightness)) sts.double("Dimmer")?.let { it / 100 } else null,
            colorTempK = if (device.has(Capability.colorTemp) && (white == null || white > 0)) {
                sts.double("CT")?.let(ColorMath::miredToKelvin)
            } else null,
            color = if (device.has(Capability.color) && hsb != null && (white == null || white == 0.0)) hsbToRgb(hsb) else null,
        )
    }

    override suspend fun send(device: Device, command: DeviceCommand): DeviceState? {
        val host = device.prop("host")!!
        val idx = device.props.int("channel") ?: 1
        command.on?.let { cmd(host, "Power$idx ${if (it) "On" else "Off"}") }
        command.brightness?.let { cmd(host, "Dimmer ${(it * 100).roundToInt()}") }
        command.colorTempK?.let { cmd(host, "CT ${ColorMath.kelvinToMired(it).coerceIn(153, 500)}") }
        command.color?.let { cmd(host, "Color ${ColorMath.hex(it)}") }
        return null
    }

    companion object {
        fun readings(sns: JsonObject?): Map<String, String> {
            val out = mutableMapOf<String, String>()
            if (sns == null) return out
            val unit = sns.string("TempUnit") ?: "C"
            for ((_, values) in sns) {
                val m = values.asObj() ?: continue
                for ((k, v) in m) {
                    if (!v.isNumber()) continue
                    val (label, u) = when (k) {
                        "Temperature" -> "Temperature" to " °$unit"
                        "Humidity" -> "Humidity" to " %"
                        "Pressure" -> "Pressure" to " hPa"
                        "Power" -> "Power" to " W"
                        "Voltage" -> "Voltage" to " V"
                        "Today" -> "Energy today" to " kWh"
                        else -> continue
                    }
                    out[label] = "${v.text()}$u"
                }
            }
            return out
        }

        fun hsbToRgb(hsb: String): Int? {
            val p = hsb.split(',').map { it.toDoubleOrNull() ?: 0.0 }
            if (p.size < 3) return null
            val h = p[0] / 60; val s = p[1] / 100
            val c = s; val x = c * (1 - abs((h % 2) - 1)); val m = 1 - c
            val (r, g, b) = when (floor(h).toInt() % 6) {
                0 -> Triple(c, x, 0.0)
                1 -> Triple(x, c, 0.0)
                2 -> Triple(0.0, c, x)
                3 -> Triple(0.0, x, c)
                4 -> Triple(x, 0.0, c)
                else -> Triple(c, 0.0, x)
            }
            fun ch(v: Double) = ((v + m) * 255).roundToInt().coerceIn(0, 255)
            return ColorMath.rgb(ch(r), ch(g), ch(b))
        }
    }
}
