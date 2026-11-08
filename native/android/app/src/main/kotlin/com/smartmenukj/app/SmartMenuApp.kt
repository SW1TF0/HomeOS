package com.smartmenukj.app

import android.app.Application
import com.smartmenukj.app.platform.BackupFile
import com.smartmenukj.app.platform.FileStorage
import com.smartmenukj.core.net.UrlHttp
import com.smartmenukj.core.store.HomeStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow

/** Holds the one [HomeStore] the whole app uses. */
class SmartMenuApp : Application() {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    lateinit var store: HomeStore
        private set
    lateinit var backup: BackupFile
        private set
    lateinit var prefs: Prefs
        private set

    /** Messages to show at the bottom of the screen. */
    val messages = MutableSharedFlow<String>(extraBufferCapacity = 8)

    override fun onCreate() {
        super.onCreate()
        prefs = Prefs(this)
        store = HomeStore(FileStorage(filesDir.resolve("homes")), UrlHttp(), scope)
        store.onMessage = { messages.tryEmit(it) }
        backup = BackupFile(this, scope, store, prefs)
        store.onSaved = { backup.soon() }
        store.load()
    }
}
