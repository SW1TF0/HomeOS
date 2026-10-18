package com.smartmenukj.core.net

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

class HttpResponse(val status: Int, val headers: Map<String, String>, val body: ByteArray) {
    val text: String get() = body.toString(Charsets.UTF_8)
    fun header(name: String): String? = headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value
}

/** The app's way onto the network, so tests can answer for devices. */
interface Http {
    suspend fun request(
        method: String,
        url: String,
        headers: Map<String, String> = emptyMap(),
        body: ByteArray? = null,
        timeoutMs: Int = TIMEOUT_MS,
    ): HttpResponse

    /** Reads the lines of a stream (server-sent events) for at most [forMs], then hangs up. */
    suspend fun readLines(url: String, headers: Map<String, String> = emptyMap(), forMs: Long, onLine: (String) -> Unit): Int

    companion object {
        /** Devices on the home network answer quickly, or not at all. */
        const val TIMEOUT_MS = 6000
    }
}

/** Plain java.net, which works the same on Android and on a computer. */
class UrlHttp : Http {
    override suspend fun request(
        method: String,
        url: String,
        headers: Map<String, String>,
        body: ByteArray?,
        timeoutMs: Int,
    ): HttpResponse = withContext(Dispatchers.IO) {
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.connectTimeout = timeoutMs
            c.readTimeout = timeoutMs
            c.instanceFollowRedirects = true
            c.requestMethod = method
            headers.forEach { (k, v) -> c.setRequestProperty(k, v) }
            if (body != null) {
                c.doOutput = true
                c.setFixedLengthStreamingMode(body.size)
                c.outputStream.use { it.write(body) }
            } else if (method == "POST" || method == "PUT") {
                c.doOutput = true
                c.setFixedLengthStreamingMode(0)
                c.outputStream.close()
            }
            val status = c.responseCode
            val stream = if (status >= 400) c.errorStream else c.inputStream
            val bytes = stream?.use { it.readBytes() } ?: ByteArray(0)
            val h = c.headerFields.filterKeys { it != null }.mapValues { it.value.joinToString(", ") }
            HttpResponse(status, h, bytes)
        } finally {
            c.disconnect()
        }
    }

    override suspend fun readLines(url: String, headers: Map<String, String>, forMs: Long, onLine: (String) -> Unit): Int =
        withContext(Dispatchers.IO) {
            val c = URL(url).openConnection() as HttpURLConnection
            val until = System.currentTimeMillis() + forMs
            try {
                c.connectTimeout = Http.TIMEOUT_MS
                c.readTimeout = forMs.toInt().coerceAtLeast(500)
                headers.forEach { (k, v) -> c.setRequestProperty(k, v) }
                val status = c.responseCode
                if (status != 200) return@withContext status
                val reader = BufferedReader(InputStreamReader(c.inputStream, Charsets.UTF_8))
                try {
                    while (System.currentTimeMillis() < until) {
                        val line = reader.readLine() ?: break
                        onLine(line)
                    }
                } catch (_: java.net.SocketTimeoutException) {
                    // The device stopped talking; what came so far is enough.
                }
                status
            } finally {
                c.disconnect()
            }
        }
}
