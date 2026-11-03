package com.designxdevelop.luma.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.text.Normalizer
import kotlin.math.abs
import kotlin.math.round

// Ports of CommandValidation.swift, DreamView.swift, GoveeSceneLibrary.swift and DeviceReadings.swift.

object CommandValidation {
    private val ranges = mapOf("powerSwitch" to 0.0..1.0, "brightness" to 1.0..100.0, "colorRgb" to 0.0..16777215.0, "colorTemperatureK" to 1000.0..10000.0)

    fun validate(command: CapabilityCommand, device: LightDevice) {
        if (!device.supports(command.instance)) throw LumaException("${device.displayName} does not advertise ${command.instance}. Connect cloud to load all capabilities.")
        val cap = device.capabilities.firstOrNull { it.instance == command.instance }
        if (cap != null) {
            if (cap.type != command.type) throw LumaException("Capability type does not match this device.")
            try { validateValue(command.value, cap.parameters) } catch (e: LumaException) {
                // A scene removed in Govee Home (or a list that changed since this was saved).
                if (SceneKind.from(command.instance) != null) throw LumaException("${device.displayName} no longer lists this Govee scene. Reload its scenes, then choose it again.")
                throw e
            }
        } else {
            val expected = when (command.instance) {
                "powerSwitch" -> "devices.capabilities.on_off"
                "brightness" -> "devices.capabilities.range"
                else -> "devices.capabilities.color_setting"
            }
            if (command.type != expected) throw LumaException("Invalid LAN capability type.")
        }
        ranges[command.instance]?.let { range ->
            val n = command.value.num
            if (n == null || !n.isFinite() || round(n) != n || n !in range) throw LumaException("${command.instance} must be an integer in ${range.start.toInt()}…${range.endInclusive.toInt()}.")
        }
    }

    fun validateValue(value: JsonElement, parameters: JsonElement?) {
        if (parameters == null) return
        when (parameters["dataType"].str) {
            "INTEGER" -> {
                val n = value.num
                if (n == null || !n.isFinite() || round(n) != n) throw LumaException("Expected an integer value.")
                parameters["range"]["min"].num?.let { if (n < it) throw LumaException("Value is below the device minimum (${it.toInt()}).") }
                parameters["range"]["max"].num?.let { if (n > it) throw LumaException("Value exceeds the device maximum (${it.toInt()}).") }
            }
            "ENUM" -> {
                val options = parameters["options"].arr
                if (!options.isNullOrEmpty() && options.none { jsonEquals(it["value"], value) }) throw LumaException("Choose one of the device's advertised values.")
            }
            "STRUCT" -> {
                val obj = value as? JsonObject ?: throw LumaException("Expected a JSON object for this capability.")
                for (field in parameters["fields"].arr.orEmpty()) {
                    val name = field["fieldName"].str ?: continue
                    val supplied = obj[name]
                    if (supplied != null) validateValue(supplied, field)
                    else if (field["required"].bool == true) throw LumaException("Missing required field: $name.")
                }
            }
            "Array", "ARRAY" -> {
                val elements = value as? JsonArray ?: throw LumaException("Expected an array.")
                parameters["size"]["min"].num?.let { if (elements.size < it) throw LumaException("Array has fewer items than the device minimum.") }
                parameters["size"]["max"].num?.let { if (elements.size > it) throw LumaException("Array has more items than the device maximum.") }
                parameters["elementType"].str?.let { type ->
                    val p = buildMap { put("dataType", JsonPrimitive(type)); parameters["elementRange"]?.let { put("range", it) } }
                    elements.forEach { validateValue(it, JsonObject(p)) }
                }
                if (parameters["fieldName"].str == "segment") {
                    val seen = HashSet<Double>()
                    for (e in elements) {
                        val i = e.num
                        if (i == null || !i.isFinite() || round(i) != i) throw LumaException("Segment indexes must be integers.")
                        if (!seen.add(i)) throw LumaException("Segment indexes must be unique.")
                    }
                }
            }
        }
    }

    fun validateScene(scene: LightScene, devices: List<LightDevice>) {
        if (scene.name.isBlank()) throw LumaException("Give the scene a name.")
        if (scene.steps.isEmpty() || scene.steps.size > 200) throw LumaException("Scenes need 1–200 steps.")
        if (scene.steps.map { it.id }.toSet().size != scene.steps.size) throw LumaException("Each scene step needs a unique ID.")
        var delay = 0
        for (step in scene.steps) {
            if (step.delayMilliseconds !in 0..60000) throw LumaException("Step delays must be 0–60000 milliseconds.")
            delay += step.delayMilliseconds
            if (delay > 300000) throw LumaException("Total scene delay must be 5 minutes or less.")
            val device = devices.firstOrNull { it.id == step.deviceID } ?: throw LumaException("Scene references a light that is no longer connected.")
            validate(step.command, device)
        }
    }
}

/** Govee's cloud `dreamViewToggle`: starts or stops the DreamView group set up in Govee Home. */
object DreamView {
    const val INSTANCE = "dreamViewToggle"
    fun capability(device: LightDevice) = device.capabilities.firstOrNull { it.instance == INSTANCE }

