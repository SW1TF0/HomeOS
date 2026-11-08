package com.smartmenukj.core.integrations

import com.smartmenukj.core.json.*
import com.smartmenukj.core.model.*
import com.smartmenukj.core.net.Http
import com.smartmenukj.core.util.ColorMath
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlin.math.roundToInt

/** Philips Hue bridge, over its local API. No Hue account or cloud needed. */
class HueDriver(config: IntegrationConfig, http: Http) : IntegrationDriver(config, http) {
    private val host get() = config.setting("host")
    private val username get() = config.setting("username")

    private fun api(path: String) = "http://$host/api/$username$path"

    private fun requireSetup() {
        if (host.isEmpty()) throw IntegrationException("Enter the bridge address, or use Scan network.")
        if (username.isEmpty()) throw IntegrationException("Press the bridge's link button, then tap Pair.")
    }

    override suspend fun pair(): Map<String, String> {
        if (host.isEmpty()) throw IntegrationException("Enter the bridge address first.")
        val res = sendJson("POST", "http://$host/api", mapOf("devicetype" to "smartmenukj#native"))
        val first = (res as? JsonArray)?.firstOrNull().asObj()
        first?.obj("success")?.string("username")?.let { return mapOf("username" to it) }
        val err = first?.obj("error")?.string("description") ?: "unexpected reply"
        throw IntegrationException("Bridge said: $err. Press the round link button on the bridge, then tap Pair within 30 seconds.")
    }

    private suspend fun lights(): JsonObject {
        requireSetup()
        val res = getJson(api("/lights"))
        throwHueError(res)
        return res.asObj() ?: JsonObject(emptyMap())
    }

    private fun throwHueError(res: JsonElement?) {
        val err = (res as? JsonArray)?.firstOrNull().asObj()?.obj("error") ?: return
        throw IntegrationException("Hue bridge: ${err.string("description")}")
    }

    override suspend fun discover(): List<Device> = lights().map { (id, v) -> toDevice(id, v.asObj()!!) }

    private fun toDevice(id: String, light: JsonObject): Device {
        val st = light.obj("state") ?: JsonObject(emptyMap())
        val type = light.string("type").orEmpty().lowercase()
        val caps = mutableSetOf(Capability.onOff)
        if ("bri" in st) caps += Capability.brightness
        if ("ct" in st) caps += Capability.colorTemp
        if ("xy" in st) caps += Capability.color
        return makeDevice(
            externalId = id,
            name = light.string("name") ?: "Hue light $id",
            kind = if ("plug" in type) DeviceKind.outlet else DeviceKind.light,
            capabilities = caps,
            props = mapOf("model" to light.string("modelid"), "type" to light.string("type")),
            state = parseState(st),
        )
    }

    override suspend fun refreshAll(devices: List<Device>): Map<String, DeviceState> = try {
        val all = lights()
        devices.associate { d ->
            val st = all.obj(d.externalId)?.obj("state")
            d.id to d.state.merge(if (st == null) DeviceState.unreachable else parseState(st))
        }
    } catch (e: Exception) {
        devices.associate { it.id to it.state.merge(DeviceState.unreachable) }
    }

    override suspend fun refresh(device: Device): DeviceState? {
        requireSetup()
        val res = getJson(api("/lights/${device.externalId}"))
        throwHueError(res)
        return res.asObj()?.obj("state")?.let(::parseState)
    }

    override suspend fun send(device: Device, command: DeviceCommand): DeviceState? {
        requireSetup()
        val c = command
        val body = mutableMapOf<String, Any?>()
        c.on?.let { body["on"] = it }
        c.brightness?.let {
            body["on"] = it > 0
            body["bri"] = (it * 253 + 1).roundToInt().coerceIn(1, 254)
        }
        c.colorTempK?.let { body["ct"] = ColorMath.kelvinToMired(it).coerceIn(153, 500) }
        c.color?.let { body["xy"] = ColorMath.rgbToXy(it).toList() }
        throwHueError(sendJson("PUT", api("/lights/${device.externalId}/state"), body))
        return null
    }

    companion object {
        fun parseState(st: JsonObject): DeviceState {
            val xy = st.list("xy")
            val mode = st.string("colormode")
            return DeviceState(
                on = st.bool("on"),
                brightness = st.double("bri")?.let { (it - 1) / 253 },
                colorTempK = if (mode == "ct") st.double("ct")?.let(ColorMath::miredToKelvin) else null,
                color = if (mode != "ct" && xy != null && xy.size == 2) {
                    ColorMath.xyToRgb(xy[0].number() ?: 0.0, xy[1].number() ?: 0.0)
                } else null,
                reachable = st.bool("reachable") ?: true,
            )
        }
    }
}
