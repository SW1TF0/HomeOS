package com.smartmenukj.app.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.smartmenukj.app.platform.Scan
import com.smartmenukj.core.integrations.Catalog
import com.smartmenukj.core.integrations.FoundService
import com.smartmenukj.core.integrations.IntegrationSpec
import com.smartmenukj.core.integrations.parseHosts
import com.smartmenukj.core.json.textOrNull
import com.smartmenukj.core.model.IntegrationConfig
import com.smartmenukj.core.store.StoreState
import kotlinx.coroutines.launch

/** Connections: what is connected, Scan network, and every kind of connection that can be added. */
@Composable
fun ConnectScreen(state: StoreState) {
    val store = LocalStore.current
    val nav = LocalNav.current
    val p = palette
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val scan = remember { Scan(context.applicationContext) }
    var scanning by remember { mutableStateOf(false) }
    val found = remember { mutableStateListOf<FoundService>() }
    var adding by remember { mutableStateOf<Pair<IntegrationSpec, FoundService?>?>(null) }
    val d = state.data

    Column(Modifier.fillMaxSize()) {
        ScreenTitle("Connect")
        LazyColumn(contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            item {
                NCard(inverted = true, padding = PaddingValues(18.dp), onClick = {
                    if (!scanning) {
                        scanning = true
                        found.clear()
                        scope.launch {
                            try {
                                scan.run { f -> if (d.integrations.none { known(it, f) }) found += f }
                            } finally {
                                scanning = false
                            }
                        }
                    }
                }) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.Radar, null, tint = p.background)
                        Spacer(Modifier.width(14.dp))
                        Column(Modifier.weight(1f)) {
                            Text(if (scanning) "Looking around your Wi-Fi…" else "Scan network", style = NType.body(16.sp, p.background, 500))
                            Text("Finds Hue, Shelly, WLED, Tasmota, ESPHome and Home Assistant", style = NType.body(13.sp, p.background.copy(alpha = 0.65f)))
                        }
                        if (scanning) CircularProgressIndicator(color = Palette.Accent, strokeWidth = 2.dp, modifier = Modifier.size(22.dp))
                    }
                }
            }
            if (!scanning && found.isEmpty() && scan.localAddress() == null) item {
                Text("This phone is not on Wi-Fi, so Scan network only asks the Hue service. Join your home Wi-Fi to find everything.",
                    style = NType.body(13.sp, p.textDim))
            }
            if (found.isNotEmpty()) {
                item { SectionLabel("Found · ${found.size}", accent = true) }
                items(found.toList(), key = { it.key }) { f ->
                    val spec = Catalog.spec(f.integrationType) ?: return@items
                    NCard(padding = PaddingValues(16.dp), onClick = { adding = spec to f }) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(integrationIcon(spec.icon), null, tint = p.text)
                            Spacer(Modifier.width(14.dp))
                            Column(Modifier.weight(1f)) {
                                Text(f.name, style = NType.body(15.sp, p.text, 500))
                                Text("${spec.name} · ${f.host}", style = NType.body(13.sp, p.textDim))
                            }
                            Icon(Icons.Outlined.Add, "Add", tint = p.text)
                        }
                    }
                }
            }
            val connected = d.integrations
            if (connected.isNotEmpty()) {
                item { SectionLabel("Connected · ${connected.size}") }
                items(connected, key = { it.id }) { cfg ->
                    val spec = Catalog.spec(cfg.type)
                    val st = state.status[cfg.id]
                    val count = d.devices.count { it.integrationId == cfg.id }
                    NCard(padding = PaddingValues(16.dp), onClick = { nav.integration = cfg.id }) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(integrationIcon(spec?.icon ?: ""), null, tint = p.text)
                            Spacer(Modifier.width(14.dp))
                            Column(Modifier.weight(1f)) {
                                Text(cfg.name, style = NType.body(15.sp, p.text, 500))
                                Text(
                                    when {
                                        spec == null -> "${Catalog.laterNames[cfg.type] ?: cfg.type} · not in this version yet"
                                        st?.ok == false -> st.message
                                        else -> "$count devices"
                                    },
                                    style = NType.body(13.sp, if (st?.ok == false) Palette.Red else p.textDim),
                                    maxLines = 2,
                                )
                            }
                            if (cfg.id in state.busy) CircularProgressIndicator(color = Palette.Accent, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
                            else Box(Modifier.size(8.dp).background(if (spec == null || st?.ok == false) Palette.Red else p.textDim, CircleShape))
                        }
                    }
                }
            }
            item { SectionLabel("Add a connection") }
            items(Catalog.specs, key = { it.type }) { spec ->
                NCard(padding = PaddingValues(16.dp), onClick = {
                    if (spec.fields.isEmpty()) {
                        val cfg = store.addIntegration(spec.type)
                        nav.integration = cfg.id
                    } else adding = spec to null
                }) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(integrationIcon(spec.icon), null, tint = p.text)
                        Spacer(Modifier.width(14.dp))
                        Column(Modifier.weight(1f)) {
                            Text(spec.name, style = NType.body(15.sp, p.text, 500))
                            Text(spec.tagline, style = NType.body(13.sp, p.textDim))
                        }
                        Icon(Icons.Outlined.ChevronRight, null, tint = p.textDim)
                    }
                }
            }
            item {
                Text("Coming to the native app next: Matter, MQTT and Zigbee2MQTT, TVs and other network devices, cameras, and control from anywhere. The other SmartMenuKJ app has them today.",
                    style = NType.body(12.sp, p.textDim), modifier = Modifier.padding(top = 8.dp))
            }
        }
    }
    adding?.let { (spec, f) ->
        AddIntegrationSheet(spec, f, onDismiss = { adding = null }) { cfgId ->
            adding = null
            f?.let { found.remove(it) }
            nav.integration = cfgId
        }
    }
}

