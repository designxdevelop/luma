package com.designxdevelop.luma

import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.designxdevelop.luma.core.LightScene
import com.designxdevelop.luma.core.SceneSchedule

private val dayNames = listOf("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat") // Apple numbering: index + 1

fun daysText(days: List<Int>): String = when (days.sorted()) {
    (1..7).toList() -> "Every day"
    listOf(2, 3, 4, 5, 6) -> "Weekdays"
    listOf(1, 7) -> "Weekends"
    else -> days.sorted().joinToString(", ") { dayNames[it - 1] }
}

@Composable
fun ScenesScreen(store: HomeStore, modifier: Modifier) {
    var creating by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<LightScene?>(null) }
    Scaffold(modifier, floatingActionButton = { ExtendedFloatingActionButton(onClick = { creating = true }, icon = { Icon(Icons.Outlined.Add, null) }, text = { Text("New scene") }) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            item { Header("Scenes", "One scene runs at a time.") }
            if (store.home.scenes.isEmpty()) item { Banner("No scenes yet. Save a look from a light, or tap New scene.") }
            store.restorePoint?.takeIf { store.runningSceneID == null }?.let { point ->
                item {
                    val count = point.steps.map { it.deviceID }.distinct().size
                    Card(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp), colors = CardDefaults.cardColors(MaterialTheme.colorScheme.surfaceContainer)) {
                        Column(Modifier.padding(16.dp)) {
                            Text(point.name, style = MaterialTheme.typography.titleSmall)
                            Text("Put $count ${if (count == 1) "light" else "lights"} back to ${if (count == 1) "its" else "their"} power, brightness, and color from before the scene. Effects and DreamView aren't undone.",
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                                TextButton({ store.restorePoint = null }) { Text("Dismiss") }
                                Button(store::restoreBeforeScene) { Text("Restore") }
                            }
                        }
                    }
                }
            }
            items(store.home.scenes, key = { it.id }) { scene ->
                val running = store.runningSceneID == scene.id
                Card(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp), colors = CardDefaults.cardColors(MaterialTheme.colorScheme.surfaceContainer)) {
                    Row(Modifier.padding(start = 14.dp, end = 8.dp, top = 14.dp, bottom = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                        SceneSwatch(scene, glowing = running)
                        Column(Modifier.weight(1f).padding(start = 14.dp)) {
                            Text(scene.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                            val lights = scene.steps.map { it.deviceID }.distinct().mapNotNull { id -> store.devices.firstOrNull { it.id == id }?.displayName }
                            Text(if (running) "Running…" else lights.joinToString(", ").ifEmpty { "${scene.steps.size} steps" },
                                style = MaterialTheme.typography.bodySmall, color = if (running) MaterialTheme.colorScheme.secondary else MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
                        }
                        if (running) Button(store::stopScene) { Text("Stop") }
                        else OutlinedButton({ store.runScene(scene) }, enabled = store.runningSceneID == null) { Text("Run") }
                        IconButton({ deleting = scene }) { Icon(Icons.Outlined.Delete, "Delete ${scene.name}") }
                    }
                }
            }
            item { Spacer(Modifier.height(88.dp)) }
        }
    }
    if (creating) NewSceneDialog(store) { creating = false }
    deleting?.let { s ->
        AlertDialog(onDismissRequest = { deleting = null }, title = { Text("Delete ${s.name}?") }, text = { Text("Schedules that run this scene are deleted too.") },
            confirmButton = { TextButton({ store.deleteScene(s); deleting = null }) { Text("Delete", color = MaterialTheme.colorScheme.error) } },
            dismissButton = { TextButton({ deleting = null }) { Text("Cancel") } })
    }
}

