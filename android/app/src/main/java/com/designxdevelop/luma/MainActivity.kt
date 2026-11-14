package com.designxdevelop.luma

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.WbIncandescent
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import java.text.DateFormat
import kotlinx.coroutines.launch
import java.util.Date

class MainActivity : ComponentActivity() {
    private val store: HomeStore by viewModels()
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { LumaTheme { LumaRoot(store) } }
    }
}

// API-key copy shared with iOS, macOS and desktop (LightsView.swift, SettingsView.swift).
const val GOVEE_KEY_URL = "https://developer.govee.com/reference/apply-you-govee-api-key"
const val KEY_BENEFIT = "A free Govee API key adds cloud actions like effects and segments, and controls your lights when you're not on the same network."
const val LAN_WITHOUT_KEY = "LAN Control works without a key for lights on the same Wi-Fi. You need a free Govee API key for cloud actions and to control lights when you're not on their network."
const val NO_KEY_YET = "No key yet? In the Govee Home app, open Profile › Settings › Apply for API Key. Govee emails it to you, usually within minutes."

// Theme.swift values: neutral surfaces, one warm accent.
object LumaColors {
    val accentFill = Color(0xFFB95500)
    val success = Color(0xFF1D7543)
    val danger = Color(0xFFB52A25)
}

@Composable
fun LumaTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val scheme = if (dark) darkColorScheme(
        primary = LumaColors.accentFill, onPrimary = Color.White, secondary = Color(0xFFFFA347),
        background = Color(0xFF161618), surface = Color(0xFF161618), surfaceContainer = Color(0xFF202023),
        surfaceContainerHigh = Color(0xFF2A2A2E), surfaceContainerLow = Color(0xFF202023), surfaceContainerHighest = Color(0xFF333338), error = Color(0xFFFF6961),
        primaryContainer = Color(0xFF4A2A10), onPrimaryContainer = Color(0xFFFFD7B3), secondaryContainer = Color(0xFF4A2A10), onSecondaryContainer = Color(0xFFFFD7B3),
    ) else lightColorScheme(
        primary = LumaColors.accentFill, onPrimary = Color.White, secondary = Color(0xFFA84C00),
        background = Color(0xFFF5F5F7), surface = Color(0xFFF5F5F7), surfaceContainer = Color.White,
        surfaceContainerHigh = Color(0xFFF0F0F2), surfaceContainerLow = Color.White, surfaceContainerHighest = Color(0xFFE6E6EA), error = LumaColors.danger,
        primaryContainer = Color(0xFFF8E1CC), onPrimaryContainer = Color(0xFF5A2600), secondaryContainer = Color(0xFFF8E1CC), onSecondaryContainer = Color(0xFF5A2600),
    )
    MaterialTheme(colorScheme = scheme, content = content)
}

private enum class Tab(val title: String) { Home("Home"), Scenes("Scenes"), Automations("Automations"), Settings("Settings") }

@Composable
fun LumaRoot(store: HomeStore) {
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(store.message) { store.message?.let { snackbar.showSnackbar(it); store.message = null } }
    if (!store.onboarded) {
        Scaffold(snackbarHost = { SnackbarHost(snackbar) }) { Onboarding(store, Modifier.padding(it)) }
        return
    }
    var tab by rememberSaveable { mutableStateOf(Tab.Home) }
    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        bottomBar = {
            NavigationBar {
                Tab.entries.forEach { t ->
                    val icon = when (t) { Tab.Home -> Icons.Outlined.Home; Tab.Scenes -> Icons.Outlined.AutoAwesome; Tab.Automations -> Icons.Outlined.Schedule; Tab.Settings -> Icons.Outlined.Settings }
                    NavigationBarItem(selected = tab == t, onClick = { tab = t }, icon = { Icon(icon, null) }, label = { Text(t.title) })
                }
            }
        },
    ) { padding ->
        val m = Modifier.padding(padding)
        when (tab) {
            Tab.Home -> HomeScreen(store, m)
            Tab.Scenes -> ScenesScreen(store, m)
            Tab.Automations -> AutomationsScreen(store, m)
            Tab.Settings -> SettingsScreen(store, m)
        }
    }
}

