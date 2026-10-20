package com.smartmenukj.app.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.smartmenukj.app.BuildConfig
import com.smartmenukj.core.store.StoreState
import java.text.DateFormat
import java.util.Date

@Composable
fun SettingsScreen(state: StoreState) {
    val store = LocalStore.current
    val nav = LocalNav.current
    val app = LocalApp.current
    val p = palette
    val settings by app.prefs.settings.collectAsStateWithLifecycle()
    val open = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        val text = app.backup.read(uri)
        val msg = try {
            if (text == null) "Could not read that file."
            else store.importAll(text).let { n -> if (n == 1) "Your home is back." else "$n homes are back." }
        } catch (e: Exception) {
            e.message ?: "That is not a SmartHomeKJ backup."
        }
        app.messages.tryEmit(msg)
    }
    val save = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        if (uri != null) app.messages.tryEmit(if (app.backup.writeTo(uri)) "Saved a copy of every home." else "Could not save there.")
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).statusBarsPadding().navigationBarsPadding()
        .padding(horizontal = 20.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 8.dp)) {
            IconButton(onClick = { nav.settings = false }) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back", tint = p.text) }
            DotText("Settings", 30)
        }
        SectionLabel("Look")
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for ((mode, label) in listOf("dark" to "Dark", "light" to "Light", "system" to "Like the phone")) {
                NChip(label, selected = state.data.themeMode == mode) { store.setTheme(mode) }
            }
        }
        SettingRow("24-hour clock", icon = Icons.Outlined.Schedule) { NSwitch(settings.clock24) { v -> app.prefs.update { it.copy(clock24 = v) } } }
        SectionLabel("Devices")
        Text("Check devices every", style = NType.body(14.sp, p.textDim))
        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (s in listOf(5, 10, 30, 60)) NChip("$s s", selected = settings.checkSeconds == s) {
                app.prefs.update { it.copy(checkSeconds = s) }
                store.startPolling(s)
            }
        }
        SectionLabel("Your homes")
        SettingRow("Bring your home from the other app", "Open SmartHomeKJ-backup.json from Downloads/SmartHomeKJ (SmartHomeKJ before), or any backup",
            Icons.Outlined.FileOpen, onClick = { open.launch(arrayOf("application/json", "text/plain", "application/octet-stream")) })
        SettingRow("Save a copy", "Every home in one file", Icons.Outlined.SaveAlt, onClick = { save.launch("SmartHomeKJ-backup.json") })
        SettingRow(
            "Keep a backup in Downloads",
            if (app.backup.savedAt > 0) "Last saved ${DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(app.backup.savedAt))}"
            else "Downloads/SmartHomeKJ, so a new install can take your homes back",
            Icons.Outlined.Backup,
        ) { NSwitch(settings.autoBackup) { v -> app.prefs.update { it.copy(autoBackup = v) }; if (v) app.backup.soon() } }
        SettingRow("Homes", "${state.homes.size} · ${state.home?.name ?: ""}", Icons.Outlined.Home, onClick = { nav.homes = true })
        SectionLabel("About")
        SettingRow("SmartHomeKJ native ${BuildConfig.VERSION_NAME}", "Kotlin and Jetpack Compose. Free, and everything stays on your phone.", Icons.Outlined.Info)
        Spacer(Modifier.height(8.dp))
        Text("How it works: tap a device to switch it, hold it for all its controls, drag sideways across a tile to dim. " +
            "On the map, tap Edit to draw rooms, drag them, and resize them from the corner.",
            style = NType.body(13.sp, p.textDim))
        Spacer(Modifier.height(28.dp))
    }
}
