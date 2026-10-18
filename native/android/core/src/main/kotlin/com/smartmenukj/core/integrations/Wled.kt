package com.smartmenukj.core.integrations

import com.smartmenukj.core.json.*
import com.smartmenukj.core.model.*
import com.smartmenukj.core.net.Http
import com.smartmenukj.core.util.ColorMath
import kotlinx.serialization.json.JsonObject
import kotlin.math.roundToInt

/** LED strips running the open WLED firmware, over its JSON API. */
class WledDriver(config: IntegrationConfig, http: Http) : HostListDriver(config, http) {
    override suspend fun readHost(host: String): Any? = getJson("http://$host/json/state")

    override suspend fun probe(host: String): List<Device> {
        val data = getJson("http://$host/json").asObj() ?: throw IntegrationException("$host is not a WLED light.")
        val info = data.obj("info") ?: JsonObject(emptyMap())
        val d = makeDevice(
            externalId = host,
            name = info.string("name") ?: "WLED",
            kind = DeviceKind.light,
            capabilities = setOf(Capability.onOff, Capability.brightness, Capability.color),
            props = mapOf("host" to host, "leds" to info.obj("leds")?.int("count")),
        )
        return listOf(d.copy(state = stateFrom(d, data["state"]) ?: DeviceState()))
    }

    override fun stateFrom(device: Device, hostData: Any?): DeviceState? {
        val st = (hostData as? JsonObject) ?: return null
        val col = st.list("seg")?.firstOrNull().asObj()?.list("col")?.firstOrNull().asList()
        val color = if (col != null && col.size >= 3) {
            ColorMath.rgb(col[0].number()!!.toInt(), col[1].number()!!.toInt(), col[2].number()!!.toInt())
        } else null
        return DeviceState(on = st.bool("on"), brightness = st.double("bri")?.let { it / 255 }, color = color)
    }

    override suspend fun send(device: Device, command: DeviceCommand): DeviceState? {
        val host = device.prop("host")!!
        val body = mutableMapOf<String, Any?>("v" to true)
        command.on?.let { body["on"] = it }
        command.brightness?.let {
            body["on"] = it > 0
            body["bri"] = (it * 255).roundToInt().coerceIn(1, 255)
        }
        command.color?.let { body["seg"] = listOf(mapOf("col" to listOf(ColorMath.channels(it).toList()))) }
        val res = sendJson("POST", "http://$host/json/state", body)
        return (res as? JsonObject)?.let { stateFrom(device, it) }
    }
}
