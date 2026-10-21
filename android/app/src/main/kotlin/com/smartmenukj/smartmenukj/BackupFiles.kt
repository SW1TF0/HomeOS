package com.smartmenukj.smartmenukj

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

/**
 * Keeps a copy of every home in Downloads/SmartHomeKJ/SmartHomeKJ-backup.json (backup_files.dart). Files in Downloads
 * stay when the app is uninstalled, so a new install can open the file again and take the homes back. Writing needs
 * Android 10 or later; opening a file works everywhere.
 */
object BackupFiles {
    const val CHANNEL = "smartmenukj/backup"
    private const val TAG = "BackupFiles"
    private const val REQUEST_OPEN = 7301
    private const val NAME = "SmartHomeKJ-backup.json"
    private const val FOLDER = "SmartHomeKJ"
    private const val PREFS = "smartmenukj.backup"
    private const val KEY_URI = "uri"

    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var picked: Uri? = null

    fun attach(app: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "save" -> {
                    val text = call.argument<String>("text")
                    if (text == null) {
                        result.error("args", "Nothing to save", null)
                    } else {
                        thread(name = "smartmenukj-backup") {
                            val ok = save(app, text.toByteArray(Charsets.UTF_8))
                            main.post { result.success(ok) }
                        }
                    }
                }
                "open" -> open(result)
                "keep" -> {
                    picked?.let { keep(app, it) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Writes into the file used last time, or makes a new one in Downloads/SmartHomeKJ. */
    private fun save(app: Context, bytes: ByteArray): Boolean {
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString(KEY_URI, null)?.let { if (write(app, Uri.parse(it), bytes)) return true }
        if (Build.VERSION.SDK_INT < 29) return false
        val uri = try {
            app.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, NAME)
                put(MediaStore.MediaColumns.MIME_TYPE, "application/json")
                put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$FOLDER")
            })
        } catch (e: Exception) {
            Log.w(TAG, "Could not make the backup file", e)
            null
        } ?: return false
        if (!write(app, uri, bytes)) return false
        prefs.edit().putString(KEY_URI, uri.toString()).apply()
        return true
    }

    private fun write(app: Context, uri: Uri, bytes: ByteArray): Boolean = try {
        app.contentResolver.openOutputStream(uri, "wt")?.use { it.write(bytes) } != null
    } catch (e: Exception) {
        // The file was deleted, or the app may no longer write it.
        Log.i(TAG, "Could not write $uri", e)
        false
    }

    /** Lets the owner pick a file, with Android's own file picker. */
    private fun open(result: MethodChannel.Result) {
        val screen = HomeEngine.activity?.get()
        if (screen == null) {
            result.success(null)
            return
        }
        pending?.success(null)
        pending = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try {
            screen.startActivityForResult(intent, REQUEST_OPEN)
        } catch (e: Exception) {
            pending = null
            result.error("open", e.message, null)
        }
    }

    /** Called by MainActivity when the file picker closes. Returns whether the result was for this. */
    fun opened(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_OPEN) return false
        val result = pending ?: return true
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        val app = activity.applicationContext
        thread(name = "smartmenukj-restore") {
            val text = try {
                app.contentResolver.openInputStream(uri)?.use { it.readBytes().toString(Charsets.UTF_8) }
            } catch (e: Exception) {
                Log.w(TAG, "Could not read $uri", e)
                null
            }
            main.post {
                picked = if (text != null) uri else null
                if (text == null) result.error("read", "The file could not be read", null) else result.success(text)
            }
        }
        return true
    }

    /** Later copies go into the file the homes were taken back from, when Android lets the app write it. */
    private fun keep(app: Context, uri: Uri) {
        try {
            app.contentResolver.takePersistableUriPermission(uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY_URI, uri.toString()).apply()
        } catch (e: Exception) {
            Log.i(TAG, "The opened file cannot be written; later copies go to a new file", e)
        }
    }
}
