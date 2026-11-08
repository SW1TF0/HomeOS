package com.smartmenukj.smartmenukj

import android.content.Context
import android.media.AudioAttributes
import android.media.SoundPool
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Short sounds for taps, switching on and off and running scenes, played with Android's SoundPool. */
object UiSounds {
    private var pool: SoundPool? = null
    private val ids = mutableMapOf<String, Int>()

    fun attach(app: Context, messenger: BinaryMessenger) {
        // Loaded up front: SoundPool loads in the background and stays silent until it is done.
        load(app)
        MethodChannel(messenger, "smartmenukj/sounds").setMethodCallHandler { call, result ->
            when (call.method) {
                "play" -> {
                    play(app, call.arguments as? String ?: "tap")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun load(app: Context): SoundPool {
        pool?.let { return it }
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val p = SoundPool.Builder().setMaxStreams(4).setAudioAttributes(attrs).build()
        ids["tap"] = p.load(app, R.raw.ui_tap, 1)
        ids["tick"] = p.load(app, R.raw.ui_tick, 1)
        ids["on"] = p.load(app, R.raw.ui_on, 1)
        ids["off"] = p.load(app, R.raw.ui_off, 1)
        ids["scene"] = p.load(app, R.raw.ui_scene, 1)
        pool = p
        return p
    }

    private fun play(app: Context, name: String) {
        val p = load(app)
        val id = ids[name] ?: return
        p.play(id, 0.6f, 0.6f, 1, 0, 1f)
    }
}
