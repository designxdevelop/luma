package com.designxdevelop.luma.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.time.Instant
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLException
import javax.net.ssl.X509TrustManager

/**
 * The paired-device half of schedule sync (`desktop/src/core/schedule-sync.ts`, "paired device").
 * A computer (the runner) holds the shared scenes and schedules and is the only device that runs
 * them; this phone mirrors them and sends its edits as operations. The runner decides conflicts.
 */
object SyncProtocol {
    const val VERSION = 1
    const val SYNC_PATH = "/v1/sync"
    private const val BATCH_BYTES = 48 * 1024
    private const val OPS_PER_REQUEST = 200
    private val uuid = Regex("^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")

    fun canonicalID(id: String?): String? = id?.uppercase()?.takeIf { uuid.matches(it) }
    fun key(kind: String, id: String) = "$kind:$id"

    // ---- Wire values (same shapes as backup scenes; schedules carry pausedUntil as epoch ms) ----

    fun sceneWire(scene: LightScene, icon: String? = null): JsonObject = buildJsonObject {
        put("id", scene.id.uppercase()); put("name", scene.name); put("symbol", scene.symbol)
        icon?.let { put("icon", it) }
        put("steps", JsonArray(scene.steps.map { s ->
            buildJsonObject {
                put("id", s.id.uppercase()); put("deviceID", s.deviceID)
                put("command", buildJsonObject { put("type", s.command.type); put("instance", s.command.instance); put("value", s.command.value) })
                put("delayMilliseconds", s.delayMilliseconds)
            }
        }))
    }

