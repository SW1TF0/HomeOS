package com.smartmenukj.core.json

import kotlinx.serialization.json.*

/** Small helpers for reading loosely typed JSON from devices and saved homes, where any field can be missing. */

val json = Json { ignoreUnknownKeys = true; isLenient = true; prettyPrint = false }
val prettyJson = Json { prettyPrint = true; prettyPrintIndent = " " }

fun parseJson(text: String): JsonElement = json.parseToJsonElement(text)

fun JsonElement?.asObj(): JsonObject? = this as? JsonObject
fun JsonElement?.asList(): JsonArray? = this as? JsonArray

private fun JsonElement?.prim(): JsonPrimitive? = (this as? JsonPrimitive)?.takeIf { it !is JsonNull }

/** The value as text: strings as they are, numbers and booleans printed, null as "null". */
fun JsonElement?.text(): String = when (val p = this) {
    null, JsonNull -> "null"
    is JsonPrimitive -> p.content
    else -> p.toString()
}

fun JsonElement?.textOrNull(): String? = prim()?.content

fun JsonElement?.number(): Double? = prim()?.let { if (it.isString) it.content.toDoubleOrNull() else it.doubleOrNull }
fun JsonElement?.bool(): Boolean? = prim()?.let { if (it.isString) it.content.toBooleanStrictOrNull() else it.booleanOrNull }
fun JsonElement?.isNumber(): Boolean = prim()?.let { !it.isString && it.doubleOrNull != null } ?: false

fun JsonObject.string(key: String): String? = this[key].prim()?.let { if (it.isString) it.content else it.content }
fun JsonObject.double(key: String): Double? = this[key].number()
fun JsonObject.int(key: String): Int? = this[key].number()?.let { Math.round(it).toInt() }
fun JsonObject.bool(key: String): Boolean? = this[key].prim()?.booleanOrNull
fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject
fun JsonObject.list(key: String): JsonArray? = this[key] as? JsonArray

fun jsonArrayOf(items: List<JsonElement>) = JsonArray(items)

/** Turns plain Kotlin values (maps, lists, strings, numbers, booleans, null) into JSON. */
fun toJsonElement(v: Any?): JsonElement = when (v) {
    null -> JsonNull
    is JsonElement -> v
    is String -> JsonPrimitive(v)
    is Number -> JsonPrimitive(v)
    is Boolean -> JsonPrimitive(v)
    is Map<*, *> -> JsonObject(v.entries.associate { "${it.key}" to toJsonElement(it.value) })
    is Iterable<*> -> JsonArray(v.map { toJsonElement(it) })
    is Array<*> -> JsonArray(v.map { toJsonElement(it) })
    is IntArray -> JsonArray(v.map { JsonPrimitive(it) })
    else -> JsonPrimitive(v.toString())
}

fun jsonObjectOf(vararg pairs: Pair<String, Any?>): JsonObject =
    JsonObject(pairs.filter { it.second != null }.associate { it.first to toJsonElement(it.second) })

/** This object with [pairs] added or replaced. A null value removes the key. */
fun JsonObject.with(vararg pairs: Pair<String, Any?>): JsonObject {
    val m = toMutableMap()
    for ((k, v) in pairs) if (v == null) m.remove(k) else m[k] = toJsonElement(v)
    return JsonObject(m)
}

operator fun JsonObject.plus(other: JsonObject): JsonObject = JsonObject(this.toMutableMap().apply { putAll(other) })
