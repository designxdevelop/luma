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

/**
 * Model for painting `segmentedColorRgb` / `segmentedBrightness` (port of SegmentPaint.swift):
 * reads the advertised STRUCT schema and turns a painting into the fewest validated commands.
 */
data class SegmentPaint(val type: String, val instance: String, val indexes: List<Int>, val valueField: String, val valueRange: IntRange, val perCommand: Int?) {
    val isColor: Boolean get() = valueField == "rgb"

    /** One command per distinct value, segments ascending, split at the per-command limit, ordered by first segment. */
    fun commands(paint: Map<Int, Int>): List<CapabilityCommand> {
        val allowed = indexes.toSet()
        val groups = HashMap<Int, MutableList<Int>>()
        for ((index, value) in paint) {
            if (index !in allowed) throw LumaException("Segment $index isn't on this light.")
            if (value !in valueRange) throw LumaException("$valueField must be ${valueRange.first}…${valueRange.last}.")
            groups.getOrPut(value) { mutableListOf() } += index
        }
        return groups.flatMap { (value, members) ->
            members.sorted().chunked(perCommand ?: members.size).map { part ->
                part.first() to CapabilityCommand(type, instance, kotlinx.serialization.json.buildJsonObject {
                    put("segment", JsonArray(part.map(::JsonPrimitive))); put(valueField, JsonPrimitive(value))
                })
            }
        }.sortedBy { it.first }.map { it.second }
    }

    companion object {
        val INSTANCES = listOf("segmentedColorRgb", "segmentedBrightness")
        private const val MAX_SEGMENTS = 256

        fun all(device: LightDevice) = INSTANCES.mapNotNull { i -> of(device.capabilities.firstOrNull { it.instance == i }) }

        /** Null when the capability isn't a paintable segment schema (including a required field the painter can't fill). */
        fun of(cap: Capability?): SegmentPaint? {
            val p = cap?.parameters ?: return null
            if (cap.instance !in INSTANCES || p["dataType"].str?.uppercase() != "STRUCT") return null
            val fields = p["fields"].arr ?: return null
            val segment = fields.firstOrNull { it["fieldName"].str == "segment" } ?: return null
            val value = fields.firstOrNull { it["fieldName"].str.let { n -> n != null && n != "segment" } && it["dataType"].str?.uppercase() == "INTEGER" } ?: return null
            if (fields.any { it["required"].bool == true && it !== segment && it !== value }) return null
            val lo = int(segment["elementRange"]["min"])
            val hi = int(segment["elementRange"]["max"])
            val indexes = if (lo != null && hi != null && lo >= 0 && hi >= lo && hi - lo < MAX_SEGMENTS) (lo..hi).toList()
                else segment["options"].arr.orEmpty().mapNotNull { int(it["value"]) }.distinct().sorted().take(MAX_SEGMENTS)
            val field = value["fieldName"].str ?: return null
            if (indexes.isEmpty()) return null
            val fallback = if (field == "rgb") 0..0xFFFFFF else 0..100
            val min = int(value["range"]["min"]) ?: fallback.first
            val max = int(value["range"]["max"]) ?: fallback.last
            return SegmentPaint(cap.type, cap.instance, indexes, field, if (min <= max) min..max else fallback, int(segment["size"]["max"])?.takeIf { it > 0 })
        }

        private fun int(v: JsonElement?): Int? = v.num?.takeIf { it.isFinite() && round(it) == it && abs(it) <= Int.MAX_VALUE }?.toInt()
    }
}

// Port of LightLook.swift. Govee reports one color per light, never segment or scene
// colors, so Luma remembers what it last sent to draw the gradient the light is showing.
// ponytail: only Luma's own writes update it; clear on telemetry if stale palettes bite.

/** This light with `palette` updated for a command Luma is sending to it. */
fun LightDevice.notingLook(c: CapabilityCommand): LightDevice = when (c.instance) {
    "colorRgb", "colorTemperatureK" -> copy(palette = null)
    "segmentedColorRgb" -> {
        val schema = SegmentPaint.all(this).firstOrNull { it.instance == c.instance }
        val color = schema?.let { c.value[it.valueField].num?.toInt() }
        val painted = c.value["segment"].arr?.mapNotNull { it.num?.toInt() }?.toSet()
        if (schema == null || color == null || painted == null) this
        else copy(palette = (palette?.takeIf { it.size == schema.indexes.size } ?: List(schema.indexes.size) { rgb ?: 0xFFC98F })
            .mapIndexed { slot, old -> if (schema.indexes[slot] in painted) color else old })
    }
    "lightScene", "diyScene", "snapshot" ->
        copy(palette = SceneLibrary.options(this).firstOrNull { it.kind.instance == c.instance && jsonEquals(it.value, c.value) }?.name?.let(ScenePalette::colors))
    else -> this
}

/** Best-guess colors for a Govee scene from its name; null when the name says nothing. */
object ScenePalette {
    private val table = listOf(
        listOf("sunrise", "dawn", "morning") to listOf(0xFF7A3D, 0xFFB36B, 0xFFE2A8),
        listOf("sunset", "dusk", "twilight") to listOf(0xFF5E62, 0xFF9966, 0xB24592),
        listOf("aurora", "northern") to listOf(0x00E5A0, 0x3FA9F5, 0x8A5CF6),
        listOf("candle", "fire", "flame", "warm", "cozy") to listOf(0xFF4E1F, 0xFF8A1F, 0xFFC46B),
        listOf("ocean", "sea", "wave", "water", "rain", "lake") to listOf(0x0077FF, 0x00C6D7, 0x6FE3E1),
        listOf("forest", "jungle", "leaf", "spring", "grass", "nature") to listOf(0x0B6E4F, 0x1FA34A, 0x9BE15D),
        listOf("rainbow", "party", "disco", "colorful", "carnival", "pulse") to listOf(0xFF3B30, 0xFFD60A, 0x34C759, 0x0A84FF, 0xAF52DE),
        listOf("star", "night", "galaxy", "space", "universe", "moon") to listOf(0x1B2A6B, 0x6A5ACD, 0xC6B5FF),
        listOf("romantic", "love", "rose", "valentine", "sakura", "cherry") to listOf(0xFF2D75, 0xFF7EB3, 0xB5179E),
        listOf("movie", "cinema", "film", "fade") to listOf(0x3A1C71, 0xD76D77, 0xFFAF7B),
        listOf("snow", "ice", "winter", "frost") to listOf(0x5AA9E6, 0xA8E0FF, 0xEAF6FF),
        listOf("christmas", "xmas") to listOf(0xD62828, 0xF6F1D1, 0x2A9D3F),
        listOf("halloween", "pumpkin") to listOf(0xFF7A00, 0x6A0DAD, 0x2B1055),
        listOf("reading", "work", "study", "focus") to listOf(0xFFE9C4, 0xFFF6E5),
    )
    fun colors(name: String): List<Int>? = name.lowercase().let { n -> table.firstOrNull { (words, _) -> words.any { it in n } }?.second }
}
