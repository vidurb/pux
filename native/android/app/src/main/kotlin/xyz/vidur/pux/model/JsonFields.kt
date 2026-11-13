package xyz.vidur.pux.model

import org.json.JSONObject

/** Reads a string field, treating JSON null and non-strings as absent (Android org.json quirk). */
fun JSONObject.optNullableString(name: String): String? {
    if (!has(name) || isNull(name)) return null
    val value = get(name)
    if (value == JSONObject.NULL) return null
    if (value !is String) return null
    return value
}

fun JSONObject.optStringOrDefault(name: String, default: String): String {
    return optNullableString(name)?.takeIf { it.isNotEmpty() } ?: default
}

fun JSONObject.optBooleanWhenPresent(name: String): Boolean? {
    if (!has(name) || isNull(name)) return null
    return optBoolean(name)
}
