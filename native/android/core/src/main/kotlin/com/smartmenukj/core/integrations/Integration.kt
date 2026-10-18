package com.smartmenukj.core.integrations

import com.smartmenukj.core.json.*
import com.smartmenukj.core.model.*
import com.smartmenukj.core.net.Http
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** A field on an integration's settings form. */
data class SettingField(
    val key: String,
    val label: String,
    val hint: String = "",
    val secret: Boolean = false,
    val multiline: Boolean = false,
    val required: Boolean = false,
    val defaultValue: String? = null,
)

class IntegrationException(message: String) : Exception(message)

/** Talks to one configured integration. One instance exists per [IntegrationConfig]. */
abstract class IntegrationDriver(val config: IntegrationConfig, val http: Http) {
    /** Finds the devices this integration can control. */
    abstract suspend fun discover(): List<Device>

    abstract suspend fun refresh(device: Device): DeviceState?

    /** Sends [command]. Returns the confirmed state if the device reports one. */
    abstract suspend fun send(device: Device, command: DeviceCommand): DeviceState?

    /** For integrations that pair (Hue): returns settings to store on success. */
    open suspend fun pair(): Map<String, String> = throw IntegrationException("${config.name} does not need pairing.")

    open suspend fun start() {}
    open suspend fun stop() {}

    /**
     * Reads the current state of every device in [devices], keyed by device id. Devices that could not be read are
     * reported as unreachable.
     */
    open suspend fun refreshAll(devices: List<Device>): Map<String, DeviceState> {
        val out = mutableMapOf<String, DeviceState>()
        for (d in devices) {
            out[d.id] = try {
                d.state.merge(refresh(d) ?: DeviceState())
            } catch (e: Exception) {
                d.state.merge(DeviceState.unreachable)
            }
        }
        return out
    }

    fun makeDevice(
        externalId: String,
        name: String,
        kind: DeviceKind,
        capabilities: Set<Capability>? = null,
        props: Map<String, Any?> = emptyMap(),
        state: DeviceState = DeviceState(),
    ) = Device(
        id = Device.idFor(config.id, externalId),
        name = name,
        kind = kind,
        integrationId = config.id,
        externalId = externalId,
        capabilities = capabilities ?: defaultCapabilities(kind),
        props = toJsonElement(props.filterValues { it != null }) as JsonObject,
        state = DeviceState().merge(state),
    )

    // HTTP helpers for devices on the local network.

    suspend fun getJson(url: String, headers: Map<String, String> = emptyMap()): JsonElement? =
        decode(url, http.request("GET", url, headers))

    suspend fun sendJson(method: String, url: String, body: Any?, headers: Map<String, String> = emptyMap()): JsonElement? {
        val bytes = body?.let { toJsonElement(it).toString().toByteArray() }
        return decode(url, http.request(method, url, mapOf("Content-Type" to "application/json") + headers, bytes))
    }

    private fun decode(url: String, res: com.smartmenukj.core.net.HttpResponse): JsonElement? {
        val host = hostOf(url)
        if (res.status == 401 || res.status == 403) {
            throw IntegrationException("$host refused access (HTTP ${res.status}). Check the token or password.")
        }
        if (res.status >= 400) throw IntegrationException("$host answered HTTP ${res.status}.")
        val text = res.text
        if (text.isBlank()) return null
        return try {
            parseJson(text)
        } catch (e: Exception) {
            JsonPrimitive(text)
        }
    }

    companion object {
        fun hostOf(url: String) = url.substringAfter("://").substringBefore('/').substringAfter('@')
    }
}

/** Splits a "hosts" setting (one per line or comma separated) into hosts. */
fun parseHosts(raw: String): List<String> = raw.split(Regex("[\\s,;]+"))
    .map { it.trim().replace(Regex("^https?://"), "").replace(Regex("/+$"), "") }
    .filter { it.isNotEmpty() }
    .distinct()

/**
 * Base for devices that are each reached at their own LAN address (Shelly, Tasmota, WLED, ESPHome). Reads each host at
 * most once per refresh.
 */
abstract class HostListDriver(config: IntegrationConfig, http: Http) : IntegrationDriver(config, http) {
    val hosts: List<String> get() = parseHosts(config.setting("hosts"))

    abstract suspend fun probe(host: String): List<Device>

    /** Reads everything a host reports, shared by all devices on that host. */
    abstract suspend fun readHost(host: String): Any?

    abstract fun stateFrom(device: Device, hostData: Any?): DeviceState?

    override suspend fun discover(): List<Device> {
        if (hosts.isEmpty()) throw IntegrationException("Add at least one device address (for example 192.168.1.40).")
        val out = mutableListOf<Device>()
        val errors = mutableListOf<String>()
        for (host in hosts) {
            try {
                out += probe(host)
            } catch (e: Exception) {
                errors += "$host: ${e.message}"
            }
        }
        if (out.isEmpty() && errors.isNotEmpty()) throw IntegrationException("Could not reach ${errors.joinToString("; ")}")
        return out
    }

    override suspend fun refreshAll(devices: List<Device>): Map<String, DeviceState> {
        val cache = mutableMapOf<String, Result<Any?>>()
        val out = mutableMapOf<String, DeviceState>()
        for (d in devices) {
            val host = d.prop("host") ?: ""
            val data = cache.getOrPut(host) { runCatching { readHost(host) } }
            out[d.id] = data.fold(
                { d.state.merge(stateFrom(d, it) ?: DeviceState()) },
                { d.state.merge(DeviceState.unreachable) },
            )
        }
        return out
    }

    override suspend fun refresh(device: Device): DeviceState? = stateFrom(device, readHost(device.prop("host")!!))
}

/** URL-encodes a query. */
fun query(params: Map<String, String>): String =
    params.entries.joinToString("&") { "${enc(it.key)}=${enc(it.value)}" }

fun enc(s: String): String = java.net.URLEncoder.encode(s, "UTF-8").replace("+", "%20")