    fun scheduleWire(s: SceneSchedule): JsonObject = buildJsonObject {
        put("id", s.id.uppercase()); put("sceneID", s.sceneID.uppercase()); put("hour", s.hour); put("minute", s.minute)
        put("weekdays", JsonArray(s.weekdays.distinct().sorted().map(::JsonPrimitive))); put("enabled", s.enabled)
        s.pausedUntil?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrNull() }?.let { put("pausedUntil", it) }
    }

    fun scene(v: JsonElement): LightScene = LumaJson.decodeFromJsonElement(LightScene.serializer(), v)

    fun schedule(v: JsonElement, lastRunMinute: String?): SceneSchedule = SceneSchedule(
        id = v["id"].str!!, sceneID = v["sceneID"].str!!, hour = v["hour"].num!!.toInt(), minute = v["minute"].num!!.toInt(),
        weekdays = v["weekdays"].arr.orEmpty().mapNotNull { it.num?.toInt() }, enabled = v["enabled"].bool ?: true,
        pausedUntil = v["pausedUntil"].num?.let { Instant.ofEpochMilli(it.toLong()).toString() }, lastRunMinute = lastRunMinute,
    )

    /** Schedules may only "reduce" (turn off, pause longer) without naming a revision. */
    fun onlyReduces(before: JsonObject, next: JsonObject): Boolean {
        val rest = { o: JsonObject -> JsonObject(o - "enabled" - "pausedUntil") }
        if (!jsonEquals(rest(before), rest(next))) return false
        val e1 = before["enabled"].bool == true
        val e2 = next["enabled"].bool == true
        val p1 = before["pausedUntil"].num ?: 0.0
        val p2 = next["pausedUntil"].num ?: 0.0
        val disables = e1 && !e2
        val pauses = p2 > p1
        return (disables || e1 == e2) && (pauses || p1 == p2) && (disables || pauses)
    }

    @Serializable data class Record(val kind: String, val id: String, val rev: Long, val deleted: Boolean? = null, val value: JsonElement? = null, val updatedBy: String = "", val updatedAt: Long = 0)
    /** `desired == null` is a delete. */
    @Serializable data class Pending(val kind: String, val id: String, val opID: String, var baseRev: Long, val desired: JsonElement? = null)
    data class Refusal(val kind: String, val id: String, val status: String, val reason: String)

    @Serializable
    class ClientState(
        var hubID: String? = null,
        var cursor: Long = 0,
        val mirror: MutableMap<String, Record> = mutableMapOf(),
        val pending: MutableMap<String, Pending> = mutableMapOf(),
    ) {
        /** Records a local change. Several edits before a sync collapse into one change. */
        fun stage(kind: String, desired: JsonObject?, id: String? = desired?.get("id").str) {
            val canon = canonicalID(id) ?: throw LumaException("Invalid record ID.")
            val key = key(kind, canon)
            val mirrored = mirror[key]
            val live = mirrored?.takeIf { it.deleted != true }?.value
            if ((desired == null && (mirrored == null || mirrored.deleted == true)) || (desired != null && live != null && jsonEquals(live, desired))) { pending.remove(key); return }
            pending[key] = Pending(kind, canon, newId(), pending[key]?.baseRev ?: mirrored?.rev ?: 0, desired)
        }

        /** The runner's copy with unsent local changes on top. */
        fun view(kind: String): List<JsonElement> {
            val values = LinkedHashMap<String, JsonElement>()
            for (r in mirror.values) if (r.kind == kind && r.deleted != true && r.value != null) values[r.id] = r.value
            for (p in pending.values) if (p.kind == kind) { if (p.desired == null) values.remove(p.id) else values[p.id] = p.desired }
            return values.values.toList()
        }

        /** Changes in a safe order (scenes before the schedules that use them), split under the body limit. */
        fun batches(): List<List<JsonObject>> {
            fun order(p: Pending) = if (p.desired == null) (if (p.kind == "schedule") 2 else 3) else (if (p.kind == "scene") 0 else 1)
            val ops = pending.values.sortedBy(::order).map { p ->
                val mirrored = mirror[key(p.kind, p.id)]?.takeIf { it.deleted != true }?.value as? JsonObject
                val desired = p.desired as? JsonObject
                when {
                    desired == null -> buildJsonObject { put("opID", p.opID); put("type", "delete"); put("kind", p.kind); put("id", p.id) }
                    p.kind == "schedule" && mirrored != null && onlyReduces(mirrored, desired) -> buildJsonObject {
                        put("opID", p.opID); put("type", "reduce"); put("kind", "schedule"); put("id", p.id)
                        if (mirrored["enabled"].bool == true && desired["enabled"].bool != true) put("enabled", false)
                        val p2 = desired["pausedUntil"].num ?: 0.0
                        if (p2 > (mirrored["pausedUntil"].num ?: 0.0)) put("pausedUntil", desired["pausedUntil"]!!)
                    }
                    else -> buildJsonObject { put("opID", p.opID); put("type", "put"); put("kind", p.kind); put("id", p.id); put("baseRev", p.baseRev); put("value", desired) }
                }
            }
            val batches = mutableListOf(mutableListOf<JsonObject>())
            var size = 0
            for (op in ops) {
                val bytes = op.toString().toByteArray().size + 1
                val last = batches.last()
                if (last.isNotEmpty() && (size + bytes > BATCH_BYTES || last.size >= OPS_PER_REQUEST)) { batches += mutableListOf(op); size = bytes }
                else { last += op; size += bytes }
            }
            return batches
        }

        /** Folds a response into the mirror. Returns refused changes so the UI can say what was undone. */
        fun apply(sent: List<JsonObject>, response: JsonElement): List<Refusal> {
            val hub = response["hub"]["id"].str ?: throw LumaException("The runner sent an answer this version can't read.")
            if (hubID != null && hub != hubID) throw LumaException("This is a different runner than the one you paired with. Pair again.")
            hubID = hub
            val reset = response["reset"].bool == true
            if (reset) mirror.clear()
            for (raw in response["changes"].arr.orEmpty()) {
                val r = LumaJson.decodeFromJsonElement(Record.serializer(), raw)
                val id = canonicalID(r.id) ?: continue
                if (r.kind != "scene" && r.kind != "schedule") continue
                val k = key(r.kind, id)
                if ((mirror[k]?.rev ?: 0) < r.rev || reset) mirror[k] = r.copy(id = id)
            }
            cursor = response["seq"].num?.toLong() ?: cursor
            val refusals = mutableListOf<Refusal>()
            for (op in sent) {
                val opID = op["opID"].str
                val result = response["results"].arr.orEmpty().firstOrNull { it["opID"].str == opID } ?: continue
                val k = key(op["kind"].str!!, op["id"].str!!)
                val p = pending[k]
                if (result["status"].str == "applied") {
                    if (p?.opID == opID) pending.remove(k)
                    else if (p != null) result["rev"].num?.let { p.baseRev = it.toLong() } // edited again while in flight
                } else {
                    refusals += Refusal(op["kind"].str!!, op["id"].str!!, result["status"].str ?: "invalid", result["reason"].str ?: "Refused by the runner.")
                    if (p?.opID == opID) pending.remove(k)
                }
            }
            // A local change to something the runner has since deleted can never apply.
            pending.entries.removeAll { (k, p) -> mirror[k]?.deleted == true && p.desired != null && p.baseRev != 0L }
            return refusals
        }
    }

    // ---- Transport ----

    /** One HTTPS POST to the runner. The certificate must match the pairing pin, checked in the TLS handshake before the token is sent. */
    fun send(code: SyncCodes.PairingCode, path: String, body: ByteArray, timeoutMs: Int = 10_000): Pair<Int, ByteArray> {
        var mismatched = false
        val trust = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = throw CertificateException()
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                if (chain.isEmpty() || SyncCodes.certPin(chain[0].encoded) != code.pin) { mismatched = true; throw CertificateException("pin mismatch") }
            }
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        val ssl = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), null) }
        val c = java.net.URL("https://${code.host}:${code.port}$path").openConnection() as HttpsURLConnection
        try {
            c.sslSocketFactory = ssl.socketFactory
            c.hostnameVerifier = javax.net.ssl.HostnameVerifier { _, _ -> true } // The pin identifies the runner; hosts are often bare LAN IPs.
            c.requestMethod = "POST"; c.connectTimeout = timeoutMs; c.readTimeout = timeoutMs; c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json")
            c.setRequestProperty("Authorization", "Bearer ${code.token}")
            c.outputStream.use { it.write(body) }
            val status = c.responseCode
            return status to ((if (status >= 400) c.errorStream else c.inputStream)?.use { it.readBytes() } ?: ByteArray(0))
        } catch (e: SSLException) {
            throw LumaException(if (mismatched) "The runner's identity doesn't match the pairing code. Pair again." else "Can't reach the runner (${e.message}).")
        } catch (e: java.io.IOException) {
            throw LumaException("Can't reach the runner (${e.message}).")
        } finally { c.disconnect() }
    }
}
