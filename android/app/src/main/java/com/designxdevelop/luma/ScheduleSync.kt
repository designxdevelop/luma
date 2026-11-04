package com.designxdevelop.luma

import android.content.Context
import android.os.Build
import com.designxdevelop.luma.core.LightScene
import com.designxdevelop.luma.core.LumaException
import com.designxdevelop.luma.core.LumaJson
import com.designxdevelop.luma.core.SceneSchedule
import com.designxdevelop.luma.core.SyncCodes
import com.designxdevelop.luma.core.SyncProtocol
import com.designxdevelop.luma.core.get
import com.designxdevelop.luma.core.newId
import com.designxdevelop.luma.core.str
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File

/**
 * This phone paired with a computer that runs schedules (Android Counterpart of the paired role in
 * ScheduleSyncController.swift). While paired, schedules run only on the runner; this phone shows
 * the shared scenes and schedules and sends its edits. The pairing token is sealed in [KeyStore].
 */
class ScheduleSync(private val context: Context) {
    @Serializable
    data class Run(val scheduleID: String = "", val status: String = "", val at: Long = 0, val detail: String? = null)

    @Serializable
    data class Saved(
        val deviceID: String = newId(),
        val host: String? = null,
        val port: Int = 0,
        val pin: String? = null,
        val runnerName: String? = null,
        val lastSync: Long? = null,
        val lastError: String? = null,
        val runs: List<Run> = emptyList(),
        val state: SyncProtocol.ClientState = SyncProtocol.ClientState(),
    ) { val paired: Boolean get() = host != null }

    var saved: Saved = load(context); private set
    val paired: Boolean get() = saved.paired
    private val mutex = Mutex()

    /** Pairs with a runner. Local scenes and schedules it doesn't have are added to it; same IDs keep the runner's copy. */
    suspend fun pair(code: String, scenes: List<LightScene>, schedules: List<SceneSchedule>): List<String> = mutex.withLock {
        val target = SyncCodes.parsePairingCode(code)
        val fresh = SyncProtocol.ClientState()
        val response = request(target, fresh, emptyList())
        val previous = saved
        val sameRunner = previous.paired && previous.pin == target.pin && previous.state.hubID == response["hub"]["id"].str
        val state = if (sameRunner) previous.state else fresh.also { it.apply(emptyList(), response) }
        if (!sameRunner) {
            for (s in scenes) if (state.mirror[SyncProtocol.key("scene", s.id.uppercase())] == null) runCatching { state.stage("scene", SyncProtocol.sceneWire(s)) }
            for (s in schedules) if (state.mirror[SyncProtocol.key("schedule", s.id.uppercase())] == null) runCatching { state.stage("schedule", SyncProtocol.scheduleWire(s)) }
        }
        KeyStore.save(context, target.token, KeyStore.SYNC_TOKEN)
        saved = previous.copy(host = target.host, port = target.port, pin = target.pin, runnerName = response["hub"]["name"].str,
            lastSync = System.currentTimeMillis(), lastError = null, runs = runs(response), state = state)
        persist()
        if (previous.paired && !sameRunner && previous.state.pending.isNotEmpty()) listOf("${previous.state.pending.size} unsent changes were dropped: this is a different runner than before.") else emptyList()
    }

    /** Turns sharing off. Schedules here are turned off first so nothing runs twice. */
    fun unpair(schedules: List<SceneSchedule>): List<SceneSchedule> {
        KeyStore.delete(context, KeyStore.SYNC_TOKEN)
        saved = Saved(deviceID = saved.deviceID); persist()
        return schedules.map { it.copy(enabled = false) }
    }

    /** Every local scene/schedule edit becomes a shared change. Returns problems to show. */
    fun reconcile(scenes: List<LightScene>, schedules: List<SceneSchedule>): List<String> {
        if (!paired) return emptyList()
        val state = saved.state
        val shared = (state.view("scene").map { "scene:${it["id"].str}" to it } + state.view("schedule").map { "schedule:${it["id"].str}" to it }).toMap()
        val local = scenes.associate { s ->
            val old = shared["scene:${s.id.uppercase()}"]
            // Desktop scenes carry an icon; keep it while the symbol is unchanged so they don't look edited.
            val icon = old?.takeIf { it["symbol"].str == s.symbol }?.get("icon").str
            "scene:${s.id.uppercase()}" to SyncProtocol.sceneWire(s, icon)
        } + schedules.associate { "schedule:${it.id.uppercase()}" to SyncProtocol.scheduleWire(it) }
        val problems = mutableListOf<String>()
        for ((k, v) in local) if (!com.designxdevelop.luma.core.jsonEquals(shared[k], v)) runCatching { state.stage(k.substringBefore(':'), v) }.onFailure { problems += "Not shared: ${it.message}" }
        for (k in shared.keys - local.keys) runCatching { state.stage(k.substringBefore(':'), null, k.substringAfter(':')) }.onFailure { problems += "Not shared: ${it.message}" }
        persist()
        return problems
    }

