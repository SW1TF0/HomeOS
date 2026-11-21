package com.smartmenukj.app.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf

enum class Tab(val label: String) { Home("Home"), Map("Map"), Devices("Devices"), Scenes("Scenes"), Connect("Connect") }

/** Which tab, sheet and page is open. Screens ask it to open each other. */
class Nav {
    var tab by mutableStateOf(Tab.Home)
    var device by mutableStateOf<String?>(null)
    var room by mutableStateOf<String?>(null)
    var mapEdit by mutableStateOf(false)
    var mapFloor by mutableStateOf<String?>(null)
    var settings by mutableStateOf(false)
    var homes by mutableStateOf(false)
    var scene by mutableStateOf<String?>(null)
    var integration by mutableStateOf<String?>(null)

    fun openMap(edit: Boolean = false, floorId: String? = null) {
        mapEdit = edit
        floorId?.let { mapFloor = it }
        tab = Tab.Map
    }
}

val LocalNav = staticCompositionLocalOf { Nav() }