/** Whether a connection already has the address that was found. */
private fun known(cfg: IntegrationConfig, f: FoundService) = cfg.settings.values
    .flatMap { parseHosts(it.textOrNull() ?: "") }
    .any { it.substringBefore('/').substringBefore(':') == f.host }

/** The form for a new connection, filled in from what Scan network found. Saving searches it for devices. */
@Composable
private fun AddIntegrationSheet(spec: IntegrationSpec, found: FoundService?, onDismiss: () -> Unit, onAdded: (String) -> Unit) {
    val store = LocalStore.current
    val p = palette
    val scope = rememberCoroutineScope()
    val values = remember {
        mutableStateMapOf<String, String>().apply {
            for (f in spec.fields) put(f.key, f.defaultValue ?: "")
            if (found != null) {
                when {
                    spec.fields.any { it.key == "hosts" } -> put("hosts", found.address)
                    spec.fields.any { it.key == "host" } -> put("host", found.address)
                    spec.fields.any { it.key == "url" } -> put("url", found.address)
                }
            }
        }
    }
    NSheet(onDismiss) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(integrationIcon(spec.icon), null, tint = p.text)
            Spacer(Modifier.width(12.dp))
            DotText(spec.name, 26)
        }
        Spacer(Modifier.height(8.dp))
        Text(spec.description, style = NType.body(14.sp, p.textDim))
        Spacer(Modifier.height(16.dp))
        for (f in spec.fields) {
            NTextField(values[f.key] ?: "", { values[f.key] = it }, f.label + if (f.required) "" else " (optional)",
                hint = f.hint, secret = f.secret, multiline = f.multiline)
            Spacer(Modifier.height(10.dp))
        }
        val ready = spec.fields.filter { it.required }.all { !values[it.key].isNullOrBlank() }
        PrimaryButton(if (spec.canPair) "Add and pair" else "Add and search", {
            val cfg = store.addIntegration(spec.type, found?.name?.takeIf { spec.type != "homeassistant" } ?: spec.name, values.toMap())
            onAdded(cfg.id)
            scope.launch {
                if (spec.canPair && values["username"].isNullOrBlank()) {
                    if (store.pair(cfg.id)) store.sync(cfg.id)
                } else store.sync(cfg.id)
            }
        }, enabled = ready, modifier = Modifier.fillMaxWidth())
        if (spec.canPair) {
            Spacer(Modifier.height(8.dp))
            Text("Press the round link button on the bridge first, then tap Add and pair within 30 seconds.",
                style = NType.body(13.sp, p.textDim))
        }
    }
}

