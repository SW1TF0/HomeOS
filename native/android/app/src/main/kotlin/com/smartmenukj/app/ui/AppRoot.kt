package com.smartmenukj.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.smartmenukj.app.SmartMenuApp
import com.smartmenukj.core.store.HomeStore
import com.smartmenukj.core.store.StoreState

val LocalStore = staticCompositionLocalOf<HomeStore> { error("No store") }
val LocalApp = staticCompositionLocalOf<SmartMenuApp> { error("No app") }

@Composable
fun AppRoot(app: SmartMenuApp) {
    val state by app.store.state.collectAsStateWithLifecycle()
    val nav = remember { Nav() }
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(Unit) {
        app.messages.collect { snackbar.currentSnackbarData?.dismiss(); snackbar.showSnackbar(it) }
    }
    AppTheme(state.data.themeMode) {
        CompositionLocalProvider(LocalStore provides app.store, LocalNav provides nav, LocalApp provides app) {
            val p = palette
            Scaffold(
                containerColor = p.background,
                contentWindowInsets = WindowInsets(0, 0, 0, 0),
                snackbarHost = {
                    SnackbarHost(snackbar) { d ->
                        Snackbar(d, containerColor = p.text, contentColor = p.background, shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp))
                    }
                },
                bottomBar = { if (!nav.settings) BottomBar(nav) },
            ) { pad ->
                Box(Modifier.padding(pad).fillMaxSize().background(p.background)) {
                    if (!state.loaded) return@Box
                    when {
                        nav.settings -> SettingsScreen(state)
                        else -> when (nav.tab) {
                            Tab.Home -> HomeScreen(state)
                            Tab.Map -> MapScreen(state)
                            Tab.Devices -> DevicesScreen(state)
                            Tab.Scenes -> ScenesScreen(state)
                            Tab.Connect -> ConnectScreen(state)
                        }
                    }
                }
            }
            BackHandler(nav.settings || nav.tab != Tab.Home) {
                if (nav.settings) nav.settings = false else nav.tab = Tab.Home
            }
            nav.device?.let { id -> DeviceSheet(state, id) { nav.device = null } }
            nav.room?.let { id -> RoomSheet(state, id) { nav.room = null } }
            nav.scene?.let { id -> SceneEditor(state, id) { nav.scene = null } }
            nav.integration?.let { id -> IntegrationSheet(state, id) { nav.integration = null } }
            if (nav.homes) HomesSheet(state) { nav.homes = false }
        }
    }
}

@Composable
private fun BottomBar(nav: Nav) {
    val p = palette
    Row(
        Modifier.fillMaxWidth().background(if (p.dark) Color(0xF20D0D0D) else Color(0xF2FFFFFF))
            .navigationBarsPadding().padding(horizontal = 8.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.SpaceAround,
    ) {
        for (t in Tab.entries) {
            val on = nav.tab == t
            Column(
                Modifier.clip(CircleShape).clickable { nav.tab = t }.padding(horizontal = 10.dp, vertical = 6.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(tabIcon(t), t.label, tint = if (on) Palette.Accent else p.textDim)
                Spacer(Modifier.height(4.dp))
                Text(t.label, style = NType.body(11.sp, if (on) Palette.Accent else p.textDim, 500))
            }
        }
    }
}

private fun tabIcon(t: Tab): ImageVector = when (t) {
    Tab.Home -> Icons.Outlined.Home
    Tab.Map -> Icons.Outlined.GridView
    Tab.Devices -> Icons.Outlined.Devices
    Tab.Scenes -> Icons.Outlined.AutoAwesome
    Tab.Connect -> Icons.Outlined.Hub
}

/** The round button top right that opens Settings. */
@Composable
fun ProfileButton() {
    val nav = LocalNav.current
    val p = palette
    Box(Modifier.size(40.dp).clip(CircleShape).background(p.surfaceHigh).clickable { nav.settings = true },
        contentAlignment = Alignment.Center) {
        Icon(Icons.Outlined.Person, "Settings", tint = p.text, modifier = Modifier.size(20.dp))
    }
}

/** Title row of a tab: big bold title, then the profile button. */
@Composable
fun ScreenTitle(title: String, trailing: (@Composable RowScope.() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().statusBarsPadding().padding(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically) {
        DotText(title, 30, modifier = Modifier.weight(1f))
        trailing?.invoke(this)
        Spacer(Modifier.width(8.dp))
        ProfileButton()
    }
}

fun StoreState.roomName(id: String?) = data.room(id)?.name
