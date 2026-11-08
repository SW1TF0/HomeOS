package com.smartmenukj.smartmenukj

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Keeps the app running while this device keeps a home online, so phones away
 * from home can reach its devices through it. Android shows a notification
 * for as long as it runs. It comes back after a restart of the phone.
 */
class HubService : Service() {
    override fun onCreate() {
        super.onCreate()
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(NOTIFICATION, notification())
            }
        } catch (e: Exception) {
            Log.e(TAG, "Android would not keep the app running", e)
            stopSelf()
            return
        }
        running = true
        // After a restart, or if Android stopped the app, this starts it again without a screen.
        HomeEngine.get(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun notification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Home online", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while this device keeps your home reachable from anywhere"
                    setShowBadge(false)
                })
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return builder
            .setSmallIcon(R.drawable.ic_stat_home)
            .setContentTitle("Keeping your home online")
            .setContentText("Your other devices reach your home through this one.")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val TAG = "HubService"
        private const val CHANNEL = "hub"
        private const val NOTIFICATION = 7
        private const val PREFS = "smartmenukj.hub"

        @Volatile
        var running = false
            private set

        /** Whether this device should keep a home online, also after a restart. */
        fun wanted(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("on", false)

        fun start(context: Context) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("on", true).apply()
            launch(context)
        }

        /** Starts the service if it should run. */
        fun launch(context: Context) {
            if (running || !wanted(context)) return
            val intent = Intent(context, HubService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
            } catch (e: Exception) {
                Log.e(TAG, "Could not start keeping the home online", e)
            }
        }

        fun stop(context: Context) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("on", false).apply()
            context.stopService(Intent(context, HubService::class.java))
        }
    }
}
