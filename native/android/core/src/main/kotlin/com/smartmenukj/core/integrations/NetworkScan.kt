package com.smartmenukj.core.integrations

import com.smartmenukj.core.json.*
import com.smartmenukj.core.net.Http
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import java.net.InetSocketAddress
import java.net.Socket

/** Something found on the local network, and which integration can use it. */
data class FoundService(val name: String, val host: String, val port: Int, val integrationType: String) {
    /** Address to store in an integration's settings. */
    val address: String
        get() = when (integrationType) {
            "homeassistant" -> "http://$host:$port"
            "hue", "esphome" -> host
            else -> if (port == 80 || port == 0) host else "$host:$port"
        }

    val key get() = "$integrationType|$host"
}

/**
 * Finds devices by asking every address on the home network what it is, over plain HTTP: Shelly, WLED, Tasmota, Hue,
 * ESPHome and Home Assistant all answer in their own way. Also asks the free Hue discovery service. mDNS is added by
 * the app, which has the phone's own service browser.
 */
class NetworkScanner(private val http: Http, private val parallel: Int = 48) {
    /** Maps an mDNS service type to the integration that uses it. */
    fun typeForService(service: String, name: String): String? = when (service.trim('.').removeSuffix(".local")) {
        "_hue._tcp" -> "hue"
        "_shelly._tcp" -> "shelly"
        "_wled._tcp" -> "wled"
        "_esphomelib._tcp" -> "esphome"
        "_home-assistant._tcp" -> "homeassistant"
        "_http._tcp" -> name.lowercase().let {
            when {
                it.startsWith("shelly") -> "shelly"
                it.contains("tasmota") -> "tasmota"
                it.startsWith("wled") -> "wled"
                else -> null
            }
        }
        else -> null
    }

    suspend fun hueCloud(): List<FoundService> = try {
        val res = http.request("GET", "https://discovery.meethue.com/", timeoutMs = 4000)
        (parseJson(res.text) as? JsonArray)?.mapNotNull { e ->
            e.asObj()?.string("internalipaddress")?.let { FoundService("Hue bridge", it, 80, "hue") }
        } ?: emptyList()
    } catch (e: Exception) {
        emptyList()
    }

    /** Knocks on each of [hosts] and reports what answers, as soon as it is known. */
    suspend fun sweep(hosts: List<String>, onFound: (FoundService) -> Unit) = coroutineScope {
        val gate = Semaphore(parallel)
        hosts.map { host ->
            async {
                gate.withPermit {
                    if (open(host, 80)) identify(host)?.let(onFound)
                    if (open(host, 8123)) identifyHomeAssistant(host)?.let(onFound)
                }
            }
        }.awaitAll()
    }

    private suspend fun open(host: String, port: Int): Boolean = withContext(Dispatchers.IO) {
        try {
            Socket().use { it.connect(InetSocketAddress(host, port), 350) }
            true
        } catch (e: Exception) {
            false
        }
    }

    private suspend fun get(url: String): String? = try {
        val r = http.request("GET", url, timeoutMs = 1500)
        if (r.status in 200..299) r.text else null
    } catch (e: Exception) {
        null
    }

    /** Works out what answers HTTP on [host], or null when it is nothing this app drives. */
    suspend fun identify(host: String): FoundService? {
        get("http://$host/shelly")?.let { t ->
            runCatching { parseJson(t).asObj() }.getOrNull()?.let { j ->
                if (j.containsKey("mac") || j.containsKey("gen") || j.containsKey("type")) {
                    return FoundService(j.string("name") ?: j.string("type") ?: j.string("model") ?: "Shelly", host, 80, "shelly")
                }
            }
        }
        get("http://$host/json/info")?.let { t ->
            runCatching { parseJson(t).asObj() }.getOrNull()?.let { j ->
                if (j.containsKey("leds")) return FoundService(j.string("name") ?: "WLED", host, 80, "wled")
            }
        }
        get("http://$host/api/config")?.let { t ->
            runCatching { parseJson(t).asObj() }.getOrNull()?.let { j ->
                if (j.containsKey("bridgeid")) return FoundService(j.string("name") ?: "Hue bridge", host, 80, "hue")
            }
        }
        get("http://$host/cm?cmnd=Status")?.let { t ->
            runCatching { parseJson(t).asObj() }.getOrNull()?.obj("Status")?.let { s ->
                val name = s.string("DeviceName") ?: s.list("FriendlyName")?.firstOrNull()?.textOrNull() ?: "Tasmota"
                return FoundService(name, host, 80, "tasmota")
            }
        }
        get("http://$host/")?.let { t ->
            if (t.contains("ESPHome", ignoreCase = true) || t.contains("esp-app")) {
                val title = Regex("<title>([^<]*)</title>").find(t)?.groupValues?.get(1)?.trim()
                return FoundService(title?.ifEmpty { null } ?: host, host, 80, "esphome")
            }
        }
        return null
    }

    private suspend fun identifyHomeAssistant(host: String): FoundService? = try {
        // The API answers 401 without a token, and its front page says Home Assistant.
        val r = http.request("GET", "http://$host:8123/api/", timeoutMs = 1500)
        if (r.status == 401 || r.status == 200) FoundService("Home Assistant", host, 8123, "homeassistant") else null
    } catch (e: Exception) {
        null
    }

    companion object {
        /** Every other address in the /24 of [ip] (an IPv4 address of this phone). */
        fun subnetOf(ip: String): List<String> {
            val parts = ip.split('.')
            if (parts.size != 4) return emptyList()
            val base = parts.take(3).joinToString(".")
            return (1..254).map { "$base.$it" }.filter { it != ip }
        }
    }
}