@Composable
private fun Onboarding(store: HomeStore, modifier: Modifier) {
    var key by rememberSaveable { mutableStateOf("") }
    Column(
        modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        androidx.compose.foundation.layout.Box(contentAlignment = Alignment.Center) {
            AmbientGlow(ColorPresets.map { rgbColor(it.second) }.filterIndexed { i, _ -> i % 2 == 0 }, Modifier.fillMaxWidth().height(180.dp))
            Icon(Icons.Outlined.WbIncandescent, null, tint = Color.White, modifier = Modifier.size(84.dp)
                .background(androidx.compose.ui.graphics.Brush.linearGradient(listOf(Color(0xFFFFB347), Color(0xFFB95500))), androidx.compose.foundation.shape.RoundedCornerShape(24.dp)).padding(18.dp))
        }
        Text("Welcome to Luma", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
        Text("Control your Govee lights by room. The API key is optional: local lights work without one.",
            style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        val uri = LocalUriHandler.current
        Card(Modifier.widthIn(max = 480.dp).fillMaxWidth(), colors = CardDefaults.cardColors(MaterialTheme.colorScheme.surfaceContainer)) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Connect your account", style = MaterialTheme.typography.titleMedium)
                Text(KEY_BENEFIT, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton({ uri.openUri(GOVEE_KEY_URL) }, Modifier.height(48.dp)) { Text("Get a free API key ↗") }
                OutlinedTextField(key, { key = it }, Modifier.fillMaxWidth(), label = { Text("Govee API key") }, singleLine = true,
                    visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                Text(NO_KEY_YET, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Button({ store.connect(key) }, Modifier.fillMaxWidth().height(48.dp), enabled = key.isNotBlank()) { Text("Connect") }
            }
        }
        Card(Modifier.widthIn(max = 480.dp).fillMaxWidth(), colors = CardDefaults.cardColors(MaterialTheme.colorScheme.surfaceContainer)) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Add local control", style = MaterialTheme.typography.titleMedium)
                Text("No API key needed. Turn on LAN Control for each light in the Govee Home app, then look for lights on this Wi-Fi.",
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedButton({ store.useLanOnly() }, Modifier.fillMaxWidth().height(48.dp)) { Text("Look for lights on this Wi-Fi") }
            }
        }
        TextButton({ store.enterDemo() }, Modifier.height(48.dp)) { Text("Try demo") }
    }
}

@Composable
fun Section(title: String, content: @Composable () -> Unit) {
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text(title.uppercase(), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 4.dp, bottom = 6.dp))
        Card(colors = CardDefaults.cardColors(MaterialTheme.colorScheme.surfaceContainer)) { Column(Modifier.padding(vertical = 4.dp)) { content() } }
    }
}

@Composable
fun SettingRow(title: String, detail: String? = null, trailing: @Composable () -> Unit = {}) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            detail?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        trailing()
    }
}

