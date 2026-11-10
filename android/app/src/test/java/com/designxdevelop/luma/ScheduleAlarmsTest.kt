package com.designxdevelop.luma

import com.designxdevelop.luma.core.Capability
import com.designxdevelop.luma.core.CapabilityCommand
import com.designxdevelop.luma.core.LightDevice
import com.designxdevelop.luma.core.LightScene
import com.designxdevelop.luma.core.LumaJson
import com.designxdevelop.luma.core.SavedHome
import com.designxdevelop.luma.core.SceneSchedule
import com.designxdevelop.luma.core.SceneStep
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.time.ZoneId
import java.time.ZonedDateTime

class ScheduleAlarmsTest {
    private val ny = ZoneId.of("America/New_York")
    private fun at(y: Int, mo: Int, d: Int, h: Int, mi: Int) = ZonedDateTime.of(y, mo, d, h, mi, 0, 0, ny)
    private val scene = LightScene(name = "Evening", steps = emptyList())

    @Test fun nextPicksEarliestRunAcrossTheHomeAndIgnoresMissingScenes() {
        val home = SavedHome(scenes = listOf(scene), schedules = listOf(
            SceneSchedule(sceneID = scene.id, hour = 21, minute = 0),
            SceneSchedule(sceneID = scene.id, hour = 7, minute = 30),
            SceneSchedule(sceneID = "gone", hour = 6, minute = 0),
            SceneSchedule(sceneID = scene.id, hour = 5, minute = 0, enabled = false),
        ))
        assertEquals(at(2026, 6, 10, 7, 30), ScheduleAlarms.next(home, at(2026, 6, 10, 1, 0)))
        assertEquals(at(2026, 6, 10, 21, 0), ScheduleAlarms.next(home, at(2026, 6, 10, 7, 30)))
        assertNull(ScheduleAlarms.next(SavedHome(scenes = listOf(scene)), at(2026, 6, 10, 1, 0)))
    }

    @Test fun dueDedupesByLastRunMinute() {
        val s = SceneSchedule(sceneID = scene.id, hour = 7, minute = 30)
        val t = at(2026, 6, 10, 7, 30)
        assertEquals(listOf(s), ScheduleAlarms.due(SavedHome(scenes = listOf(scene), schedules = listOf(s)), t))
        val ran = s.copy(lastRunMinute = SceneSchedule.minuteKey(t))
        assertTrue(ScheduleAlarms.due(SavedHome(scenes = listOf(scene), schedules = listOf(ran)), t).isEmpty())
        // Not its minute, and not its weekday.
        assertTrue(ScheduleAlarms.due(SavedHome(schedules = listOf(s)), t.plusMinutes(1)).isEmpty())
        val weekdaysOnly = s.copy(weekdays = listOf(2, 3, 4, 5, 6)) // 2026-06-13 is a Saturday.
        assertTrue(ScheduleAlarms.due(SavedHome(schedules = listOf(weekdaysOnly)), at(2026, 6, 13, 7, 30)).isEmpty())
    }

    @Test fun dueDoesNotFilterMissingScenes() {
        // Unlike next(), due() keeps a schedule whose scene is gone; the runners skip it when they look the scene up.
        val s = SceneSchedule(sceneID = "gone", hour = 7, minute = 30)
        assertEquals(listOf(s), ScheduleAlarms.due(SavedHome(schedules = listOf(s)), at(2026, 6, 10, 7, 30)))
    }

    @Test fun graceWindow() {
        assertFalse(ScheduleAlarms.late(1_000 + ScheduleAlarms.GRACE_MS, 1_000))
        assertTrue(ScheduleAlarms.late(1_001 + ScheduleAlarms.GRACE_MS, 1_000))
        assertFalse(ScheduleAlarms.late(500, 1_000)) // Early delivery is never late.
    }

    @Test fun springForwardRunsAtTheShiftedTime() {
        // 2026-03-08 02:00 EST jumps to 03:00 EDT, so 02:30 doesn't exist and runs at 03:30.
        val s = SceneSchedule(sceneID = scene.id, hour = 2, minute = 30)
        val home = SavedHome(scenes = listOf(scene), schedules = listOf(s))
        val shifted = at(2026, 3, 8, 3, 30)
        assertEquals(shifted, ScheduleAlarms.next(home, at(2026, 3, 8, 0, 0)))
        assertEquals(listOf(s), ScheduleAlarms.due(home, shifted))
    }

    @Test fun fallBackRunsOnce() {
        // 2026-11-01 01:30 happens twice (EDT, then EST). Only the first is due.
        val s = SceneSchedule(sceneID = scene.id, hour = 1, minute = 30)
        val home = SavedHome(scenes = listOf(scene), schedules = listOf(s))
        val first = ZonedDateTime.ofLocal(java.time.LocalDateTime.of(2026, 11, 1, 1, 30), ny, java.time.ZoneOffset.ofHours(-4))
        val second = first.withLaterOffsetAtOverlap()
        assertEquals(first, ScheduleAlarms.next(home, at(2026, 11, 1, 0, 0)))
        assertEquals(listOf(s), ScheduleAlarms.due(home, first))
        assertTrue(ScheduleAlarms.due(home, second).isEmpty())
        assertEquals(at(2026, 11, 2, 1, 30), ScheduleAlarms.next(home, first))
    }

    // ---- Headless runs report what wasn't sent ----

    private val cloudOnlyLight = LightDevice("AA:01", "H6008", "Bulb", capabilities = listOf(Capability("devices.capabilities.on_off", "powerSwitch")))

    @Test fun headlessCountsMissingKeyMissingLightAndRefusedCommands() = runBlocking {
        val on = CapabilityCommand.power(true)
        // Valid, and no ip, so it needs the cloud, and there's no key.
        com.designxdevelop.luma.core.CommandValidation.validate(on, cloudOnlyLight)
        assertEquals(1, HeadlessScene.run(listOf(SceneStep(deviceID = cloudOnlyLight.id, command = on)), listOf(cloudOnlyLight), null))
        assertEquals(1, HeadlessScene.run(listOf(SceneStep(deviceID = "gone", command = on)), listOf(cloudOnlyLight), null))
        assertEquals(1, HeadlessScene.run(listOf(SceneStep(deviceID = cloudOnlyLight.id, command = CapabilityCommand.brightness(50))), listOf(cloudOnlyLight), null))
        assertEquals(0, HeadlessScene.run(emptyList(), listOf(cloudOnlyLight), null))
    }

    // ---- home.json ----

    @Test fun unreadableHomeIsMovedAsideNotLost() {
        val dir = Files.createTempDirectory("luma-home").toFile()
        try {
            assertNull(HomeFile.load(dir)) // Missing.
            val good = SavedHome(scenes = listOf(scene))
            dir.resolve("home.json").writeText(LumaJson.encodeToString(SavedHome.serializer(), good))
            assertEquals(good, HomeFile.load(dir))
            dir.resolve("home.json").writeText("{\"scenes\": [ truncated")
            assertNull(HomeFile.load(dir))
            assertTrue(HomeFile.moveAside(dir))
            assertFalse(dir.resolve("home.json").exists())
            assertEquals("{\"scenes\": [ truncated", dir.resolve("home.json.corrupt").readText())
        } finally { dir.deleteRecursively() }
    }
}
