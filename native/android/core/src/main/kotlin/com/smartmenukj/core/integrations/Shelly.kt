package com.smartmenukj.core.integrations

import com.smartmenukj.core.json.*
import com.smartmenukj.core.model.*
import com.smartmenukj.core.net.Http
import kotlinx.serialization.json.JsonObject
import kotlin.math.roundToInt

/**
 * Shelly relays, dimmers, plugs, roller shutters and H&T sensors over their local HTTP API. Supports Gen1 and Gen2+
 * (Plus / Pro / Gen3 / Gen4).
 */
class ShellyDriver(config: IntegrationConfig, http: Http) : HostListDriver(config, http) {
    private fun u(host: String, path: String, q: Map<String, String> = emptyMap()) =
        "http://$host$path" + if (q.isEmpty()) "" else "?" + query(q)

    override suspend fun probe(host: String): List<Device> {
        val info = getJson(u(host, "/shelly")).asObj() ?: throw IntegrationException("$host is not a Shelly.")
        val gen = info.int("gen") ?: 1
        val base = info.string("name") ?: info.string("type") ?: info.string("model") ?: "Shelly"
        return if (gen >= 2) probeGen2(host, base) else probeGen1(host, base)
    }

    private suspend fun probeGen2(host: String, base: String): List<Device> {
        val status = readHost(host) as JsonObject
        val config = runCatching { getJson(u(host, "/rpc/Shelly.GetConfig")).asObj() }.getOrNull() ?: JsonObject(emptyMap())
        val out = mutableListOf<Device>()
        val readings = mutableMapOf<String, String>()
        for (key in status.keys) {
            val parts = key.split(':')
            if (parts.size != 2) continue
            val comp = parts[0]
            val ch = parts[1].toIntOrNull() ?: 0
            val label = config.obj(key)?.string("name")
            fun name(fallback: String) = label ?: if (ch == 0) base else "$base $fallback ${ch + 1}"
            val props = mapOf("host" to host, "gen" to 2, "component" to comp, "channel" to ch)
            when (comp) {
                "switch" -> out += makeDevice("$host#switch:$ch", name("switch"), DeviceKind.outlet, props = props,
                    state = gen2State(comp, status.obj(key)))
                "light" -> out += makeDevice("$host#light:$ch", name("light"), DeviceKind.light,
                    setOf(Capability.onOff, Capability.brightness), props, gen2State(comp, status.obj(key)))
                "cover" -> out += makeDevice("$host#cover:$ch", name("cover"), DeviceKind.cover, props = props,
                    state = gen2State(comp, status.obj(key)))
                "temperature", "humidity", "devicepower" -> readings += gen2Readings(JsonObject(mapOf(key to status[key]!!)))
            }
        }
        if (readings.isNotEmpty()) {
            out += makeDevice("$host#sensor", "$base sensor", DeviceKind.sensor,
                props = mapOf("host" to host, "gen" to 2, "component" to "sensor", "channel" to 0),
                state = DeviceState(readings = readings))
        }
        return out
    }

    private suspend fun probeGen1(host: String, base: String): List<Device> {
        val status = readHost(host) as JsonObject
        val mode = runCatching { getJson(u(host, "/settings")).asObj()?.string("mode") }.getOrNull() ?: "relay"
        val out = mutableListOf<Device>()
        fun add(comp: String, kind: DeviceKind, count: Int, caps: Set<Capability>?) {
            for (ch in 0 until count) {
                val d = makeDevice("$host#$comp:$ch", if (count == 1) base else "$base ${ch + 1}", kind, caps,
                    mapOf("host" to host, "gen" to 1, "component" to comp, "channel" to ch))
                out += d.copy(state = DeviceState().merge(gen1State(comp, ch, status)))
            }
        }
        val relays = status.list("relays")?.size ?: 0
        val lights = status.list("lights")?.size ?: 0
        val rollers = status.list("rollers")?.size ?: 0
        if (mode == "roller" && rollers > 0) add("roller", DeviceKind.cover, rollers, null)
        else if (relays > 0) add("relay", DeviceKind.outlet, relays, null)
        if (lights > 0) add("light", DeviceKind.light, lights, setOf(Capability.onOff, Capability.brightness))
        val readings = gen1Readings(status)
        if (readings.isNotEmpty()) {
            out += makeDevice("$host#sensor", "$base sensor", DeviceKind.sensor,
                props = mapOf("host" to host, "gen" to 1, "component" to "sensor", "channel" to 0),
                state = DeviceState(readings = readings))
        }
        return out
    }