@Composable
private fun SettingsScreen(store: HomeStore, modifier: Modifier) {
    var keyDialog by remember { mutableStateOf(false) }
    var pairDialog by remember { mutableStateOf(false) }
    var syncScreen by remember { mutableStateOf(false) }
    var bluetoothScreen by remember { mutableStateOf(false) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { it?.let(store::exportBackup) }
    val import = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { it?.let(store::importBackup) }
    val time = DateFormat.getTimeInstance(DateFormat.SHORT)
    LazyColumn(modifier.fillMaxSize()) {
        item { Text("Settings", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = 20.dp, top = 20.dp, bottom = 8.dp)) }
        item {
            Section("Connections") {
                SettingRow("Govee cloud", when { store.demo -> "Not used in the demo home"; store.hasKey -> "Connected · key stored encrypted on this phone"; else -> "Not connected" }) {
                    if (!store.demo) TextButton({ keyDialog = true }) { Text(if (store.hasKey) "Change" else "Add key") }
                }
                if (store.hasKey && !store.demo) SettingRow("Remove API key", "Lights found on the local network keep working.") { TextButton(store::removeKey) { Text("Remove", color = MaterialTheme.colorScheme.error) } }
                HorizontalDivider(Modifier.padding(horizontal = 16.dp))
                val onLan = store.devices.count { it.ip != null }
                SettingRow("Local network", if (store.demo) "Disabled in the demo home" else "$onLan ${if (onLan == 1) "light" else "lights"} on this network" + (store.lastScan?.let { " · scanned ${time.format(Date(it))}" } ?: "")) {
                    if (!store.demo) TextButton(store::refresh) { Text("Scan now") }
                }
                HorizontalDivider(Modifier.padding(horizontal = 16.dp))
                SettingRow("Demo home", if (store.demo) "Sample lights; nothing real is controlled." else "Explore Luma with sample lights.") {
                    TextButton({ if (store.demo) store.leaveDemo() else store.enterDemo() }) { Text(if (store.demo) "Leave demo" else "Explore demo") }
                }
            }
        }
        item {
            Section("Sync & Bluetooth") {
                SettingRow("Sync lights to a TV or music", "Camera, or microphone. Uses lights on this Wi-Fi.") { TextButton({ syncScreen = true }) { Text("Open") } }
                SettingRow("Bluetooth lights", "Govee TV backlights, controlled directly over Bluetooth.") { TextButton({ bluetoothScreen = true }) { Text("Open") } }
            }
        }
        item {
            Section("Schedule sync") {
                val sync = store.syncStatus
                if (sync.paired) {
                    SettingRow("Paired with ${sync.runnerName ?: sync.host}", buildString {
                        append("Schedules run on that computer; this phone shows and edits them.")
                        sync.lastSync?.let { append(" Synced ${time.format(Date(it))}.") }
                        sync.lastError?.let { append(" $it") }
                    }) { TextButton({ scope.launch { store.syncNow() } }) { Text("Sync now") } }
                    sync.runs.lastOrNull()?.let { r -> SettingRow("Last run: ${r.status}", listOfNotNull(time.format(Date(r.at)), r.detail).joinToString(" · ")) }
                    SettingRow("Turn off", "Schedules here are turned off so nothing runs twice.") { TextButton(store::unpair) { Text("Turn off", color = MaterialTheme.colorScheme.error) } }
                } else {
                    SettingRow("Pair with a computer", if (store.demo) "Not available in the demo home" else "A Mac or PC running Luma can run schedules for this phone, even when the phone is off.") {
                        if (!store.demo) TextButton({ pairDialog = true }) { Text("Pair") }
                    }
                }
            }
        }
        item { GoveeHomeSection(store) }
        item {
            Section("Backup") {
                SettingRow("Export home", "Scenes, schedules, names and rooms. No keys.") { TextButton({ export.launch("Luma backup.json") }) { Text("Export") } }
                SettingRow("Import backup", "Replaces scenes and schedules.") { TextButton({ import.launch(arrayOf("application/json", "text/plain", "*/*")) }) { Text("Import") } }
            }
        }
        item { Section("Activity") { if (store.log.isEmpty()) SettingRow("Nothing yet") } }
        items(store.log.take(30)) { e ->
            Text("${time.format(Date(e.time))}  ${e.text}", style = MaterialTheme.typography.bodySmall,
                color = if (e.error) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 24.dp, vertical = 3.dp))
        }
        item {
            Section("About") {
                SettingRow("Luma for Android", "Version ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
                SettingRow("Open source", "Luma is an open-source project built by Design X Develop LLC. Provided as is, without warranty.")
            }
            Spacer(Modifier.height(24.dp))
        }
    }
    if (syncScreen) SyncScreen(store) { syncScreen = false }
    if (bluetoothScreen) BluetoothScreen { bluetoothScreen = false }
    if (pairDialog) {
        var code by remember { mutableStateOf("") }
        AlertDialog(onDismissRequest = { pairDialog = false }, title = { Text("Pair with a computer") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("On the computer, open Luma → Settings → Schedule sync and copy its pairing code. The phone and computer must be on the same network.", style = MaterialTheme.typography.bodyMedium)
                    OutlinedTextField(code, { code = it }, label = { Text("Pairing code") }, placeholder = { Text("luma1/…") }, minLines = 2)
                }
            },
            confirmButton = { TextButton({ store.pair(code); pairDialog = false }, enabled = code.isNotBlank()) { Text("Pair") } },
            dismissButton = { TextButton({ pairDialog = false }) { Text("Cancel") } })
    }
    if (keyDialog) {
        var key by remember { mutableStateOf("") }
        AlertDialog(onDismissRequest = { keyDialog = false }, title = { Text("Govee API key") },
            text = {
                val uri = LocalUriHandler.current
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(LAN_WITHOUT_KEY, style = MaterialTheme.typography.bodyMedium)
                    OutlinedTextField(key, { key = it }, singleLine = true, label = { Text("API key") }, visualTransformation = PasswordVisualTransformation())
                    Text(NO_KEY_YET, style = MaterialTheme.typography.bodySmall)
                    TextButton({ uri.openUri(GOVEE_KEY_URL) }) { Text("Get a free API key ↗") }
                }
            },
            confirmButton = { TextButton({ store.connect(key); keyDialog = false }, enabled = key.isNotBlank()) { Text("Save") } },
            dismissButton = { TextButton({ keyDialog = false }) { Text("Cancel") } })
    }
}
