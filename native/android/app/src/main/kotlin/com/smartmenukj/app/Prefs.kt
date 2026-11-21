package com.smartmenukj.app

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** App-wide settings that are not part of a home. */
data class Settings(
    val clock24: Boolean = true,
    val haptics: Boolean = true,
    val checkSeconds: Int = 10,
    val autoBackup: Boolean = true,
)

class Prefs(context: Context) {
    private val sp = context.getSharedPreferences("smartmenukj.settings", Context.MODE_PRIVATE)
    private val _settings = MutableStateFlow(
        Settings(
            clock24 = sp.getBoolean("clock24", true),
            haptics = sp.getBoolean("haptics", true),
            checkSeconds = sp.getInt("checkSeconds", 10),
            autoBackup = sp.getBoolean("autoBackup", true),
        )
    )
    val settings: StateFlow<Settings> = _settings.asStateFlow()

    fun update(f: (Settings) -> Settings) {
        val s = f(_settings.value)
        _settings.value = s
        sp.edit()
            .putBoolean("clock24", s.clock24)
            .putBoolean("haptics", s.haptics)
            .putInt("checkSeconds", s.checkSeconds)
            .putBoolean("autoBackup", s.autoBackup)
            .apply()
    }

    var restoreOffered: Boolean
        get() = sp.getBoolean("restoreOffered", false)
        set(v) = sp.edit().putBoolean("restoreOffered", v).apply()
}
