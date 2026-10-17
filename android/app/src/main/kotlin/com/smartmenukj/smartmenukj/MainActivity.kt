package com.smartmenukj.smartmenukj

import android.content.Context
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import java.lang.ref.WeakReference

/** The app's screen. It shows the app's one engine (HomeEngine), which may run on without it. */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        HomeEngine.activity = WeakReference(this)
        super.onCreate(savedInstanceState)
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine = HomeEngine.get(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onDestroy() {
        if (HomeEngine.activity?.get() === this) HomeEngine.activity = null
        val closing = isFinishing && !isChangingConfigurations
        super.onDestroy()
        // With no home to keep online, closing the screen ends the app as before.
        if (closing && !HubService.running) HomeEngine.destroy()
    }
}
