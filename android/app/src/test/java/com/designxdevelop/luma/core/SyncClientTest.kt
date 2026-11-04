package com.designxdevelop.luma.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** The paired-device functions from desktop/src/core/schedule-sync.ts, driven with runner-shaped responses. */
class SyncClientTest {
    private val sceneID = "6F1C2A0E-0B6B-4C11-9C2D-6A2B1F0E9D01"
    private val schedID = "6F1C2A0E-0B6B-4C11-9C2D-6A2B1F0E9D02"
    private val scene = LightScene(sceneID, "Evening", "moon.stars", listOf(SceneStep("0E000000-0000-4000-8000-000000000001", "AA:BB", CapabilityCommand.power(true))))
    private val schedule = SceneSchedule(schedID, sceneID, 7, 0)

    private fun response(seq: Int, results: String = "[]", changes: String = "[]", hub: String = "4B0B0000-0000-4000-8000-000000000001", reset: Boolean = false) =
        LumaJson.parseToJsonElement("""{"protocol":1,"hub":{"id":"$hub","name":"Desk","platform":"windows","timeZone":"UTC","now":1,"executing":true},"seq":$seq,"reset":$reset,"results":$results,"changes":$changes,"runs":[],"clients":[]}""")

    private fun record(kind: String, value: kotlinx.serialization.json.JsonObject, rev: Int) =
        """{"kind":"$kind","id":"${value["id"].str}","rev":$rev,"value":$value,"updatedBy":"Desk","updatedAt":1}"""

    @Test fun stagedChangesGoScenesFirstThenApply() {
        val state = SyncProtocol.ClientState()
        state.stage("schedule", SyncProtocol.scheduleWire(schedule))
        state.stage("scene", SyncProtocol.sceneWire(scene))
        val batch = state.batches().single()
        assertEquals(listOf("scene", "schedule"), batch.map { it["kind"].str })
        assertEquals(listOf("put", "put"), batch.map { it["type"].str })
        assertEquals(0.0, batch[0]["baseRev"].num)
        val results = batch.mapIndexed { i, op -> """{"opID":"${op["opID"].str}","status":"applied","rev":${i + 1}}""" }.joinToString(",", "[", "]")
        val changes = listOf(record("scene", SyncProtocol.sceneWire(scene), 1), record("schedule", SyncProtocol.scheduleWire(schedule), 2)).joinToString(",", "[", "]")
        assertEquals(emptyList<SyncProtocol.Refusal>(), state.apply(batch, response(2, results, changes)))
        assertTrue(state.pending.isEmpty())
        assertEquals(2L, state.cursor)
        assertEquals("Evening", SyncProtocol.scene(state.view("scene").single()).name)
        // Re-staging the same value is a no-op.
        state.stage("scene", SyncProtocol.sceneWire(scene))
        assertTrue(state.pending.isEmpty())
    }

    @Test fun disablingIsAReduceAndConflictsAreReported() {
        val state = SyncProtocol.ClientState()
        state.apply(emptyList(), response(2, changes = "[${record("scene", SyncProtocol.sceneWire(scene), 1)},${record("schedule", SyncProtocol.scheduleWire(schedule), 2)}]"))
        state.stage("schedule", SyncProtocol.scheduleWire(schedule.copy(enabled = false)))
        val reduce = state.batches().single().single()
        assertEquals("reduce", reduce["type"].str)
        assertEquals(false, reduce["enabled"].bool)
        // An edit (new time) needs a revision and can conflict.
        state.stage("schedule", SyncProtocol.scheduleWire(schedule.copy(hour = 8)))
        val put = state.batches().single().single()
        assertEquals("put", put["type"].str); assertEquals(2.0, put["baseRev"].num)
        val refused = state.apply(listOf(put), response(7, """[{"opID":"${put["opID"].str}","status":"conflict","rev":7,"reason":"Changed on another device."}]"""))
        assertEquals("conflict", refused.single().status)
        assertTrue(state.pending.isEmpty())
        assertEquals(7, SyncProtocol.schedule(state.view("schedule").single(), null).hour) // the runner's version stays
    }

    @Test fun differentRunnerAndDeletes() {
        val state = SyncProtocol.ClientState()
        state.apply(emptyList(), response(1, changes = "[${record("scene", SyncProtocol.sceneWire(scene), 1)}]"))
        assertThrows(LumaException::class.java) { state.apply(emptyList(), response(1, hub = "4B0B0000-0000-4000-8000-000000000009")) }
        state.stage("scene", null, sceneID)
        assertEquals("delete", state.batches().single().single()["type"].str)
        assertTrue(state.view("scene").isEmpty())
        assertThrows(LumaException::class.java) { state.stage("scene", null, "not-a-uuid") }
    }

    @Test fun scheduleWirePausedUntilIsEpochMillis() {
        val paused = schedule.copy(pausedUntil = "2026-11-02T15:00:00Z", weekdays = listOf(3, 2, 2))
        val wire = SyncProtocol.scheduleWire(paused)
        assertEquals(1793631600000.0, wire["pausedUntil"].num)
        assertEquals(listOf(2.0, 3.0), wire["weekdays"].arr!!.map { it.num })
        assertEquals("2026-11-02T15:00:00Z", SyncProtocol.schedule(wire, null).pausedUntil)
    }
}
