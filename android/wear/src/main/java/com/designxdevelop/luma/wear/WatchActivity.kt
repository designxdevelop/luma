package com.designxdevelop.luma.wear

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.wear.compose.foundation.lazy.TransformingLazyColumn
import androidx.wear.compose.foundation.lazy.rememberTransformingLazyColumnState
import androidx.wear.compose.material3.AppScaffold
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.ListHeader
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.SwitchButton
import androidx.wear.compose.material3.Text
import com.google.android.gms.wearable.DataClient
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.Wearable
import org.json.JSONArray
import org.json.JSONObject

/** Rooms and scenes from the phone (WearSync on the phone). Taps are sent back as messages; the phone does the control. */
class WatchActivity : ComponentActivity(), DataClient.OnDataChangedListener {
    data class Light(val id: String, val name: String, val room: String, val on: Boolean)
    data class Scene(val id: String, val name: String)
    private var lights by mutableStateOf<List<Light>?>(null)
    private var scenes by mutableStateOf<List<Scene>>(emptyList())
    private var demo by mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                AppScaffold {
                    val state = rememberTransformingLazyColumnState()
                    ScreenScaffold(scrollState = state) { padding ->
                        TransformingLazyColumn(state = state, contentPadding = padding) {
                            item { ListHeader { Text(if (demo) "Luma demo" else "Luma") } }
                            val all = lights
                            if (all == null) item { Text("Open Luma on your phone.", textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth()) }
                            else {
                                if (all.any { it.on }) item { Button({ send("/luma/power", JSONObject().put("ids", JSONArray(all.map { it.id })).put("on", false)) }, Modifier.fillMaxWidth()) { Text("All off") } }
                                all.groupBy { it.room }.toSortedMap().forEach { (room, roomLights) ->
                                    item {
                                        val on = roomLights.any { it.on }
                                        SwitchButton(on, { v -> send("/luma/power", JSONObject().put("ids", JSONArray(roomLights.map { it.id })).put("on", v)) }, Modifier.fillMaxWidth()) {
                                            Text("$room (${roomLights.count { it.on }}/${roomLights.size})")
                                        }
                                    }
                                }
                                if (scenes.isNotEmpty()) item { ListHeader { Text("Scenes") } }
                                scenes.forEach { s -> item { Button({ send("/luma/scene", JSONObject().put("id", s.id)) }, Modifier.fillMaxWidth()) { Text(s.name) } } }
                            }
                        }
                    }
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        val client = Wearable.getDataClient(this)
        client.addListener(this)
        client.dataItems.addOnSuccessListener { items -> items.forEach { if (it.uri.path == "/luma/state") read(DataMapItem.fromDataItem(it).dataMap.getString("state")) }; items.release() }
    }

    override fun onPause() { Wearable.getDataClient(this).removeListener(this); super.onPause() }

    override fun onDataChanged(events: DataEventBuffer) {
        events.forEach { if (it.type == DataEvent.TYPE_CHANGED && it.dataItem.uri.path == "/luma/state") read(DataMapItem.fromDataItem(it.dataItem).dataMap.getString("state")) }
    }

    private fun read(json: String?) {
        val o = runCatching { JSONObject(json ?: return) }.getOrNull() ?: return
        demo = o.optBoolean("demo")
        lights = o.optJSONArray("lights")?.let { a -> (0 until a.length()).map { a.getJSONObject(it).run { Light(getString("id"), getString("name"), getString("room"), getBoolean("on")) } } }
        scenes = o.optJSONArray("scenes")?.let { a -> (0 until a.length()).map { a.getJSONObject(it).run { Scene(getString("id"), getString("name")) } } }.orEmpty()
    }

    private fun send(path: String, body: JSONObject) {
        Wearable.getNodeClient(this).connectedNodes.addOnSuccessListener { nodes ->
            nodes.forEach { Wearable.getMessageClient(this).sendMessage(it.id, path, body.toString().toByteArray()) }
        }
    }
}
