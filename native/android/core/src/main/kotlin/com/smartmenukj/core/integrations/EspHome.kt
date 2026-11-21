package com.smartmenukj.core.integrations

import com.smartmenukj.core.json.*
import com.smartmenukj.core.model.*
import com.smartmenukj.core.net.Http
import kotlinx.serialization.json.JsonObject
import kotlin.math.roundToInt

/**
 * ESPHome nodes with the `web_server:` component enabled. Entities are read from the node's event stream and controlled
 * through its REST endpoints.
 */
class EspHomeDriver(config: IntegrationConfig, http: Http) : HostListDriver(config, http) {
    /** Reads the "state" events a node sends right after connecting: entity key ("domain/object") to its JSON. */
    override suspend fun readHost(host: String): Map<String, JsonObject> {
        val out = mutableMapOf<String, JsonObject>()
        var event = ""
        val status = http.readLines("http://$host/events", mapOf("Accept" to "text/event-stream"), LISTEN_MS) { line ->
            if (line.startsWith("event:")) {
                event = line.substring(6).trim()
            } else if (line.startsWith("data:") && event == "state") {
                runCatching {
                    val j = parseJson(line.substring(5).trim()).asObj()!!
                    entityKey(j.string("id") ?: "")?.let { out[it] = j }
                }
            }
        }
        if (status != 200) throw IntegrationException("$host answered HTTP $status. Is web_server enabled?")
        return out
    }

    override suspend fun probe(host: String): List<Device> {
        val entities = readHost(host)
        if (entities.isEmpty()) throw IntegrationException("$host sent no entities. Add `web_server:` to its ESPHome config.")
        val node = host.substringBefore('.')
        val out = mutableListOf<Device>()
        val readings = mutableMapOf<String, String>()
        for ((key, j) in entities) {
            val domain = key.substringBefore('/')
            val name = j.string("name") ?: key.substringAfter('/').replace('_', ' ')
            if (domain in sensorDomains) {
                readings[name] = (j["state"] ?: j["value"]).text()
                continue
            }
            val kind = when (domain) {
                "light" -> DeviceKind.light
                "switch" -> DeviceKind.toggle
                "fan" -> DeviceKind.fan
                "cover" -> DeviceKind.cover
                "lock" -> DeviceKind.lock
                else -> continue
            }
            val caps = if (kind == DeviceKind.light) {
                setOfNotNull(Capability.onOff, if ("brightness" in j) Capability.brightness else null)
            } else null
            val d = makeDevice("$host#$key", name, kind, caps, mapOf("host" to host, "entity" to key))
            out += d.copy(state = DeviceState().merge(stateFrom(d, entities) ?: DeviceState()))
        }
        if (readings.isNotEmpty()) {
            out += makeDevice("$host#sensors", "$node sensors", DeviceKind.sensor,
                props = mapOf("host" to host, "entity" to "sensors"), state = DeviceState(readings = readings))
        }
        return out
    }

    @Suppress("UNCHECKED_CAST")
    override fun stateFrom(device: Device, hostData: Any?): DeviceState? {
        val entities = hostData as? Map<String, JsonObject> ?: return null
        val key = device.prop("entity") ?: return null
        if (key == "sensors") {
            val readings = mutableMapOf<String, String>()
            for ((k, j) in entities) {
                if (k.substringBefore('/') in sensorDomains) {
                    readings[j.string("name") ?: k.substringAfter('/').replace('_', ' ')] = (j["state"] ?: j["value"]).text()
                }
            }
            return DeviceState(readings = readings)
        }
        val j = entities[key] ?: return DeviceState.unreachable
        val state = j["state"].text().uppercase()
        val value = j["value"]
        return DeviceState(
            on = if (value != null && value.bool() != null && !value.isNumber()) value.bool() else (state == "ON" || state == "OPEN"),
            brightness = if (j["brightness"].isNumber()) j.double("brightness")!! / 255 else null,
            position = if (device.kind == DeviceKind.cover && j["position"].isNumber()) j.double("position") else null,
            locked = if (device.kind == DeviceKind.lock) state == "LOCKED" else null,
        )
    }

    override suspend fun send(device: Device, command: DeviceCommand): DeviceState? {
        val host = device.prop("host")!!
        val entity = device.prop("entity")!!
        val domain = entity.substringBefore('/')
        val obj = entity.substringAfter('/')
        suspend fun post(action: String, q: Map<String, String> = emptyMap()) {
            val url = "http://$host/$domain/${enc(obj)}/$action" + if (q.isEmpty()) "" else "?" + query(q)
            val res = http.request("POST", url)
            if (res.status >= 400) throw IntegrationException("$host answered HTTP ${res.status}.")
        }
        val c = command
        when {
            c.position != null -> post("set", mapOf("position" to "%.2f".format(java.util.Locale.ROOT, c.position)))
            c.locked != null -> post(if (c.locked) "lock" else "unlock")
            c.brightness != null -> post("turn_on", mapOf("brightness" to "${(c.brightness * 255).roundToInt()}"))
            c.on != null -> post(if (c.on) "turn_on" else "turn_off")
        }
        return null
    }

    companion object {
        private const val LISTEN_MS = 2500L
        private val sensorDomains = setOf("sensor", "binary_sensor", "text_sensor")

        /** "light-desk_lamp" (web_server v1/v2) or "light/Desk Lamp" (v3) to "light/desk_lamp". */
        fun entityKey(id: String): String? {
            val m = Regex("^([a-z_]+)[-/](.+)$").find(id) ?: return null
            return "${m.groupValues[1]}/${m.groupValues[2]}"
        }
    }
}