@Composable
fun Header(title: String, subtitle: String) {
    Column(Modifier.padding(start = 20.dp, top = 20.dp, bottom = 8.dp)) {
        Text(title, style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
        Text(subtitle, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Saves the selected lights' current state as a scene (the "Save current lighting" board). */
@Composable
private fun NewSceneDialog(store: HomeStore, onDismiss: () -> Unit) {
    var name by remember { mutableStateOf("") }
    var selected by remember { mutableStateOf(store.devices.filter { it.isLight && it.power == true }.map { it.id }.toSet()) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("Save current lighting") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                OutlinedTextField(name, { name = it.take(64) }, singleLine = true, label = { Text("Scene name") }, modifier = Modifier.fillMaxWidth())
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Lights", Modifier.weight(1f), style = MaterialTheme.typography.labelLarge)
                    TextButton({ selected = if (selected.size == store.devices.size) emptySet() else store.devices.map { it.id }.toSet() }) { Text("Select all") }
                }
                store.devices.filter { it.isLight }.forEach { d ->
                    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(d.id in selected, role = Role.Checkbox) { selected = if (it) selected + d.id else selected - d.id }, verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(d.id in selected, null)
                        Column { Text(d.displayName); Text(statusLine(d), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    }
                }
            }
        },
        confirmButton = { TextButton({ if (store.saveLook(name, selected)) onDismiss() }, enabled = name.isNotBlank() && selected.isNotEmpty()) { Text("Save") } },
        dismissButton = { TextButton(onDismiss) { Text("Cancel") } })
}

@Composable
fun AutomationsScreen(store: HomeStore, modifier: Modifier) {
    var editing by remember { mutableStateOf<SceneSchedule?>(null) }
    val scenes = store.home.scenes
    Scaffold(modifier, floatingActionButton = {
        if (scenes.isNotEmpty()) ExtendedFloatingActionButton(onClick = { editing = SceneSchedule(sceneID = scenes.first().id, hour = 7, minute = 0) }, icon = { Icon(Icons.Outlined.Add, null) }, text = { Text("New schedule") })
    }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            item { Header("Automations", "Run a scene at a time of day.") }
            item {
                val context = androidx.compose.ui.platform.LocalContext.current
                androidx.lifecycle.compose.LifecycleResumeEffect(Unit) { store.refreshAlarmAccess(); onPauseOrDispose { } }
                when {
                    store.demo -> Banner("Demo schedules run only while Luma is open.")
                    store.syncStatus.paired -> Banner("These schedules run on ${store.syncStatus.runnerName ?: "the paired computer"}. Changes here sync to it.")
                    store.exactAlarms -> Banner("Schedules run on time, even when Luma is closed. Lights need to be on this Wi-Fi, or reachable through Govee cloud with your API key.")
                    else -> Column(Modifier.padding(horizontal = 16.dp, vertical = 6.dp)) {
                        Banner("Allow alarms so schedules run on time. Without it, Android can deliver them late and Luma skips runs more than 2 minutes late.")
                        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) TextButton({
                            context.startActivity(android.content.Intent(android.provider.Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, android.net.Uri.parse("package:${context.packageName}")))
                        }) { Text("Allow exact alarms") }
                    }
                }
            }
            if (scenes.isEmpty()) item { Banner("Save a scene first, then schedule it.") }
            store.homeConflicts.takeIf { it.isNotEmpty() }?.let { cs ->
                item { Banner("Possible conflict: " + cs.joinToString("; ") { "Govee Home's “${it.automation}” also changes ${it.light} at the same time" } + ". Turn one off so they don't fight.") }
            }
            items(store.home.schedules, key = { it.id }) { s ->
                val scene = scenes.firstOrNull { it.id == s.sceneID }
                Card(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp).clickable { editing = s }, colors = CardDefaults.cardColors(MaterialTheme.colorScheme.surfaceContainer)) {
                    Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("%02d:%02d".format(s.hour, s.minute), style = MaterialTheme.typography.headlineSmall)
                            Text("${scene?.name ?: "Missing scene"} · ${daysText(s.weekdays)}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Switch(s.enabled, { store.saveSchedule(s.copy(enabled = it)) }, Modifier.padding(start = 8.dp).semantics { contentDescription = "Schedule at %02d:%02d".format(s.hour, s.minute) })
                    }
                }
            }
            if (store.homeAutomations.isNotEmpty()) item {
                Section("In Govee Home (read-only)") {
                    store.homeAutomations.forEach { a ->
                        SettingRow(a.name, (a.times.joinToString(", ") { "%02d:%02d".format(it.hour, it.minute) } + " · " + (if (a.repeatDays.toSet() == (1..7).toSet()) "Every day" else "${a.repeatDays.size} days") + " · " + a.targets.joinToString(", ") { it.name }) + if (a.enabled) "" else " · Off")
                    }
                }
            }
            item { Spacer(Modifier.height(88.dp)) }
        }
    }
    editing?.let { s -> ScheduleDialog(store, s) { editing = null } }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ScheduleDialog(store: HomeStore, initial: SceneSchedule, onDismiss: () -> Unit) {
    val time = rememberTimePickerState(initial.hour, initial.minute)
    var sceneID by remember { mutableStateOf(initial.sceneID) }
    var days by remember { mutableStateOf(initial.weekdays.toSet()) }
    val existing = store.home.schedules.any { it.id == initial.id }
    AlertDialog(onDismissRequest = onDismiss, title = { Text(if (existing) "Edit schedule" else "New schedule") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                TimePicker(time)
                Text("Days", style = MaterialTheme.typography.labelLarge)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    dayNames.forEachIndexed { i, n -> FilterChip((i + 1) in days, { days = if ((i + 1) in days) days - (i + 1) else days + (i + 1) }, { Text(n) }) }
                }
                Text("Scene", style = MaterialTheme.typography.labelLarge)
                store.home.scenes.forEach { sc ->
                    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).selectable(sceneID == sc.id, role = Role.RadioButton) { sceneID = sc.id }, verticalAlignment = Alignment.CenterVertically) {
                        androidx.compose.material3.RadioButton(sceneID == sc.id, null); Text(sc.name)
                    }
                }
                if (existing) TextButton({ store.deleteSchedule(initial); onDismiss() }) { Text("Delete schedule", color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton({ store.saveSchedule(initial.copy(sceneID = sceneID, hour = time.hour, minute = time.minute, weekdays = days.sorted(), lastRunMinute = null)); onDismiss() }, enabled = days.isNotEmpty()) { Text("Save") }
        },
        dismissButton = { TextButton(onDismiss) { Text("Cancel") } })
}
