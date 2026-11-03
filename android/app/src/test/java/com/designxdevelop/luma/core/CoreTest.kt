package com.designxdevelop.luma.core

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.net.SocketTimeoutException
import java.time.ZoneId
import java.time.ZonedDateTime

class CoreTest {
    private val fixtures = File(System.getProperty("luma.fixtures") ?: "../../desktop/src/test/fixtures")
    private fun fixture(name: String) = File(fixtures, name).readBytes()
    private val lanLight = LightDevice("AA:BB", "H6008", "Bulb", ip = "192.168.1.23")

    // ---- LAN wire format (same bytes as desktop/src/test/lan.test.ts) ----

    @Test fun lanControlPackets() {
        assertEquals("""{"msg":{"cmd":"colorwc","data":{"color":{"r":17,"g":34,"b":51},"colorTemInKelvin":0}}}""", LanPacket.control(CapabilityCommand.rgb(0x112233)).decodeToString())
        assertEquals("""{"msg":{"cmd":"turn","data":{"value":1}}}""", LanPacket.control(CapabilityCommand.power(true)).decodeToString())
        assertEquals("""{"msg":{"cmd":"brightness","data":{"value":40}}}""", LanPacket.control(CapabilityCommand.brightness(40)).decodeToString())
        assertEquals("""{"msg":{"cmd":"colorwc","data":{"color":{"r":0,"g":0,"b":0},"colorTemInKelvin":2700}}}""", LanPacket.control(CapabilityCommand.kelvin(2700)).decodeToString())
        assertEquals("""{"msg":{"cmd":"scan","data":{"account_topic":"reserve"}}}""", LanPacket.scan().decodeToString())
        assertEquals("""{"msg":{"cmd":"devStatus","data":{}}}""", LanPacket.devStatus().decodeToString())
        assertThrows(LumaException::class.java) { LanPacket.control(CapabilityCommand.kelvin(1500)) }
        assertThrows(LumaException::class.java) { LanPacket.control(CapabilityCommand.brightness(0)) }
    }

    @Test fun lanParsing() {
        val scan = """{"msg":{"cmd":"scan","data":{"ip":"192.168.1.23","device":"AA:BB","sku":"H6008"}}}""".toByteArray()
        val d = LanPacket.parse(scan, "192.168.1.23") as LanPacket.Received.Discovery
        assertEquals("AA:BB", d.device.id); assertEquals("192.168.1.23", d.device.ip)
        assertThrows(LumaException::class.java) { LanPacket.parse(scan, "192.168.1.24") } // spoofed ip
        val status = """{"msg":{"cmd":"devStatus","data":{"onOff":1,"brightness":50,"color":{"r":255,"g":0,"b":16},"colorTemInKelvin":0}}}""".toByteArray()
        assertEquals(LanPacket.Status(true, 50, 0xFF0010, 0), (LanPacket.parse(status, "192.168.1.23") as LanPacket.Received.DevStatus).status)
        assertThrows(LumaException::class.java) { LanPacket.parse("""{"msg":{"cmd":"devStatus"}}""".toByteArray(), "10.0.0.5") }
        assertThrows(LumaException::class.java) { LanPacket.parse(ByteArray(8193) { 32 }, "192.168.1.23") }
        assertFalse(LanPacket.isUnicastIPv4("239.255.255.250"))
        assertFalse(LanPacket.isUnicastIPv4("127.0.0.1"))
        assertFalse(LanPacket.isUnicastIPv4("example.com"))
        assertTrue(LanPacket.isUnicastIPv4("10.0.0.5"))
    }

    // ---- Validation, DreamView, scene lists ----

    @Test fun validation() {
        CommandValidation.validate(CapabilityCommand.brightness(100), lanLight)
        assertThrows(LumaException::class.java) { CommandValidation.validate(CapabilityCommand.brightness(101), lanLight) }
        assertThrows(LumaException::class.java) { CommandValidation.validate(CapabilityCommand("devices.capabilities.range", "colorRgb", JsonPrimitive(1)), lanLight) }
        assertThrows(LumaException::class.java) { CommandValidation.validate(CapabilityCommand("x", "lightScene", JsonPrimitive(1)), lanLight) }
        val tv = Demo.home().devices.first { it.id == "demo-tv" }
        // ENUM values compare as numbers: a 1.0 from older JSON still matches option 1.
        CommandValidation.validate(CapabilityCommand("devices.capabilities.toggle", DreamView.INSTANCE, JsonPrimitive(1.0)), tv)
        assertThrows(LumaException::class.java) { CommandValidation.validate(CapabilityCommand("devices.capabilities.toggle", DreamView.INSTANCE, JsonPrimitive(2)), tv) }
        assertEquals(JsonPrimitive(1), DreamView.command(true, tv).value)
        val structCap = Capability("t", "segmentedColorRgb", buildJsonObject {
            put("dataType", "STRUCT")
            put("fields", kotlinx.serialization.json.JsonArray(listOf(buildJsonObject { put("fieldName", "rgb"); put("dataType", "INTEGER"); put("required", true) })))
        })
        assertThrows(LumaException::class.java) { CommandValidation.validateValue(buildJsonObject { }, structCap.parameters) }
    }

