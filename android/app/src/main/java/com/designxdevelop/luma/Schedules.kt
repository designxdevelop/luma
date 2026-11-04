package com.designxdevelop.luma

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import com.designxdevelop.luma.core.CommandValidation
import com.designxdevelop.luma.core.GoveeCloud
import com.designxdevelop.luma.core.GoveeLan
import com.designxdevelop.luma.core.LightDevice
import com.designxdevelop.luma.core.LumaJson
import com.designxdevelop.luma.core.SavedHome
import com.designxdevelop.luma.core.SceneSchedule
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime

/**
 * Schedules fire from one alarm at the next run across all schedules, so they run with
 * Luma closed. Exact alarms need "Alarms & reminders" access (Android 12+); without it the
 * alarm is inexact and a run that arrives more than [GRACE_MS] late is skipped as missed.
 */
object ScheduleAlarms {
    const val GRACE_MS = 120_000L // Same grace as ScheduleSync.runGrace on the other clients.
    private const val EXTRA_AT = "at"

    fun canExact(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S || context.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()

    fun next(home: SavedHome, after: ZonedDateTime): ZonedDateTime? =
        home.schedules.filter { s -> home.scenes.any { it.id == s.sceneID } }.mapNotNull { it.next(after) }.minOrNull()

    /** Replaces the pending alarm. The demo home (in-app ticker) and a paired phone (the runner runs them) arm none. */
    fun reschedule(context: Context, home: SavedHome, demo: Boolean) {
        val alarms = context.getSystemService(AlarmManager::class.java)
        val at = if (demo || ScheduleSync.paired(context)) null else next(home, ZonedDateTime.now())
        val intent = Intent(context, ScheduleReceiver::class.java).setAction(ACTION).putExtra(EXTRA_AT, at?.toInstant()?.toEpochMilli() ?: 0L)
        val pending = PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        if (at == null) { alarms.cancel(pending); return }
        val millis = at.toInstant().toEpochMilli()
        if (canExact(context)) alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, millis, pending)
        else alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, millis, pending)
    }

    /** Schedules due at [at] that haven't run for that minute. */
    fun due(home: SavedHome, at: ZonedDateTime): List<SceneSchedule> =
        home.schedules.filter { it.next(at.minusMinutes(1)) == at && it.lastRunMinute != SceneSchedule.minuteKey(at) }

    const val ACTION = "com.designxdevelop.luma.RUN_SCHEDULES"
    fun occurrence(intent: Intent): Long = intent.getLongExtra(EXTRA_AT, 0L)
}

/** Re-arms the alarm after boot, an app update, a clock or time-zone change, or an alarm-access change. */
class ScheduleBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        HomeFile.load(app)?.let { ScheduleAlarms.reschedule(app, it, HomeFile.demo(app)) }
    }
}

/** Runs due schedules. Not exported: only Luma's own alarm can reach it. */
class ScheduleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        val pending = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                runDue(app, ScheduleAlarms.occurrence(intent))
            } finally { pending.finish() }
        }
    }

    private suspend fun runDue(context: Context, millis: Long) {
        if (millis == 0L || HomeFile.demo(context)) return
        // A live app runs the scene itself, so its state and log stay current.
        HomeStore.live?.let { store -> withContext(Dispatchers.Main) { store.runDueSchedules(millis) }; return }
        val home = HomeFile.load(context) ?: return
        val at = Instant.ofEpochMilli(millis).atZone(ZoneId.systemDefault())
        val due = ScheduleAlarms.due(home, at)
        val late = System.currentTimeMillis() - millis > ScheduleAlarms.GRACE_MS
        val key = SceneSchedule.minuteKey(at)
        val updated = home.copy(schedules = home.schedules.map { s -> if (due.any { it.id == s.id }) s.copy(lastRunMinute = key) else s })
        HomeFile.save(context, updated)
        if (!late) {
            val cloud = KeyStore.read(context)?.let { GoveeCloud(it) }
            // ponytail: a receiver gets ~10 s, so steps past 9 s of delays are skipped. Upgrade path: an expedited worker.
            withTimeoutOrNull(9_000) {
                for (s in due) home.scenes.firstOrNull { it.id == s.sceneID }?.let { HeadlessScene.run(it.steps, home.devices, cloud) }
            }
        }
        ScheduleAlarms.reschedule(context, updated, demo = false)
    }
}

/** Sends scene steps with no UI: LAN for basic controls when the light has an address, cloud otherwise. */
object HeadlessScene {
    suspend fun run(steps: List<com.designxdevelop.luma.core.SceneStep>, devices: List<LightDevice>, cloud: GoveeCloud?) {
        for (step in steps) {
            delay(step.delayMilliseconds.toLong())
            val device = devices.firstOrNull { it.id == step.deviceID } ?: continue
            runCatching {
                CommandValidation.validate(step.command, device)
                if (device.ip != null && step.command.instance in LightDevice.LAN_INSTANCES) GoveeLan.sendOnce(device, step.command)
                else cloud?.control(device, step.command)
            }
        }
    }
}

/** `home.json` access shared by the app and the alarm receiver. */
object HomeFile {
    private fun file(context: Context) = File(context.filesDir, "home.json")
    fun demo(context: Context) = context.getSharedPreferences("luma", Context.MODE_PRIVATE).getBoolean("demo", false)
    fun load(context: Context): SavedHome? = runCatching { LumaJson.decodeFromString(SavedHome.serializer(), file(context).readText()) }.getOrNull()
    @Synchronized fun save(context: Context, home: SavedHome) {
        val tmp = File(context.filesDir, "home.json.tmp")
        tmp.writeText(LumaJson.encodeToString(SavedHome.serializer(), home))
        tmp.renameTo(file(context))
    }
}
