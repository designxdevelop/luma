package com.designxdevelop.luma

import android.content.Context
import android.graphics.drawable.Icon
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.designxdevelop.luma.core.CapabilityCommand
import com.designxdevelop.luma.core.GoveeCloud
import com.designxdevelop.luma.core.LightDevice
import com.designxdevelop.luma.core.SavedHome
import com.designxdevelop.luma.core.SceneStep
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Power for the tile, widget and watch. A live app does it through its store (so state and log stay
 * current); otherwise commands go out headlessly like a scheduled scene and home.json is updated.
 * The demo home only exists inside the running app, so these do nothing for it when it's closed.
 */
object LightControl {
    fun home(context: Context): SavedHome = HomeStore.live?.home ?: HomeFile.load(context) ?: SavedHome()
    fun demo(context: Context) = HomeStore.live?.demo ?: HomeFile.demo(context)

    suspend fun setPower(context: Context, ids: Collection<String>, on: Boolean) {
        HomeStore.live?.let { s -> withContext(Dispatchers.Main) { s.perform(CapabilityCommand.power(on), ids) }; return }
        if (HomeFile.demo(context)) return
        val home = HomeFile.load(context) ?: return
        val targets = home.devices.filter { it.id in ids && it.isLight }
        HeadlessScene.run(targets.map { SceneStep(deviceID = it.id, command = CapabilityCommand.power(on)) }, home.devices, KeyStore.read(context)?.let(::GoveeCloud))
        HomeFile.save(context, home.copy(devices = home.devices.map { if (it in targets) it.copy(power = on) else it }))
    }

    suspend fun runScene(context: Context, sceneID: String) {
        HomeStore.live?.let { s -> withContext(Dispatchers.Main) { s.home.scenes.firstOrNull { it.id == sceneID }?.let(s::runScene) }; return }
        if (HomeFile.demo(context)) return
        val home = HomeFile.load(context) ?: return
        home.scenes.firstOrNull { it.id == sceneID }?.let { HeadlessScene.run(it.steps, home.devices, KeyStore.read(context)?.let(::GoveeCloud)) }
    }

    /** Refreshes the tile and widgets after any power change. */
    fun changed(context: Context) {
        TileService.requestListeningState(context, android.content.ComponentName(context, AllLightsTile::class.java))
        CoroutineScope(Dispatchers.Default).launch { runCatching { RoomsWidget().updateAll(context) } }
        WearSync.publish(context)
    }

    fun lights(home: SavedHome): List<LightDevice> = home.devices.filter { it.isLight }
}

/** Quick Settings: one tap turns every light off, or back on when all are off. */
class AllLightsTile : TileService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onStartListening() {
        val lights = LightControl.lights(LightControl.home(this))
        qsTile?.apply {
            state = when { lights.isEmpty() -> Tile.STATE_UNAVAILABLE; lights.any { it.power == true } -> Tile.STATE_ACTIVE; else -> Tile.STATE_INACTIVE }
            label = "Lights"
            subtitle = if (lights.isEmpty()) "None yet" else "${lights.count { it.power == true }} of ${lights.size} on"
            icon = Icon.createWithResource(this@AllLightsTile, R.drawable.ic_tile_light)
            updateTile()
        }
    }

    override fun onClick() {
        val lights = LightControl.lights(LightControl.home(this))
        if (lights.isEmpty()) return
        val on = lights.none { it.power == true }
        scope.launch {
            LightControl.setPower(applicationContext, lights.map { it.id }, on)
            onStartListening()
            LightControl.changed(applicationContext)
        }
    }

    override fun onDestroy() { scope.coroutineContext[kotlinx.coroutines.Job]?.cancel(); super.onDestroy() }
}

/** Home screen widget: room switches (Glance). */
class RoomsWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val home = LightControl.home(context)
        val rooms = LightControl.lights(home).groupBy { it.room }.toList().sortedBy { it.first }.take(5)
        provideContent { WidgetContent(rooms) }
    }

    @Composable
    private fun WidgetContent(rooms: List<Pair<String, List<LightDevice>>>) {
        val accent = ColorProvider(Color(0xFFB95500))
        Column(GlanceModifier.fillMaxSize().background(ColorProvider(Color(0xFFF5F5F7))).cornerRadius(16.dp).padding(12.dp)) {
            Text("Luma", style = TextStyle(fontWeight = FontWeight.Bold, fontSize = 16.sp))
            Spacer(GlanceModifier.height(6.dp))
            if (rooms.isEmpty()) Text("Open Luma to find your lights.", style = TextStyle(fontSize = 13.sp))
            rooms.forEach { (room, lights) ->
                val on = lights.any { it.power == true }
                Row(GlanceModifier.fillMaxWidth().padding(vertical = 6.dp).clickable(actionRunCallback<ToggleRoom>(actionParametersOf(ToggleRoom.room to room, ToggleRoom.on to !on))),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text(room, GlanceModifier.defaultWeight(), style = TextStyle(fontSize = 14.sp))
                    Text(if (on) "On" else "Off", style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium, color = if (on) accent else ColorProvider(Color.Gray)))
                }
            }
        }
    }
}

class ToggleRoom : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val room = parameters[room] ?: return
        val home = LightControl.home(context)
        LightControl.setPower(context, LightControl.lights(home).filter { it.room == room }.map { it.id }, parameters[on] ?: false)
        RoomsWidget().update(context, glanceId)
        LightControl.changed(context)
    }

    companion object {
        val room = ActionParameters.Key<String>("room")
        val on = ActionParameters.Key<Boolean>("on")
    }
}

class RoomsWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = RoomsWidget() }

