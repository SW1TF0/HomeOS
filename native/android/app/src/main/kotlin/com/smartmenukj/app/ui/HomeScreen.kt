package com.smartmenukj.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridItemSpanScope
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.smartmenukj.core.model.*
import com.smartmenukj.core.store.Seed
import com.smartmenukj.core.store.StoreState
import kotlinx.coroutines.delay
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun HomeScreen(state: StoreState) {
    val store = LocalStore.current
    val nav = LocalNav.current
    val p = palette
    val d = state.data
    val favorites = d.devices.filter { it.favorite }
    val active = d.devices.count { it.countsAsOn }
    val span: LazyGridItemSpanScope.() -> GridItemSpan = { GridItemSpan(maxLineSpan) }

    LazyVerticalGrid(
        columns = GridCells.Adaptive(160.dp),
        contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 28.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.fillMaxSize().statusBarsPadding(),
    ) {
        item(span = { GridItemSpan(maxLineSpan) }) {
            Column {
                Row(Modifier.fillMaxWidth().padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Row(Modifier.weight(1f).clip(androidx.compose.foundation.shape.RoundedCornerShape(8.dp))
                        .clickable { nav.homes = true }.padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Text((state.home?.name ?: "My home").uppercase(), style = NType.label(p.text), maxLines = 1,
                            overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                        Spacer(Modifier.width(8.dp))
                        Box(Modifier.size(6.dp).background(Palette.Red, CircleShape))
                        Spacer(Modifier.width(4.dp))
                        Icon(Icons.Outlined.UnfoldMore, null, tint = p.textDim, modifier = Modifier.size(16.dp))
                    }
                    ProfileButton()
                }
                Spacer(Modifier.height(8.dp))
                Clock()
                Spacer(Modifier.height(8.dp))
                Text(if (active == 0) "Everything is off." else "$active of ${d.devices.size} devices active.",
                    style = NType.body(16.sp, p.textDim))
                Spacer(Modifier.height(14.dp))
                StatusStrip(d)
                if (Seed.isSample(d)) {
                    Spacer(Modifier.height(18.dp))
                    NCard(padding = PaddingValues(16.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Outlined.BlurOn, null, tint = p.text)
                            Spacer(Modifier.width(14.dp))
                            Text("This is a sample home to try. Connect your devices, or bring your home from the other SmartMenuKJ app in Settings.",
                                style = NType.body(14.sp, p.text), modifier = Modifier.weight(1f))
                        }
                        Spacer(Modifier.height(10.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            NChip("Connect devices", icon = Icons.Outlined.Hub) { nav.tab = Tab.Connect }
                            NChip("Start empty") { store.clearSample() }
                        }
                    }
                }
                SectionLabel("Scenes", trailing = { HeaderAction("All") { nav.tab = Tab.Scenes } })
                ScenesRow(d)
                SectionLabel("Favourites", accent = true, trailing = { HeaderAction("Devices") { nav.tab = Tab.Devices } })
                if (favorites.isEmpty()) {
                    NCard(padding = PaddingValues(16.dp), onClick = { nav.tab = Tab.Devices }) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Outlined.StarBorder, null, tint = p.text)
                            Spacer(Modifier.width(14.dp))
                            Text("Star the devices you use most to keep them here.", style = NType.body(14.sp, p.textDim),
                                modifier = Modifier.weight(1f))
                        }
                    }
                }
            }
        }
        items(favorites, key = { it.id }) { dev ->
            DeviceTile(dev, listOfNotNull(state.roomName(dev.roomId), Describe.state(dev)).joinToString(" · "),
                onToggle = { store.toggle(dev.id) }, onOpen = { nav.device = dev.id },
                onLevel = { v -> Describe.levelCommand(dev, v)?.let { store.command(dev.id, it) } })
        }
        item(span = span) {
            SectionLabel("Rooms", trailing = { HeaderAction("Edit") { nav.openMap(edit = true) } })
        }
        if (d.rooms.isEmpty()) {
            item(span = span) {
                NCard(padding = PaddingValues(16.dp), onClick = { nav.openMap(edit = true) }) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.AddHome, null, tint = p.text)
                        Spacer(Modifier.width(14.dp))
                        Text("Draw your rooms on the map to group your devices.", style = NType.body(14.sp, p.textDim),
                            modifier = Modifier.weight(1f))
                    }
                }
            }
        }
        items(d.rooms, key = { it.id }) { r -> RoomCard(d, r) { nav.room = r.id } }
    }
}

