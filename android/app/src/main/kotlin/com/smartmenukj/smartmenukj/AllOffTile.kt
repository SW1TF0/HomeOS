package com.smartmenukj.smartmenukj

import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** "All off" in Quick Settings: switches off everything the home screen's All off switches, from anywhere. */
class AllOffTile : TileService() {
    override fun onStartListening() {
        qsTile?.apply {
            state = Tile.STATE_INACTIVE
            label = "All off"
            updateTile()
        }
    }

    override fun onClick() {
        sendBroadcast(Intent(this, SceneAlarmReceiver::class.java).setAction(ScenesWidget.ACTION_TAP))
    }

    companion object {
        /** From Android 13 the app can offer to add the tile. False when the owner has to add it themselves. */
        fun ask(app: Context): Boolean {
            if (Build.VERSION.SDK_INT < 33) return false
            val bar = app.getSystemService(StatusBarManager::class.java) ?: return false
            return try {
                bar.requestAddTileService(ComponentName(app, AllOffTile::class.java), "All off",
                    Icon.createWithResource(app, R.drawable.ic_tile_off), app.mainExecutor) {}
                true
            } catch (e: Exception) {
                false
            }
        }
    }
}
