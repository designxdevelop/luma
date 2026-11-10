package com.designxdevelop.luma

import android.content.Context
import com.designxdevelop.luma.core.LumaJson
import com.designxdevelop.luma.core.arr
import com.designxdevelop.luma.core.bool
import com.designxdevelop.luma.core.get
import com.designxdevelop.luma.core.str
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * The Wear OS companion relays through this phone, as the Apple Watch relays through the iPhone:
 * the phone publishes lights and scenes as one data item; the watch sends power and scene messages.
 */
object WearSync {
    const val STATE_PATH = "/luma/state"

    fun publish(context: Context) {
        val home = LightControl.home(context)
        val json = buildJsonObject {
            put("demo", LightControl.demo(context))
            put("lights", JsonArray(LightControl.lights(home).map { d ->
                buildJsonObject { put("id", d.id); put("name", d.displayName); put("room", d.room); put("on", d.power == true); put("rgb", d.rgb ?: 0xFFAA66) }
            }))
            put("scenes", JsonArray(home.scenes.map { buildJsonObject { put("id", it.id); put("name", it.name) } }))
        }.toString()
        // Without Google Play services (or no watch) this quietly does nothing.
        runCatching {
            val request = PutDataMapRequest.create(STATE_PATH).apply { dataMap.putString("state", json); dataMap.putLong("at", System.currentTimeMillis()) }
            Wearable.getDataClient(context).putDataItem(request.asPutDataRequest().setUrgent())
        }
    }
}

/** Watch requests: `/luma/power` {ids, on}, `/luma/scene` {id}, `/luma/refresh`. */
class WearListener : WearableListenerService() {
    override fun onMessageReceived(event: MessageEvent) {
        val body = runCatching { LumaJson.parseToJsonElement(event.data.decodeToString()) }.getOrNull()
        // Blocks this service's worker thread so the process stays alive until a scene with delays finishes.
        runBlocking {
            when (event.path) {
                "/luma/power" -> LightControl.setPower(applicationContext, body["ids"].arr.orEmpty().mapNotNull { it.str }, body["on"].bool == true)
                "/luma/scene" -> body["id"].str?.let { LightControl.runScene(applicationContext, it) }
            }
        }
        LightControl.changed(applicationContext)
    }
}