@Composable
private fun Clock() {
    val app = LocalApp.current
    val settings by app.prefs.settings.collectAsStateWithLifecycle()
    var now by remember { mutableStateOf(Date()) }
    LaunchedEffect(Unit) {
        while (true) {
            now = Date()
            delay(1000L * (60 - (now.time / 1000 % 60)).coerceAtLeast(1))
        }
    }
    val time = SimpleDateFormat(if (settings.clock24) "HH:mm" else "h:mm", Locale.getDefault()).format(now)
    val day = SimpleDateFormat("EEEE d MMMM", Locale.getDefault()).format(now)
    Column {
        DotText(time, 72)
        Text(day.uppercase(), style = NType.label(palette.textDim))
    }
}

/** Little facts about the home: temperature inside, lights on, doors locked. */
@Composable
private fun StatusStrip(d: HomeData) {
    val temp = Describe.averageTemperature(d.devices)
    val lights = d.devices.count { it.kind == DeviceKind.light && it.state.on == true }
    val locks = d.devices.filter { it.kind == DeviceKind.lock }
    val offline = d.devices.count { !it.state.reachable }
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (temp != null) Pill(Icons.Outlined.DeviceThermostat, "%.1f°".format(temp))
        Pill(Icons.Outlined.Lightbulb, if (lights == 0) "Lights off" else "$lights lights on")
        if (locks.isNotEmpty()) {
            val open = locks.count { it.state.locked == false }
            Pill(if (open == 0) Icons.Outlined.Lock else Icons.Outlined.LockOpen, if (open == 0) "All locked" else "$open unlocked", accent = open > 0)
        }
        if (offline > 0) Pill(Icons.Outlined.CloudOff, "$offline not responding", accent = true)
    }
}

@Composable
private fun Pill(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String, accent: Boolean = false) {
    val p = palette
    Row(Modifier.clip(CircleShape).background(p.surface).padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = if (accent) Palette.Red else p.text, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(text, style = NType.body(13.sp, p.text, 500))
    }
}

@Composable
fun ScenesRow(d: HomeData) {
    val store = LocalStore.current
    val nav = LocalNav.current
    val p = palette
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        for (s in d.scenes) {
            NCard(padding = PaddingValues(horizontal = 16.dp, vertical = 14.dp), radius = 20.dp,
                onClick = { store.runScene(s.id) }, onLongClick = { nav.scene = s.id }) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(sceneIcon(s.icon), null, tint = p.text, modifier = Modifier.size(20.dp))
                    Spacer(Modifier.width(10.dp))
                    Column {
                        Text(s.name, style = NType.body(14.sp, p.text, 500))
                        s.schedule?.let { Text("${it.time} · ${it.daysLabel}", style = NType.body(11.sp, p.textDim)) }
                    }
                }
            }
        }
        NCard(padding = PaddingValues(horizontal = 16.dp, vertical = 14.dp), radius = 20.dp,
            onClick = { nav.scene = NEW_SCENE }) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.Add, null, tint = p.textDim, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text("New scene", style = NType.body(14.sp, p.textDim, 500))
            }
        }
    }
}

const val NEW_SCENE = "__new__"

@Composable
private fun RoomCard(d: HomeData, r: Room, onClick: () -> Unit) {
    val p = palette
    val devices = d.devicesIn(r.id)
    val on = devices.count { it.countsAsOn }
    val temp = Describe.averageTemperature(devices)
    NCard(onClick = onClick, padding = PaddingValues(16.dp), modifier = Modifier.heightIn(min = 110.dp).dotGrid(p.dot, 12.dp)) {
        Row(verticalAlignment = Alignment.Top) {
            Text(r.name, style = NType.body(16.sp, p.text, 500), modifier = Modifier.weight(1f), maxLines = 1,
                overflow = TextOverflow.Ellipsis)
            if (on > 0) Box(Modifier.padding(top = 6.dp).size(8.dp).background(Palette.Red, CircleShape))
        }
        Spacer(Modifier.height(14.dp))
        Row(verticalAlignment = Alignment.Bottom) {
            DotText(if (temp != null) "%.0f°".format(temp) else "${devices.size}", 30)
            Spacer(Modifier.width(8.dp))
            Text(if (on == 0) "${devices.size} devices" else "$on on", style = NType.body(12.sp, p.textDim),
                modifier = Modifier.padding(bottom = 4.dp))
        }
    }
}
