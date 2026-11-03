package com.designxdevelop.luma

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import java.text.DateFormat
import java.util.Date

class MainActivity : ComponentActivity() {
    private val store: HomeStore by viewModels()
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { LumaTheme { LumaRoot(store) } }
    }
}

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
        surfaceContainerHigh = Color(0xFF2A2A2E), surfaceContainerLow = Color(0xFF202023), error = Color(0xFFFF6961),
    ) else lightColorScheme(
        primary = LumaColors.accentFill, onPrimary = Color.White, secondary = Color(0xFFA84C00),
        background = Color(0xFFF5F5F7), surface = Color(0xFFF5F5F7), surfaceContainer = Color.White,
        surfaceContainerHigh = Color(0xFFF0F0F2), surfaceContainerLow = Color.White, error = LumaColors.danger,
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
        Icon(Icons.Outlined.WbIncandescent, null, Modifier.size(56.dp), tint = MaterialTheme.colorScheme.secondary)
        Text("Welcome to Luma", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)
        Text("Control your Govee lights by room. Connect your Govee account to load every light, or look for lights on this Wi-Fi network.",
            style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Card(Modifier.widthIn(max = 480.dp).fillMaxWidth(), colors = CardDefaults.cardColors(MaterialTheme.colorScheme.surfaceContainer)) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Connect Govee", style = MaterialTheme.typography.titleMedium)
                Text("In the Govee Home app: Profile → Settings → Apply for API key. Luma stores the key encrypted on this phone.",
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedTextField(key, { key = it }, Modifier.fillMaxWidth(), label = { Text("Govee API key") }, singleLine = true,
                    visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                Button({ store.connect(key) }, Modifier.fillMaxWidth().height(48.dp), enabled = key.isNotBlank()) { Text("Connect") }
            }
        }
        OutlinedButton({ store.useLanOnly() }, Modifier.widthIn(max = 480.dp).fillMaxWidth().height(48.dp)) { Text("Use local network only") }
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
    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { it?.let(store::exportBackup) }
    val import = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { it?.let(store::importBackup) }
    val time = DateFormat.getTimeInstance(DateFormat.SHORT)
    LazyColumn(modifier.fillMaxSize()) {
        item { Text("Settings", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 20.dp, top = 20.dp, bottom = 8.dp)) }
        item {
            Section("Connections") {
                SettingRow("Govee cloud", when { store.demo -> "Not used in the demo home"; store.hasKey -> "Connected · key stored encrypted on this phone"; else -> "Not connected" }) {
                    if (!store.demo) TextButton({ keyDialog = true }) { Text(if (store.hasKey) "Change" else "Add key") }
                }
                if (store.hasKey && !store.demo) SettingRow("Remove API key", "Lights found on the local network keep working.") { TextButton(store::removeKey) { Text("Remove", color = MaterialTheme.colorScheme.error) } }
                HorizontalDivider(Modifier.padding(horizontal = 16.dp))
                val onLan = store.devices.count { it.ip != null }
                SettingRow("Local network", if (store.demo) "Disabled in the demo home" else "$onLan lights on this network" + (store.lastScan?.let { " · scanned ${time.format(Date(it))}" } ?: "")) {
                    if (!store.demo) TextButton(store::refresh) { Text("Scan now") }
                }
                HorizontalDivider(Modifier.padding(horizontal = 16.dp))
                SettingRow("Demo home", if (store.demo) "Sample lights; nothing real is controlled." else "Explore Luma with sample lights.") {
                    TextButton({ if (store.demo) store.leaveDemo() else store.enterDemo() }) { Text(if (store.demo) "Leave demo" else "Explore demo") }
                }
            }
        }
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
    if (keyDialog) {
        var key by remember { mutableStateOf("") }
        AlertDialog(onDismissRequest = { keyDialog = false }, title = { Text("Govee API key") },
            text = { OutlinedTextField(key, { key = it }, singleLine = true, label = { Text("API key") }, visualTransformation = PasswordVisualTransformation()) },
            confirmButton = { TextButton({ store.connect(key); keyDialog = false }, enabled = key.isNotBlank()) { Text("Save") } },
            dismissButton = { TextButton({ keyDialog = false }) { Text("Cancel") } })
    }
}