    fun command(on: Boolean, device: LightDevice): CapabilityCommand {
        val cap = capability(device) ?: throw LumaException("${device.displayName} does not advertise DreamView.")
        val named = cap.parameters["options"].arr?.firstOrNull { it["name"].str?.lowercase() == if (on) "on" else "off" }?.get("value")
        return CapabilityCommand(cap.type, INSTANCE, named ?: JsonPrimitive(if (on) 1 else 0)).also { CommandValidation.validate(it, device) }
    }
}

enum class SceneKind(val instance: String, val title: String) {
    BuiltIn("lightScene", "Built-in"), Diy("diyScene", "DIY"), Snapshot("snapshot", "Snapshot");
    companion object { fun from(instance: String) = entries.firstOrNull { it.instance == instance } }
}

/** One entry from a light's Govee scene lists, exactly as Govee's public API listed it. */
data class SceneOption(val kind: SceneKind, val name: String, val type: String, val value: JsonElement, val index: Int) {
    val id: String get() = "${kind.instance}|$index|$name"
    val command: CapabilityCommand get() = CapabilityCommand(type, kind.instance, value)
}

object SceneLibrary {
    fun options(device: LightDevice): List<SceneOption> = buildList {
        for (kind in SceneKind.entries) {
            val cap = device.capabilities.firstOrNull { it.instance == kind.instance } ?: continue
            val seen = HashMap<String, MutableList<JsonElement>>()
            cap.parameters["options"].arr.orEmpty().forEachIndexed { index, option ->
                val value = option["value"] ?: return@forEachIndexed
                val name = option["name"].str?.trim().orEmpty().ifEmpty { "${kind.title} ${index + 1}" }
                val values = seen.getOrPut(name) { mutableListOf() }
                if (values.any { jsonEquals(it, value) }) return@forEachIndexed
                values += value
                add(SceneOption(kind, name, cap.type, value, index))
            }
        }
    }

    fun advertisesScenes(device: LightDevice) = device.capabilities.any { SceneKind.from(it.instance) != null }

    /** Case- and accent-insensitive name filter; an empty query keeps everything. */
    fun filter(options: List<SceneOption>, query: String, kind: SceneKind? = null): List<SceneOption> {
        val q = fold(query.trim())
        return options.filter { (kind == null || it.kind == kind) && (q.isEmpty() || fold(it.name).contains(q)) }
    }

    private fun fold(s: String) = Normalizer.normalize(s, Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").lowercase()
}

/** Readable values from `device/state` for capabilities with no dedicated control. */
object Readings {
    data class Reading(val instance: String, val label: String, val text: String)

    fun isLight(type: String?) = type == null || type == "devices.types.light"

    private val skipped = setOf("online", "powerSwitch", "brightness", "colorRgb", "colorTemperatureK", DreamView.INSTANCE, "lightScene", "diyScene", "snapshot")
    private val labels = mapOf("sensorTemperature" to "Temperature", "sensorHumidity" to "Humidity", "airQuality" to "Air quality", "filterLifeTime" to "Filter life",
        "workMode" to "Mode", "gearMode" to "Gear", "fanSpeed" to "Fan speed", "targetTemperature" to "Target temperature")
    private val units = mapOf("unit.percent" to "%", "unit.temperature.celsius" to " °C", "unit.temperature.fahrenheit" to " °F", "unit.kelvin" to " K")

    fun parse(state: JsonElement, capabilities: List<Capability>): List<Reading> {
        val rows = state["capabilities"].arr ?: state.arr ?: return emptyList()
        val out = mutableListOf<Reading>()
        for (row in rows) {
            val instance = row["instance"].str ?: continue
            if (instance.length > 64 || instance in skipped) continue
            val value = row["state"]["value"] ?: continue
            val text = text(value, capabilities.firstOrNull { it.instance == instance }) ?: continue
            out += Reading(instance, label(instance), text)
            if (out.size == 32) break
        }
        return out
    }

    fun label(instance: String): String = labels[instance]
        ?: instance.replace(Regex("([a-z0-9])([A-Z])"), "$1 $2").lowercase().replaceFirstChar { it.uppercase() }

    fun text(value: JsonElement, capability: Capability?): String? {
        capability?.parameters["options"].arr?.firstOrNull { jsonEquals(it["value"], value) }?.get("name").str?.let { return it.take(80) }
        return when {
            value is JsonPrimitive && value.isString -> value.content.takeIf { it.isNotBlank() }?.take(80)
            value.bool != null -> if (value.bool == true) "On" else "Off"
            value.num != null -> {
                val n = value.num!!
                if (!n.isFinite()) return null
                val unit = capability?.parameters["unit"].str?.let { units[it] ?: if (it.startsWith("unit.")) " " + it.drop(5).replace(".", " ") else "" } ?: ""
                val r = if (abs(n) < 1e15) round(n * 100) / 100 else n
                (if (r == round(r)) String.format(java.util.Locale.ROOT, "%.0f", r) else r.toString()) + unit
            }
            value is JsonObject && value.isEmpty() -> null
            value is JsonArray && value.isEmpty() -> null
            value is JsonObject || value is JsonArray -> value.toString().let { if (it.length > 120) it.take(119) + "…" else it }
            else -> null
        }
    }
}