    /** Gen2 answers /rpc; Gen1 answers /status. */
    override suspend fun readHost(host: String): Any? = try {
        getJson(u(host, "/rpc/Shelly.GetStatus")).asObj() ?: throw IntegrationException("no status")
    } catch (e: Exception) {
        getJson(u(host, "/status")).asObj()
    }

    override fun stateFrom(device: Device, hostData: Any?): DeviceState? {
        val status = hostData as? JsonObject ?: return null
        val comp = device.prop("component") ?: return null
        val ch = device.props.int("channel") ?: 0
        if (device.props.int("gen") == 1) {
            return if (comp == "sensor") DeviceState(readings = gen1Readings(status)) else gen1State(comp, ch, status)
        }
        if (comp == "sensor") return DeviceState(readings = gen2Readings(status))
        return gen2State(comp, status.obj("$comp:$ch"))
    }

    override suspend fun send(device: Device, command: DeviceCommand): DeviceState? {
        val host = device.prop("host")!!
        val comp = device.prop("component")!!
        val ch = "${device.props.int("channel") ?: 0}"
        val c = command
        if (device.props.int("gen") == 1) {
            when (comp) {
                "roller" -> c.position?.let {
                    getJson(u(host, "/roller/$ch", mapOf("go" to "to_pos", "roller_pos" to "${(it * 100).roundToInt()}")))
                }
                "light" -> {
                    val q = mutableMapOf<String, String>()
                    c.on?.let { q["turn"] = if (it) "on" else "off" }
                    c.brightness?.let { q["turn"] = "on"; q["brightness"] = "${(it * 100).roundToInt().coerceIn(1, 100)}" }
                    getJson(u(host, "/light/$ch", q))
                }
                else -> c.on?.let { getJson(u(host, "/relay/$ch", mapOf("turn" to if (it) "on" else "off"))) }
            }
            return null
        }
        when (comp) {
            "cover" -> c.position?.let {
                getJson(u(host, "/rpc/Cover.GoToPosition", mapOf("id" to ch, "pos" to "${(it * 100).roundToInt()}")))
            }
            "light" -> {
                val q = mutableMapOf("id" to ch)
                c.on?.let { q["on"] = "$it" }
                c.brightness?.let { q["on"] = "true"; q["brightness"] = "${(it * 100).roundToInt().coerceIn(1, 100)}" }
                getJson(u(host, "/rpc/Light.Set", q))
            }
            else -> c.on?.let { getJson(u(host, "/rpc/Switch.Set", mapOf("id" to ch, "on" to "$it"))) }
        }
        return null
    }

    companion object {
        fun gen2State(comp: String, s: JsonObject?): DeviceState {
            val st = s ?: JsonObject(emptyMap())
            return when (comp) {
                "cover" -> DeviceState(position = (st.double("current_pos") ?: 0.0) / 100)
                "light" -> DeviceState(on = st.bool("output"), brightness = st.double("brightness")?.let { it / 100 })
                else -> DeviceState(
                    on = st.bool("output"),
                    readings = st["apower"]?.let { mapOf("Power" to "${it.text()} W") } ?: emptyMap(),
                )
            }
        }

        fun gen2Readings(status: JsonObject): Map<String, String> {
            val out = mutableMapOf<String, String>()
            for ((k, v) in status) {
                val m = v.asObj() ?: continue
                if (k.startsWith("temperature:") && m["tC"] != null) out["Temperature"] = "${m["tC"].text()} °C"
                if (k.startsWith("humidity:") && m["rh"] != null) out["Humidity"] = "${m["rh"].text()} %"
                if (k.startsWith("devicepower:")) m.obj("battery")?.let { out["Battery"] = "${it["percent"].text()} %" }
            }
            return out
        }

        fun gen1State(comp: String, ch: Int, status: JsonObject): DeviceState {
            fun item(key: String): JsonObject = status.list(key)?.getOrNull(ch).asObj() ?: JsonObject(emptyMap())
            return when (comp) {
                "roller" -> DeviceState(position = (item("rollers").double("current_pos") ?: 0.0) / 100)
                "light" -> DeviceState(on = item("lights").bool("ison"), brightness = item("lights").double("brightness")?.let { it / 100 })
                else -> DeviceState(on = item("relays").bool("ison"))
            }
        }

        fun gen1Readings(status: JsonObject): Map<String, String> {
            val out = mutableMapOf<String, String>()
            status.obj("tmp")?.let { t -> t["value"]?.let { out["Temperature"] = "${it.text()} °${t.string("units") ?: "C"}" } }
            status.obj("hum")?.get("value")?.let { out["Humidity"] = "${it.text()} %" }
            status.obj("bat")?.get("value")?.let { out["Battery"] = "${it.text()} %" }
            return out
        }
    }
}
