package com.smartmenukj.smartmenukj

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * The app's one Flutter engine. It belongs to the app rather than to the
 * screen, so when this device keeps a home online (HubService) the app goes
 * on running after the screen is closed, and the screen joins it again when
 * it is opened.
 */
object HomeEngine {
    private const val ID = "home"
    private var multicastLock: WifiManager.MulticastLock? = null

    /** The screen, while it is open: needed to ask for permissions. */
    var activity: WeakReference<Activity>? = null

    fun get(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ID)?.let { return it }
        val app = context.applicationContext
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(app)
        loader.ensureInitializationComplete(app, null)
        val engine = FlutterEngine(app)
        attachChannels(app, engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ID, engine)
        return engine
    }

    /** The app's engine, while the app runs (with or without its screen). */
    fun running(): FlutterEngine? = FlutterEngineCache.getInstance().get(ID)

    /** Stops the app's Dart code, when the screen closes and no home needs it. */
    fun destroy() {
        val engine = FlutterEngineCache.getInstance().get(ID) ?: return
        FlutterEngineCache.getInstance().remove(ID)
        multicastLock?.let { if (it.isHeld) it.release() }
        engine.destroy()
    }

    private fun attachChannels(app: Context, engine: FlutterEngine) {
        val messenger = engine.dartExecutor.binaryMessenger
        // Android drops multicast packets (mDNS, SSDP) unless an app holds this lock,
        // so the network scan takes it while it runs.
        MethodChannel(messenger, "smartmenukj/multicast").setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> {
                    if (multicastLock == null) {
                        val wifi = app.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        multicastLock = wifi.createMulticastLock("smartmenukj-scan").apply { setReferenceCounted(false) }
                    }
                    multicastLock?.acquire()
                    result.success(true)
                }
                "release" -> {
                    multicastLock?.let { if (it.isHeld) it.release() }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        // Timed scenes are booked with Android's alarm manager, so they run with the app closed.
        MethodChannel(messenger, SceneAlarms.CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "sync" -> {
                    SceneAlarms.sync(app, SceneAlarms.parse(call.arguments))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // A copy of every home in Downloads, kept when the app is uninstalled.
        BackupFiles.attach(app, messenger)
        // The home-screen widget shows the open home's scenes.
        ScenesWidget.attach(app, messenger)
        // Sounds for taps and switches.
        UiSounds.attach(app, messenger)
        // Keeping a home online: the app runs on in the background with a notification.
        MethodChannel(messenger, "smartmenukj/hub").setMethodCallHandler { call, result ->
            when (call.method) {
                "name" -> result.success(deviceName(app))
                "start" -> {
                    askForNotifications()
                    HubService.start(app)
                    result.success(null)
                }
                "stop" -> {
                    HubService.stop(app)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** The name the owner gave this phone, or its model. */
    private fun deviceName(app: Context): String {
        val given = if (Build.VERSION.SDK_INT >= 25) Settings.Global.getString(app.contentResolver, Settings.Global.DEVICE_NAME) else null
        if (!given.isNullOrBlank()) return given
        val model = Build.MODEL ?: "Android device"
        val maker = (Build.MANUFACTURER ?: "").replaceFirstChar { it.uppercase() }
        return if (maker.isEmpty() || model.startsWith(maker, ignoreCase = true)) model else "$maker $model"
    }

    /** From Android 13 the notification that says the app is running needs the owner's yes. */
    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT < 33) return
        val screen = activity?.get() ?: return
        if (screen.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            screen.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7)
        }
    }
}
