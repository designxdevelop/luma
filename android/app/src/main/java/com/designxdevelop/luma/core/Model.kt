package com.designxdevelop.luma.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import java.time.ZonedDateTime
import java.util.UUID

// Port of Sources/LumaCore/Models.swift. Wire names match the Swift and TypeScript
// clients so backups and scenes stay interchangeable.

class LumaException(message: String) : Exception(message)

/** Omits nulls and tolerates fields other clients add (the desktop app writes `icon`). */
val LumaJson = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true }

fun newId(): String = UUID.randomUUID().toString().uppercase()

// JSON helpers mirroring JSONValue's accessors.
operator fun JsonElement?.get(key: String): JsonElement? = (this as? JsonObject)?.get(key)
val JsonElement?.str: String? get() = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
val JsonElement?.num: Double? get() = (this as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull
val JsonElement?.bool: Boolean? get() = (this as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
val JsonElement?.arr: List<JsonElement>? get() = this as? JsonArray

/** Value equality as Swift's JSONValue sees it: `1` and `1.0` are the same number. */
fun jsonEquals(a: JsonElement?, b: JsonElement?): Boolean = when {
    a == null || b == null -> a == b
    a is JsonNull || b is JsonNull -> a is JsonNull && b is JsonNull
    a is JsonPrimitive && b is JsonPrimitive -> when {
        a.isString || b.isString -> a.isString && b.isString && a.content == b.content
        a.num != null && b.num != null -> a.num == b.num
        else -> a.content == b.content
    }
    a is JsonArray && b is JsonArray -> a.size == b.size && a.indices.all { jsonEquals(a[it], b[it]) }
    a is JsonObject && b is JsonObject -> a.keys == b.keys && a.keys.all { jsonEquals(a[it], b[it]) }
    else -> false
}

@Serializable
data class Capability(val type: String, val instance: String, val parameters: JsonElement? = null) {
    val id: String get() = "$type:$instance"
}

@Serializable
data class LightDevice(
    val id: String,
    val sku: String,
    val name: String,
    /** User-set label that survives cloud and LAN refreshes; `name` stays the device's own. */
    val customName: String? = null,
    /** Govee's type for appliances and sensors; null for lights. */
    val deviceType: String? = null,
    val room: String = "Unassigned",
    val ip: String? = null,
    val capabilities: List<Capability> = emptyList(),
    val power: Boolean? = null,
    val brightness: Int? = null,
    val rgb: Int? = null,
    val colorTemperature: Int? = null,
    /** Colors Luma last sent beyond the single reported one (painted segments, a known scene), in strip order. Display only. */
    val palette: List<Int>? = null,
    val dreamView: Boolean? = null,
    val online: Boolean? = null,
    /** Epoch milliseconds (Android-local storage only). */
    val lastSeen: Long? = null,
    val isDemo: Boolean = false,
) {
    val displayName: String get() = customName?.takeIf { it.isNotBlank() } ?: name
    val isLight: Boolean get() = Readings.isLight(deviceType)
    fun supports(instance: String): Boolean =
        (ip != null && instance in LAN_INSTANCES) || capabilities.any { it.instance == instance }

    companion object { val LAN_INSTANCES = setOf("powerSwitch", "brightness", "colorRgb", "colorTemperatureK") }
}

@Serializable
data class CapabilityCommand(val type: String, val instance: String, val value: JsonElement) {
    companion object {
        fun power(on: Boolean) = CapabilityCommand("devices.capabilities.on_off", "powerSwitch", JsonPrimitive(if (on) 1 else 0))
        fun brightness(value: Int) = CapabilityCommand("devices.capabilities.range", "brightness", JsonPrimitive(value))
        fun rgb(value: Int) = CapabilityCommand("devices.capabilities.color_setting", "colorRgb", JsonPrimitive(value))
        fun kelvin(value: Int) = CapabilityCommand("devices.capabilities.color_setting", "colorTemperatureK", JsonPrimitive(value))
    }
}

@Serializable
data class SceneStep(val id: String = newId(), val deviceID: String, val command: CapabilityCommand, val delayMilliseconds: Int = 0)

@Serializable
data class LightScene(val id: String = newId(), val name: String, val symbol: String = "sparkles", val steps: List<SceneStep>)

@Serializable
data class SceneSchedule(
    val id: String = newId(),
    val sceneID: String,
    val hour: Int,
    val minute: Int,
    /** Apple numbering, shared with every client: 1 = Sunday … 7 = Saturday. */
    val weekdays: List<Int> = (1..7).toList(),
    val enabled: Boolean = true,
    /** ISO-8601 instant; runs before it are skipped (Pause). */
    val pausedUntil: String? = null,
    val lastRunMinute: String? = null,
) {
    fun shouldRun(at: ZonedDateTime): Boolean =
        enabled && at.hour == hour && at.minute == minute && appleWeekday(at) in weekdays &&
            lastRunMinute != minuteKey(at) &&
            !paused(at)

    private fun paused(at: ZonedDateTime) = pausedUntil?.let { runCatching { java.time.Instant.parse(it) }.getOrNull()?.isAfter(at.toInstant()) } ?: false

    /** The first run strictly after [after], or null when disabled. A time skipped by DST moves forward, as java.time does. */
    fun next(after: ZonedDateTime): ZonedDateTime? {
        if (!enabled || weekdays.isEmpty()) return null
        for (day in 0L..8L) {
            val at = after.toLocalDate().plusDays(day).atTime(hour, minute).atZone(after.zone)
            if (at.isAfter(after) && appleWeekday(at) in weekdays && !paused(at)) return at
        }
        // Paused for more than a week: look again from the end of the pause.
        return pausedUntil?.let { runCatching { java.time.Instant.parse(it) }.getOrNull() }?.let { next(it.atZone(after.zone)) }
    }

    companion object {
        /** java.time counts Monday = 1 … Sunday = 7; Apple counts Sunday = 1 … Saturday = 7. */
        fun appleWeekday(at: ZonedDateTime): Int = at.dayOfWeek.value % 7 + 1
        /** Same unpadded shape as Swift's `minuteKey`. */
        fun minuteKey(at: ZonedDateTime): String = "${at.year}-${at.monthValue}-${at.dayOfMonth}-${at.hour}-${at.minute}"
    }
}

/** Everything Luma keeps on this device (`home.json`). Secrets live in [com.designxdevelop.luma.KeyStore]. */
@Serializable
data class SavedHome(
    val devices: List<LightDevice> = emptyList(),
    val scenes: List<LightScene> = emptyList(),
    val schedules: List<SceneSchedule> = emptyList(),
)

/** A light's pin; coordinates are fractions of the image itself, independent of zoom or screen size (FloorPlan.swift). */
@Serializable
data class FloorPlanPin(val deviceID: String, val x: Double, val y: Double) {
    init { if (deviceID.isEmpty() || x !in 0.0..1.0 || y !in 0.0..1.0) throw LumaException("Choose a light and a position inside the floor plan.") }
}

@Serializable
data class FloorPlan(val id: String = newId(), val name: String, val pins: List<FloorPlanPin> = emptyList()) {
    companion object {
        /** A light has one pin: placing it removes its pin from every other floor. */
        fun place(plans: List<FloorPlan>, deviceID: String, planID: String, x: Double, y: Double): List<FloorPlan> {
            val pin = FloorPlanPin(deviceID, x.coerceIn(0.0, 1.0), y.coerceIn(0.0, 1.0))
            return plans.map { p -> p.copy(pins = p.pins.filter { it.deviceID != deviceID } + listOfNotNull(pin.takeIf { p.id == planID })) }
        }
    }
}
