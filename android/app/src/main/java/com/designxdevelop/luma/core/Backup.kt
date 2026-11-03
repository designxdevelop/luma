package com.designxdevelop.luma.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import java.security.MessageDigest
import java.time.Instant
import java.time.temporal.ChronoUnit

/**
 * Portable home backup, same `luma-home-backup` v1 file as iOS, macOS and desktop
 * (`HomeBackup` in Sources/LumaUI/Storage.swift). No keys, tokens, IPs or webhook settings.
 */
@Serializable
data class HomeBackup(
    val format: String = FORMAT,
    val version: Int = VERSION,
    /** ISO-8601, whole seconds, as Swift's `.iso8601` writes it. */
    val exportedAt: String,
    val scenes: List<LightScene>,
    val schedules: List<SceneSchedule>,
    val lights: List<Light>,
    /** Kept opaque: Android has no DreamView layout editor, but a round trip keeps other clients' drafts. */
    val dreamViewDrafts: Map<String, JsonElement>? = null,
) {
    @Serializable data class Light(val id: String, val sku: String, val customName: String? = null, val room: String)
    data class Result(val scenes: Int, val schedules: Int, val lightsUpdated: Int, val lightsNotFound: Int, val scenesWithMissingLights: Int)

    fun encode(): String = pretty.encodeToString(serializer(), this)

    companion object {
        const val FORMAT = "luma-home-backup"
        const val VERSION = 1
        private val pretty = Json(LumaJson) { prettyPrint = true }

        fun of(home: SavedHome, drafts: Map<String, JsonElement>? = null) = HomeBackup(
            exportedAt = Instant.now().truncatedTo(ChronoUnit.SECONDS).toString(),
            scenes = home.scenes, schedules = home.schedules,
            lights = home.devices.filter { !it.isDemo }.map { Light(it.id, it.sku, it.customName, it.room) },
            dreamViewDrafts = drafts,
        )

        fun decode(bytes: ByteArray): HomeBackup {
            if (bytes.size > 8 * 1024 * 1024) throw LumaException("That backup is too large.")
            val backup = runCatching { LumaJson.decodeFromString(serializer(), bytes.decodeToString()) }
                .getOrElse { throw LumaException("That file isn't a Luma home backup.") }
            if (backup.format != FORMAT || backup.version > VERSION) throw LumaException("That isn't a Luma home backup this version can read.")
            return backup
        }

        /**
         * Replaces scenes and schedules; applies names and rooms only to lights Luma already
         * knows (same ID and model). Schedules whose scene isn't in the backup are dropped.
         */
        fun restore(backup: HomeBackup, into: SavedHome): Pair<SavedHome, Result> {
            var updated = 0
            var notFound = 0
            val devices = into.devices.toMutableList()
            for (label in backup.lights) {
                val i = devices.indexOfFirst { it.id == label.id && it.sku.equals(label.sku, ignoreCase = true) }
                if (i < 0) { notFound++; continue }
                devices[i] = devices[i].copy(customName = label.customName, room = label.room); updated++
            }
            val sceneIDs = backup.scenes.map { it.id }.toSet()
            val schedules = backup.schedules.filter { it.sceneID in sceneIDs }
            val known = devices.map { it.id }.toSet()
            val missing = backup.scenes.count { s -> s.steps.any { it.deviceID !in known } }
            return SavedHome(devices, backup.scenes, schedules) to Result(backup.scenes.size, schedules.size, updated, notFound, missing)
        }
    }
}

/**
 * The pure parts of schedule sync shared by every client (desktop/src/core/schedule-sync.ts):
 * the base32 alphabet, certificate pins and `luma1/…` pairing codes.
 */
object SyncCodes {
    private const val B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    data class PairingCode(val host: String, val port: Int, val pin: String, val token: String)

    fun base32(bytes: ByteArray): String = buildString {
        var bits = 0
        var value = 0
        for (b in bytes) {
            value = (value shl 8) or (b.toInt() and 0xFF); bits += 8
            while (bits >= 5) { append(B32[(value ushr (bits - 5)) and 31]); bits -= 5 }
        }
        if (bits > 0) append(B32[(value shl (5 - bits)) and 31])
    }

    /** First 128 bits of the certificate's SHA-256, in base32. */
    fun certPin(der: ByteArray): String = base32(MessageDigest.getInstance("SHA-256").digest(der).copyOf(16))

    fun parsePairingCode(text: String): PairingCode {
        val bad = LumaException("That pairing code is not complete. Copy it again from the computer that runs schedules.")
        val parts = text.trim().replace(Regex("\\s+"), "").split("/")
        if (parts.size != 5 || !parts[0].equals("luma1", ignoreCase = true)) throw bad
        val (_, host, portText, pin, token) = parts
        val port = portText.toIntOrNull()
        if (!host.matches(Regex("[A-Za-z0-9.-]{1,253}")) || port == null || port !in 1..65535) throw bad
        val p = pin.uppercase()
        val t = token.uppercase()
        val b32 = Regex("[A-Z2-7]{26}")
        if (!p.matches(b32) || !t.matches(b32)) throw bad
        return PairingCode(host, port, p, t)
    }
}