    @Test fun demoScenesValidateAndListOptions() {
        val home = Demo.home()
        home.scenes.forEach { CommandValidation.validateScene(it, home.devices) }
        val strip = home.devices.first { it.id == "demo-strip" }
        val options = SceneLibrary.options(strip)
        assertEquals(14, options.size)
        assertEquals(listOf("Party Pulse", "Slow Fade"), SceneLibrary.filter(options, "", SceneKind.Diy).map { it.name })
        assertEquals("Starry Sky", SceneLibrary.filter(options, "starry").single().name)
        CommandValidation.validate(options.first().command, strip)
    }

    @Test fun readings() {
        val state = LumaJson.parseToJsonElement("""{"capabilities":[{"instance":"sensorTemperature","state":{"value":21.456}},{"instance":"powerSwitch","state":{"value":1}},{"instance":"filterLifeTime","state":{"value":80}}]}""")
        val caps = listOf(Capability("t", "sensorTemperature", buildJsonObject { put("unit", "unit.temperature.celsius") }), Capability("t", "filterLifeTime", buildJsonObject { put("unit", "unit.percent") }))
        assertEquals(listOf("Temperature" to "21.46 °C", "Filter life" to "80%"), Readings.parse(state, caps).map { it.label to it.text })
        assertEquals("Work mode now", Readings.label("workModeNow"))
    }

    // ---- Schedules: Apple weekday numbering is shared with every client ----

    @Test fun scheduleWeekdaysUseAppleNumbering() {
        val zone = ZoneId.of("America/New_York")
        val monday = ZonedDateTime.of(2026, 11, 2, 7, 30, 0, 0, zone) // a Monday
        assertEquals(2, SceneSchedule.appleWeekday(monday))
        assertEquals(1, SceneSchedule.appleWeekday(monday.minusDays(1))) // Sunday
        val s = SceneSchedule(sceneID = "S", hour = 7, minute = 30, weekdays = listOf(2, 3, 4))
        assertTrue(s.shouldRun(monday))
        assertFalse(s.shouldRun(monday.plusDays(3))) // Thursday
        assertFalse(s.copy(lastRunMinute = SceneSchedule.minuteKey(monday)).shouldRun(monday))
        assertFalse(s.copy(pausedUntil = monday.plusHours(1).toInstant().toString()).shouldRun(monday))
        assertEquals("2026-11-2-7-30", SceneSchedule.minuteKey(monday))
    }

    @Test fun nextRunHonorsWeekdaysPauseAndDst() {
        val zone = ZoneId.of("America/New_York")
        val monday = ZonedDateTime.of(2026, 11, 2, 7, 30, 0, 0, zone)
        val s = SceneSchedule(sceneID = "S", hour = 7, minute = 30, weekdays = listOf(2, 3, 4))
        assertEquals(monday.plusDays(1), s.next(monday)) // strictly after: Tuesday
        assertEquals(monday, s.next(monday.minusMinutes(1)))
        assertEquals(monday.plusDays(7), s.next(monday.plusDays(2))) // Wednesday 7:30 → next Monday
        assertEquals(null, s.copy(enabled = false).next(monday))
        assertEquals(monday.plusDays(14), s.copy(pausedUntil = monday.plusDays(10).toInstant().toString()).next(monday.minusMinutes(1)))
        // 2:30 doesn't exist on 2027-03-14 in New York; it moves to 3:30.
        val gap = SceneSchedule(sceneID = "S", hour = 2, minute = 30).next(ZonedDateTime.of(2027, 3, 14, 0, 0, 0, 0, zone))!!
        assertEquals(3, gap.hour)
        assertEquals(30_000L, GoveeCloud.retryAfterMillis("30"))
        assertEquals(2_000L, GoveeCloud.retryAfterMillis("0"))
        assertEquals(60_000L, GoveeCloud.retryAfterMillis(null))
    }

    // ---- Shared fixtures ----

