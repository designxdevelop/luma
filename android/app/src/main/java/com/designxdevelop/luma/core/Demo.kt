package com.designxdevelop.luma.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** The sample home from `HomeStore.loadDemo()` on iOS: same IDs, names, colors and scene lists. */
object Demo {
    private val caps = listOf(
        Capability("devices.capabilities.on_off", "powerSwitch"),
        Capability("devices.capabilities.range", "brightness"),
        Capability("devices.capabilities.color_setting", "colorRgb"),
        Capability("devices.capabilities.color_setting", "colorTemperatureK"),
    )
    private val dreamView = Capability("devices.capabilities.toggle", DreamView.INSTANCE, buildJsonObject {
        put("dataType", "ENUM")
        put("options", JsonArray(listOf(buildJsonObject { put("name", "on"); put("value", 1) }, buildJsonObject { put("name", "off"); put("value", 0) })))
    })
    /** Govee's documented segment schema, so the demo strip shows the segment painter. */
    private val segments = Capability("devices.capabilities.segment_color_setting", "segmentedColorRgb", LumaJson.parseToJsonElement(
        """{"dataType":"STRUCT","fields":[{"fieldName":"segment","size":{"min":1,"max":15},"dataType":"Array","elementRange":{"min":0,"max":14},"elementType":"INTEGER","required":true},{"fieldName":"rgb","dataType":"INTEGER","range":{"min":0,"max":16777215},"required":true}]}"""))
    private val builtIn = listOf("Sunrise", "Sunset", "Aurora", "Candlelight", "Ocean", "Forest", "Fireplace", "Rainbow", "Starry Sky", "Reading", "Movie", "Romantic")

    private fun sceneList(instance: String, names: List<String>, base: Int) = Capability("devices.capabilities.dynamic_scene", instance, buildJsonObject {
        put("dataType", "ENUM")
        put("options", JsonArray(names.mapIndexed { i, name ->
            buildJsonObject {
                put("name", name)
                put("value", if (instance == "lightScene") buildJsonObject { put("id", base + i); put("paramId", base + 100 + i) } else JsonPrimitive(base + i))
            }
        }))
    })

    fun home(): SavedHome {
        val devices = listOf(
            LightDevice("demo-floor", "Demo lamp", "Corner glow", room = "Living room", capabilities = caps + sceneList("lightScene", builtIn, 1000), power = true, brightness = 65, rgb = 0xFFB66A, online = true, isDemo = true),
            LightDevice("demo-strip", "Demo strip", "Behind the sofa", room = "Living room", capabilities = caps + sceneList("lightScene", builtIn, 1000) + sceneList("diyScene", listOf("Party Pulse", "Slow Fade"), 5000) + segments, power = true, brightness = 42, rgb = 0xCA8BFF, online = true, isDemo = true),
            LightDevice("demo-desk", "Demo light bars", "Desk lights", room = "Office", capabilities = caps, power = true, brightness = 80, rgb = 0x89CBD2, online = true, isDemo = true),
            LightDevice("demo-bed", "Demo bulb", "Bedside", room = "Bedroom", capabilities = caps + sceneList("lightScene", builtIn.take(6), 1000), power = false, brightness = 25, rgb = 0xFFC58B, online = true, isDemo = true),
            LightDevice("demo-tv", "Demo TV backlight", "TV backlight", room = "Living room", capabilities = caps + dreamView, power = true, brightness = 70, rgb = 0x7FA8FF, online = true, isDemo = true, dreamView = false),
        )
        val scenes = listOf(
            LightScene(name = "Evening unwind", symbol = "moon.stars", steps = devices.take(2).flatMap {
                listOf(SceneStep(deviceID = it.id, command = CapabilityCommand.power(true)), SceneStep(deviceID = it.id, command = CapabilityCommand.brightness(35)), SceneStep(deviceID = it.id, command = CapabilityCommand.rgb(0xFFAE64)))
            }),
            LightScene(name = "Focus time", symbol = "sun.max", steps = listOf(SceneStep(deviceID = "demo-desk", command = CapabilityCommand.power(true)), SceneStep(deviceID = "demo-desk", command = CapabilityCommand.kelvin(4500)))),
        )
        return SavedHome(devices, scenes)
    }
}
