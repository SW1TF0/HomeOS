package com.smartmenukj.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import com.smartmenukj.app.ui.AppRoot
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.Calendar

class MainActivity : ComponentActivity() {
    private var clock: Job? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as SmartMenuApp
        setContent { AppRoot(app) }
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            // Devices are read while the app is on screen, and timed scenes run then too.
            override fun onStart(owner: LifecycleOwner) {
                app.store.startPolling(app.prefs.settings.value.checkSeconds)
                clock = app.scope.launch {
                    var last = -1
                    while (isActive) {
                        val c = Calendar.getInstance()
                        val minute = c.get(Calendar.HOUR_OF_DAY) * 60 + c.get(Calendar.MINUTE)
                        if (minute != last && last != -1) {
                            // Calendar counts Sunday as 1; scenes count Monday as 1.
                            val day = (c.get(Calendar.DAY_OF_WEEK) + 5) % 7 + 1
                            app.store.runDueScenes(day, c.get(Calendar.HOUR_OF_DAY), c.get(Calendar.MINUTE))
                        }
                        last = minute
                        delay(5000)
                    }
                }
            }

            override fun onStop(owner: LifecycleOwner) {
                app.store.stopPolling()
                clock?.cancel()
                app.store.saveNow()
            }
        })
    }
}
