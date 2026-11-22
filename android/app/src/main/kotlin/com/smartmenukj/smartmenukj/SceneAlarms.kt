package com.smartmenukj.smartmenukj

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * Exact alarms that wake the app when a timed scene is due. The booked times
 * are kept in the app's own preferences too, so they can be put back after
 * the phone restarts.
 */
object SceneAlarms {
    const val CHANNEL = "smartmenukj/alarms"
    const val ACTION_RUN = "com.smartmenukj.smartmenukj.RUN_SCENE"
    const val EXTRA_ALARM = "alarm"
    private const val PREFS = "smartmenukj_scene_alarms"
    private const val TAG = "SceneAlarms"

    /** Makes the booked alarms exactly [alarms]: alarm number to time in milliseconds. */
    fun sync(context: Context, alarms: Map<Int, Long>) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        for (key in prefs.all.keys) {
            val id = key.toIntOrNull() ?: continue
            if (id !in alarms) cancel(context, id)
        }
        val edit = prefs.edit().clear()
        for ((id, at) in alarms) {
            book(context, id, at)
            edit.putLong(id.toString(), at)
        }
        edit.apply()
    }

    /** Books the stored alarms again, for example after a restart. */
    fun restore(context: Context) {
        val now = System.currentTimeMillis()
        for ((key, value) in context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).all) {
            val id = key.toIntOrNull() ?: continue
            val at = value as? Long ?: continue
            if (at > now) book(context, id, at)
        }
    }

    /** Reads the alarms sent from Dart, like {"123": 1760000000000}. */
    fun parse(arguments: Any?): Map<Int, Long> {
        val map = arguments as? Map<*, *> ?: return emptyMap()
        val alarms = HashMap<Int, Long>()
        for ((key, value) in map) {
            val id = key?.toString()?.toIntOrNull() ?: continue
            val at = (value as? Number)?.toLong() ?: continue
            alarms[id] = at
        }
        return alarms
    }

    private fun pending(context: Context, id: Int): PendingIntent {
        val intent = Intent(context, SceneAlarmReceiver::class.java)
            .setAction(ACTION_RUN)
            .putExtra(EXTRA_ALARM, id)
        return PendingIntent.getBroadcast(
            context, id, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** Whether exact alarms are allowed, so scenes run on the minute. */
    fun onTime(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val manager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return false
        return manager.canScheduleExactAlarms()
    }

    /** Opens Settings > Alarms & reminders for this app. False when there is no such page. */
    fun askOnTime(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return try {
            context.startActivity(
                Intent(android.provider.Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                    .setData(android.net.Uri.parse("package:" + context.packageName))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: Exception) {
            Log.w(TAG, "No Alarms & reminders page", e)
            false
        }
    }

    private fun book(context: Context, id: Int, at: Long) {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        val intent = pending(context, id)
        val exact = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) manager.canScheduleExactAlarms() else true
        try {
            if (exact) {
                manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, intent)
                return
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "Exact alarms are not allowed, booking an inexact one", e)
        }
        manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, intent)
    }

    private fun cancel(context: Context, id: Int) {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        manager.cancel(pending(context, id))
    }
}
