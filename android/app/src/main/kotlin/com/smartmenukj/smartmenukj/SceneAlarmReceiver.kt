package com.smartmenukj.smartmenukj

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Runs a timed scene when its alarm goes off, even with the app closed. It
 * starts the app's Dart code without a screen (sceneAlarmMain in main.dart),
 * which runs the scene, books the next alarms and says when it is done.
 * After a restart or an app update it books the alarms again the same way.
 */
class SceneAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        val args = when (intent.action) {
            SceneAlarms.ACTION_RUN -> listOf("run", intent.getIntExtra(SceneAlarms.EXTRA_ALARM, -1).toString())
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                SceneAlarms.restore(app)
                listOf("sync")
            }
            else -> return
        }

        // Keep the phone awake until the scene has been sent, then let go.
        val result = goAsync()
        val wakeLock = (app.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SmartMenuKJ:scene")
        wakeLock.acquire(LIMIT_MS + 1_000)
        val main = Handler(Looper.getMainLooper())
        var engine: FlutterEngine? = null
        var finished = false
        lateinit var finish: Runnable
        finish = Runnable {
            if (finished) return@Runnable
            finished = true
            main.removeCallbacks(finish)
            try {
                engine?.destroy()
            } catch (e: Exception) {
                Log.w(TAG, "Could not stop the background engine", e)
            }
            if (wakeLock.isHeld) wakeLock.release()
            result.finish()
        }

        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(app)
            loader.ensureInitializationComplete(app, null)
            val background = FlutterEngine(app)
            engine = background
            MethodChannel(background.dartExecutor.binaryMessenger, SceneAlarms.CHANNEL).setMethodCallHandler { call, reply ->
                when (call.method) {
                    "sync" -> {
                        SceneAlarms.sync(app, SceneAlarms.parse(call.arguments))
                        reply.success(null)
                    }
                    "done" -> {
                        reply.success(null)
                        main.post(finish)
                    }
                    else -> reply.notImplemented()
                }
            }
            background.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "sceneAlarmMain"), args)
            main.postDelayed(finish, LIMIT_MS)
        } catch (e: Exception) {
            Log.e(TAG, "Could not run a timed scene", e)
            finish.run()
        }
    }

    private companion object {
        const val TAG = "SceneAlarmReceiver"

        /** A receiver gets about ten seconds; the Dart side aims to finish well within that. */
        const val LIMIT_MS = 9_000L
    }
}
