package com.designxdevelop.luma

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

/** Settings rows for the read-only Govee Home import (rooms, DreamView groups, automations). */
@Composable
fun GoveeHomeSection(store: HomeStore) {
    var signIn by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val file = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { it?.let(store::importGoveeHomeFile) }
    Section("Govee Home account") {
        val signedIn = !store.demo && store.goveeHomeSignedIn
        SettingRow("Rooms, groups and automations", when {
            store.demo -> "Sample data in the demo home"
            signedIn -> "Signed in. ${store.homeGroups.size} groups, ${store.homeAutomations.size} automations."
            else -> "Optional: read your Govee Home rooms, DreamView groups and automations. Luma never changes them."
        }) {
            if (!store.demo) TextButton({ if (signedIn) scope.launch { store.importGoveeHome() } else signIn = true }) { Text(if (signedIn) "Import" else "Sign in") }
        }
        if (signedIn) SettingRow("Sign out of Govee Home") { TextButton(store::signOutGoveeHome) { Text("Sign out") } }
        if (!store.demo) SettingRow("Import a device-list file", "A saved GET /bff-app/v1/device/list response: rooms only.") { TextButton({ file.launch(arrayOf("application/json", "*/*")) }) { Text("Choose") } }
    }
    if (signIn) SignInDialog(store) { signIn = false }
    store.homePlan?.let { HomePlanDialog(store, it) }
}

@Composable
private fun SignInDialog(store: HomeStore, onDismiss: () -> Unit) {
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var needsCode by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    AlertDialog(onDismissRequest = onDismiss, title = { Text("Sign in to Govee Home") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Luma only reads rooms, groups and automations. Your password goes to Govee and isn't stored; the session is sealed on this phone.", style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(email, { email = it }, singleLine = true, label = { Text("Email") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email))
                OutlinedTextField(password, { password = it }, singleLine = true, label = { Text("Password") }, visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                if (needsCode) OutlinedTextField(code, { code = it }, singleLine = true, label = { Text("Code from Govee's email") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
            }
        },
        confirmButton = {
            TextButton({
                busy = true
                scope.launch {
                    val again = store.signInGoveeHome(email, password, code.takeIf { needsCode })
                    busy = false
                    if (again) needsCode = true else if (store.goveeHomeSignedIn) onDismiss()
                }
            }, enabled = !busy && email.isNotBlank() && password.isNotBlank() && (!needsCode || code.isNotBlank())) { Text(if (busy) "Signing in…" else "Sign in") }
        },
        dismissButton = { TextButton(onDismiss) { Text("Cancel") } })
}

@Composable
private fun HomePlanDialog(store: HomeStore, plan: com.designxdevelop.luma.core.GoveeHomeImport.Plan) {
    var picked by remember(plan) { mutableStateOf(plan.changes.filter { it.selectedByDefault }.map { it.deviceID }.toSet()) }
    AlertDialog(onDismissRequest = { store.homePlan = null }, title = { Text("Govee Home rooms") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(listOfNotNull("${plan.unchanged} already match", plan.withoutRoom.takeIf { it > 0 }?.let { "$it have no room" },
                    plan.notInLuma.size.takeIf { it > 0 }?.let { "$it aren't in Luma yet" }, plan.groups.size.takeIf { it > 0 }?.let { "$it groups" },
                    plan.automations.size.takeIf { it > 0 }?.let { "$it automations" }).joinToString(" · "), style = MaterialTheme.typography.bodySmall)
                if (plan.unavailable.isNotEmpty()) Text("Couldn't read ${plan.unavailable.joinToString(" and ")}; the last import is kept.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                if (plan.changes.isEmpty()) Text("No room changes.")
                plan.changes.forEach { c ->
                    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable { picked = if (c.deviceID in picked) picked - c.deviceID else picked + c.deviceID }, verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(c.deviceID in picked, null)
                        Column { Text(c.name); Text("${c.currentRoom} → ${c.goveeRoom}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    }
                }
            }
        },
        confirmButton = { TextButton({ store.applyRooms(plan.changes.filter { it.deviceID in picked }) }) { Text(if (picked.isEmpty()) "Done" else "Apply ${picked.size}") } },
        dismissButton = { TextButton({ store.homePlan = null }) { Text("Cancel") } })
}