/** One connection: its devices, search again, pair, settings, remove. */
@Composable
fun IntegrationSheet(state: StoreState, id: String, onDismiss: () -> Unit) {
    val store = LocalStore.current
    val nav = LocalNav.current
    val p = palette
    val scope = rememberCoroutineScope()
    val cfg = state.data.integration(id)
    if (cfg == null) {
        LaunchedEffect(Unit) { onDismiss() }
        return
    }
    val spec = Catalog.spec(cfg.type)
    val devices = state.data.devices.filter { it.integrationId == id }
    var editing by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf(false) }
    val values = remember(cfg) { mutableStateMapOf<String, String>().apply { spec?.fields?.forEach { put(it.key, cfg.setting(it.key)) } } }
    var name by remember(cfg) { mutableStateOf(cfg.name) }
    val busy = id in state.busy
    NSheet(onDismiss) {
        DotText(cfg.name, 26)
        val st = state.status[id]
        Text(
            when {
                spec == null -> "${Catalog.laterNames[cfg.type] ?: cfg.type} does not work in the native app yet. Its ${devices.size} devices are kept as they are."
                busy -> "Working…"
                st?.ok == false -> st.message
                else -> "${devices.size} devices"
            },
            style = NType.body(14.sp, if (st?.ok == false) Palette.Red else p.textDim),
        )
        Spacer(Modifier.height(14.dp))
        if (spec != null) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (spec.fields.isNotEmpty() || !spec.manualDevices) {
                    NChip("Search again", icon = Icons.Outlined.Refresh) { scope.launch { store.sync(id) } }
                }
                if (spec.canPair) NChip("Pair", icon = Icons.Outlined.Link) { scope.launch { if (store.pair(id)) store.sync(id) } }
                if (spec.fields.isNotEmpty()) NChip("Settings", selected = editing, icon = Icons.Outlined.Tune) { editing = !editing }
            }
        }
        if (editing && spec != null) {
            Spacer(Modifier.height(14.dp))
            NTextField(name, { name = it }, "Name")
            Spacer(Modifier.height(10.dp))
            for (f in spec.fields) {
                NTextField(values[f.key] ?: "", { values[f.key] = it }, f.label, hint = f.hint, secret = f.secret, multiline = f.multiline)
                Spacer(Modifier.height(10.dp))
            }
            PrimaryButton("Save and search", {
                store.updateIntegration(id, name, values.toMap())
                editing = false
                scope.launch { store.sync(id) }
            })
        }
        if (devices.isNotEmpty()) {
            SectionLabel("Devices")
            for (dev in devices) {
                SettingRow(dev.name, listOfNotNull(state.roomName(dev.roomId) ?: "No room yet", com.smartmenukj.core.model.Describe.state(dev)).joinToString(" · "),
                    deviceIcon(dev.kind), onClick = { nav.device = dev.id })
            }
        }
        if (spec?.manualDevices == true) {
            Spacer(Modifier.height(10.dp))
            Text("Add virtual devices on the Devices tab.", style = NType.body(13.sp, p.textDim))
        }
        Spacer(Modifier.height(18.dp))
        SecondaryButton(if (confirm) "Tap again to remove it and its devices" else "Remove connection", {
            if (confirm) { store.removeIntegration(id); onDismiss() } else confirm = true
        })
    }
}