    @Test fun nativeBackupFixtureRestoresIntoDemoHome() {
        val backup = HomeBackup.decode(fixture("native-backup.json"))
        assertEquals(2, backup.scenes.size)
        assertEquals(listOf(2, 3, 4), backup.schedules.single().weekdays)
        val (home, result) = HomeBackup.restore(backup, Demo.home())
        assertEquals(HomeBackup.Result(scenes = 2, schedules = 1, lightsUpdated = 5, lightsNotFound = 0, scenesWithMissingLights = 0), result)
        assertEquals("Sofa glow", home.devices.first { it.id == "demo-strip" }.customName)
        home.scenes.forEach { CommandValidation.validateScene(it, home.devices) }
        // Round trip: Android's file decodes back to the same content, integers stay integers.
        val again = HomeBackup.decode(backup.encode().toByteArray())
        assertEquals(backup, again)
        assertTrue(backup.encode().contains("\"value\": 16756324"))
        assertFalse(backup.encode().contains("customName\": null"))
    }

    @Test fun backupRejectsOtherFiles() {
        assertThrows(LumaException::class.java) { HomeBackup.decode("""{"format":"other","version":1,"exportedAt":"x","scenes":[],"schedules":[],"lights":[]}""".toByteArray()) }
        assertThrows(LumaException::class.java) { HomeBackup.decode("""{"format":"luma-home-backup","version":2,"exportedAt":"x","scenes":[],"schedules":[],"lights":[]}""".toByteArray()) }
        assertThrows(LumaException::class.java) { HomeBackup.decode("nope".toByteArray()) }
    }

    @Test fun scheduleSyncVectors() {
        val v = LumaJson.parseToJsonElement(fixture("schedule-sync-vectors.json").decodeToString())
        fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        for (b in v["base32"].arr!!) assertEquals(b["b32"].str, SyncCodes.base32(hex(b["hex"].str!!)))
        assertEquals(v["certPin"]["pin"].str, SyncCodes.certPin(hex(v["certPin"]["derHex"].str!!)))
        for (p in v["pairing"].arr!!) {
            if (p["valid"].bool != true) { assertThrows(LumaException::class.java) { SyncCodes.parsePairingCode(p["code"].str!!) }; continue }
            val parsed = SyncCodes.parsePairingCode(p["code"].str!!)
            assertEquals(p["host"].str, parsed.host); assertEquals(p["port"].num!!.toInt(), parsed.port)
        }
    }

    // ---- Cloud client: retry rules, parsing ----

    @Test fun cloudNeverRetriesCommandsButRetriesReadsOnce() = runBlocking {
        var calls = 0
        val failing = GoveeCloud("key") { _, _, _, _ -> calls++; throw SocketTimeoutException() }
        val e = assertThrows(LumaException::class.java) { runBlocking { failing.control(lanLight, CapabilityCommand.power(true)) } }
        assertEquals(1, calls); assertTrue(e.message!!.contains("not retried"))
        calls = 0
        assertThrows(LumaException::class.java) { runBlocking { failing.devices() } }
        assertEquals(2, calls)
    }

    @Test fun cloudParsesDevicesAndState() = runBlocking {
        val sent = mutableListOf<String>()
        val cloud = GoveeCloud(" key ") { method, url, headers, body ->
            assertEquals("key", headers["Govee-API-Key"])
            sent += "$method ${url.substringAfterLast("v1/")}"
            GoveeCloud.Response(200, when {
                url.endsWith("user/devices") -> """{"code":200,"data":[{"device":"AA:BB","sku":"H6008","deviceName":"Lamp","capabilities":[{"type":"devices.capabilities.on_off","instance":"powerSwitch"}]},{"device":"S1","sku":"H5179","type":"devices.types.thermometer"}]}"""
                else -> { assertNotNull(body); """{"code":200,"payload":{"device":"AA:BB","sku":"H6008","capabilities":[{"instance":"online","state":{"value":true}},{"instance":"powerSwitch","state":{"value":1}},{"instance":"brightness","state":{"value":55}}]}}""" }
            }.toByteArray())
        }
        val devices = cloud.devices()
        assertEquals(listOf("Lamp", "H5179"), devices.map { it.name })
        assertFalse(devices[1].isLight)
        val (state, _) = cloud.stateAndReadings(devices[0])
        assertEquals(true, state.power); assertEquals(55, state.brightness)
        assertEquals(listOf("GET user/devices", "POST device/state"), sent)
        val rejected = GoveeCloud("key") { _, _, _, _ -> GoveeCloud.Response(401, ByteArray(0)) }
        assertThrows(LumaException::class.java) { runBlocking { rejected.devices() } }
        Unit
    }

}