    /** Sends pending changes and pulls the runner's. Returns notices about refused changes. */
    suspend fun sync(): List<String> = mutex.withLock {
        val s = saved
        if (!s.paired) return emptyList()
        val token = KeyStore.read(context, KeyStore.SYNC_TOKEN) ?: return listOf("Pair again: the pairing token is missing on this phone.")
        val target = SyncCodes.PairingCode(s.host!!, s.port, s.pin!!, token)
        val notices = mutableListOf<String>()
        try {
            var runs = s.runs
            var name = s.runnerName
            for (batch in s.state.batches()) {
                val response = request(target, s.state, batch)
                s.state.apply(batch, response).forEach { notices += "A change to a ${it.kind} wasn't applied: ${it.reason} The runner's version is shown." }
                runs = runs(response); name = response["hub"]["name"].str ?: name
            }
            saved = s.copy(lastSync = System.currentTimeMillis(), lastError = null, runs = runs, runnerName = name)
        } catch (e: Exception) {
            saved = s.copy(lastError = e.message)
        }
        persist()
        notices
    }

    /** Shared scenes and schedules for the home, keeping this phone's order and run marks. */
    fun shared(scenes: List<LightScene>, schedules: List<SceneSchedule>): Pair<List<LightScene>, List<SceneSchedule>> {
        val order = scenes.mapIndexed { i, s -> s.id.uppercase() to i }.toMap()
        val last = schedules.associate { it.id.uppercase() to it.lastRunMinute }
        val newScenes = saved.state.view("scene").mapNotNull { runCatching { SyncProtocol.scene(it) }.getOrNull() }.sortedBy { order[it.id.uppercase()] ?: Int.MAX_VALUE }
        val newSchedules = saved.state.view("schedule").mapNotNull { v -> runCatching { SyncProtocol.schedule(v, last[v["id"].str]) }.getOrNull() }.sortedWith(compareBy({ it.hour }, { it.minute }))
        return newScenes to newSchedules
    }

    private suspend fun request(target: SyncCodes.PairingCode, state: SyncProtocol.ClientState, ops: List<JsonObject>): JsonElement {
        val body = buildJsonObject {
            put("protocol", SyncProtocol.VERSION)
            put("client", buildJsonObject { put("id", saved.deviceID); put("name", (Build.MODEL ?: "Android").take(64)); put("platform", "android") })
            state.hubID?.let { put("hubID", it) }
            put("since", state.cursor)
            put("ops", JsonArray(ops))
        }.toString().toByteArray()
        val (status, data) = withContext(Dispatchers.IO) { SyncProtocol.send(target, SyncProtocol.SYNC_PATH, body) }
        val json = runCatching { LumaJson.parseToJsonElement(data.decodeToString()) }.getOrNull()
        if (status != 200) throw LumaException(json["error"].str ?: "The runner answered $status.")
        return json ?: throw LumaException("The runner sent an answer this version can't read.")
    }

    private fun runs(response: JsonElement) = (response["runs"] as? JsonArray).orEmpty().mapNotNull { runCatching { LumaJson.decodeFromJsonElement(Run.serializer(), it) }.getOrNull() }.takeLast(20)

    private fun persist() = file(context).writeText(LumaJson.encodeToString(Saved.serializer(), saved))

    companion object {
        private fun file(context: Context) = File(context.filesDir, "schedule-sync.json")
        fun load(context: Context): Saved = runCatching { LumaJson.decodeFromString(Saved.serializer(), file(context).readText()) }.getOrDefault(Saved())
        /** Paired phones never arm schedule alarms: the runner runs them. */
        fun paired(context: Context): Boolean = load(context).paired
    }
}
