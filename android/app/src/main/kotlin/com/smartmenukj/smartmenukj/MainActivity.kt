package com.smartmenukj.smartmenukj

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Android drops multicast packets (mDNS, SSDP) unless an app holds this lock,
        // so the network scan takes it while it runs.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "smartmenukj/multicast").setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> {
                    if (multicastLock == null) {
                        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        multicastLock = wifi.createMulticastLock("smartmenukj-scan").apply {
                            setReferenceCounted(false)
                        }
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SceneAlarms.CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "sync" -> {
                    SceneAlarms.sync(applicationContext, SceneAlarms.parse(call.arguments))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        multicastLock?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }
}
