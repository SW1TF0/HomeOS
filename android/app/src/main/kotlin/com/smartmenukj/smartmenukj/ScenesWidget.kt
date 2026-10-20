package com.smartmenukj.smartmenukj

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import android.widget.Toast
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * The widget on the home screen: the open home's first four scenes and All off (scenes_widget.dart sends what it
 * shows). A tap goes to SceneAlarmReceiver, which asks the running app to do it, or starts the app's Dart code
 * without a screen when the app is not running.
 */
class ScenesWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) = render(context, manager, ids)

    companion object {
        const val CHANNEL = "smartmenukj/widget"
        const val ACTION_TAP = "com.smartmenukj.smartmenukj.WIDGET_TAP"
        const val EXTRA_SCENE = "scene"
        private const val PREFS = "smartmenukj.widget"
        private const val KEY_CONTENT = "content"
        private val CELLS = intArrayOf(R.id.scene_0, R.id.scene_1, R.id.scene_2, R.id.scene_3)

        fun attach(app: Context, messenger: BinaryMessenger) {
            MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
                when (call.method) {
                    "show" -> {
                        val content = (call.arguments as? Map<*, *>)?.let { JSONObject(it) } ?: JSONObject()
                        app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                            .putString(KEY_CONTENT, content.toString()).apply()
                        refresh(app)
                        result.success(null)
                    }
                    "pin" -> result.success(pin(app))
                    "tile" -> result.success(AllOffTile.ask(app))
                    else -> result.notImplemented()
                }
            }
        }

        /** Asks the running app to do what was tapped. [then] gets false when no app is running or it could not. */
        fun runInApp(app: Context, scene: String?, then: (Boolean) -> Unit) {
            val engine = HomeEngine.running() ?: return then(false)
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).invokeMethod("run", mapOf("scene" to scene),
                object : MethodChannel.Result {
                    override fun success(reply: Any?) {
                        (reply as? String)?.let { say(app, it) }
                        then(true)
                    }

                    override fun error(code: String, message: String?, details: Any?) = then(false)
                    override fun notImplemented() = then(false)
                })
        }

        fun say(app: Context, text: String) = Toast.makeText(app, text, Toast.LENGTH_SHORT).show()

        private fun refresh(app: Context) {
            val manager = AppWidgetManager.getInstance(app)
            render(app, manager, manager.getAppWidgetIds(ComponentName(app, ScenesWidget::class.java)))
        }

        /** Puts the widget on the home screen, where the launcher lets apps do that. */
        private fun pin(app: Context): Boolean {
            val manager = AppWidgetManager.getInstance(app)
            if (Build.VERSION.SDK_INT < 26 || !manager.isRequestPinAppWidgetSupported) return false
            return manager.requestPinAppWidget(ComponentName(app, ScenesWidget::class.java), null, null)
        }

        private fun render(context: Context, manager: AppWidgetManager, ids: IntArray) {
            if (ids.isEmpty()) return
            val saved = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_CONTENT, null)
            val content = try {
                JSONObject(saved ?: "{}")
            } catch (e: Exception) {
                JSONObject()
            }
            val home = content.optString("home", "").ifBlank { "SmartHomeKJ" }
            val scenes = content.optJSONArray("scenes") ?: JSONArray()
            for (id in ids) {
                val views = RemoteViews(context.packageName, R.layout.widget_scenes)
                views.setTextViewText(R.id.widget_home, home.uppercase())
                views.setOnClickPendingIntent(R.id.widget_home, openApp(context))
                views.setOnClickPendingIntent(R.id.widget_all_off, tap(context, null, 0))
                views.setOnClickPendingIntent(R.id.widget_empty, openApp(context))
                views.setViewVisibility(R.id.widget_empty, if (scenes.length() == 0) View.VISIBLE else View.GONE)
                views.setViewVisibility(R.id.widget_row_0, if (scenes.length() > 0) View.VISIBLE else View.GONE)
                views.setViewVisibility(R.id.widget_row_1, if (scenes.length() > 2) View.VISIBLE else View.GONE)
                for ((i, cell) in CELLS.withIndex()) {
                    val scene = scenes.optJSONObject(i)
                    if (scene == null) {
                        views.setViewVisibility(cell, View.INVISIBLE)
                        continue
                    }
                    views.setViewVisibility(cell, View.VISIBLE)
                    views.setTextViewText(cell, scene.optString("name"))
                    views.setOnClickPendingIntent(cell, tap(context, scene.optString("id"), i + 1))
                }
                manager.updateAppWidget(id, views)
            }
        }

        private fun tap(context: Context, scene: String?, slot: Int): PendingIntent {
            val intent = Intent(context, SceneAlarmReceiver::class.java).setAction(ACTION_TAP)
            if (scene != null) intent.putExtra(EXTRA_SCENE, scene)
            return PendingIntent.getBroadcast(context, 7400 + slot, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }

        private fun openApp(context: Context): PendingIntent {
            val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent(context, MainActivity::class.java)
            return PendingIntent.getActivity(context, 7399, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
    }
}
