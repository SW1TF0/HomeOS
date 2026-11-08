package com.smartmenukj.app.platform

import com.smartmenukj.core.store.HomeStorage
import java.io.File

/** Homes as files in the app's own folder. Writes go to a temporary file first, so a crash never leaves half a home. */
class FileStorage(private val dir: File) : HomeStorage {
    init {
        dir.mkdirs()
    }

    override fun read(name: String): String? = File(dir, name).takeIf { it.exists() }?.readText()

    override fun write(name: String, text: String) {
        val tmp = File(dir, "$name.tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(File(dir, name))) {
            File(dir, name).writeText(text)
            tmp.delete()
        }
    }

    override fun delete(name: String) {
        File(dir, name).delete()
    }
}
