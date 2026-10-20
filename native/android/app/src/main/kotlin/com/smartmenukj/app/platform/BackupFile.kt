package com.smartmenukj.app.platform

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import com.smartmenukj.app.Prefs
import com.smartmenukj.core.store.HomeStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Keeps a copy of every home in Downloads/SmartHomeKJ/SmartHomeKJ-native-backup.json. Files in Downloads stay when the
 * app is uninstalled, so a new install can open the file again and take the homes back. Writing needs Android 10.
 */
class BackupFile(
    private val context: Context,
    private val scope: CoroutineScope,
    private val store: HomeStore,
    private val prefs: Prefs,
) {
    private val sp = context.getSharedPreferences("smartmenukj.backup", Context.MODE_PRIVATE)
    private var job: Job? = null
    private var written: String? = null

    var savedAt: Long = sp.getLong("savedAt", 0)
        private set

    /** Writes the file a little after a change, so a run of changes writes it once. */
    fun soon() {
        if (!prefs.settings.value.autoBackup) return
        job?.cancel()
        job = scope.launch {
            delay(8000)
            val text = store.exportAll()
            if (text == written) return@launch
            if (withContext(Dispatchers.IO) { save(text.toByteArray()) }) {
                written = text
                savedAt = System.currentTimeMillis()
                sp.edit().putLong("savedAt", savedAt).apply()
            }
        }
    }

    private fun save(bytes: ByteArray): Boolean {
        sp.getString("uri", null)?.let { if (write(Uri.parse(it), bytes)) return true }
        if (Build.VERSION.SDK_INT < 29) return false
        val uri = try {
            context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, NAME)
                put(MediaStore.MediaColumns.MIME_TYPE, "application/json")
                put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/SmartHomeKJ")
            })
        } catch (e: Exception) {
            Log.w(TAG, "Could not make the backup file", e)
            null
        } ?: return false
        if (!write(uri, bytes)) return false
        sp.edit().putString("uri", uri.toString()).apply()
        return true
    }

    private fun write(uri: Uri, bytes: ByteArray): Boolean = try {
        context.contentResolver.openOutputStream(uri, "wt")?.use { it.write(bytes) } != null
    } catch (e: Exception) {
        Log.w(TAG, "Could not write the backup file", e)
        false
    }

    /** Reads a file the user picked. */
    fun read(uri: Uri): String? = try {
        context.contentResolver.openInputStream(uri)?.use { it.readBytes().toString(Charsets.UTF_8) }
    } catch (e: Exception) {
        null
    }

    /** Writes every home into a file the user picked (Save a copy). */
    fun writeTo(uri: Uri): Boolean = write(uri, store.exportAll().toByteArray())

    companion object {
        private const val TAG = "BackupFile"
        const val NAME = "SmartHomeKJ-native-backup.json"
    }
}
