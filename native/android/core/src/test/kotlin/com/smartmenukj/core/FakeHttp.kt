package com.smartmenukj.core

import com.smartmenukj.core.net.Http
import com.smartmenukj.core.net.HttpResponse

/** Answers requests from a table of "METHOD url" to (status, body), and remembers what was asked. */
class FakeHttp(private val routes: MutableMap<String, Pair<Int, String>> = mutableMapOf()) : Http {
    val calls = mutableListOf<String>()

    fun on(method: String, url: String, body: String, status: Int = 200) { routes["$method $url"] = status to body }

    override suspend fun request(method: String, url: String, headers: Map<String, String>, body: ByteArray?, timeoutMs: Int): HttpResponse {
        calls += "$method $url" + (body?.let { " " + it.toString(Charsets.UTF_8) } ?: "")
        val r = routes["$method $url"] ?: (404 to "")
        return HttpResponse(r.first, emptyMap(), r.second.toByteArray())
    }

    override suspend fun readLines(url: String, headers: Map<String, String>, forMs: Long, onLine: (String) -> Unit): Int {
        calls += "STREAM $url"
        val r = routes["STREAM $url"] ?: return 404
        r.second.lines().forEach(onLine)
        return r.first
    }
}
