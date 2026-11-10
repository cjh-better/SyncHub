package xyz.synchub.android

import android.app.Application
import xyz.synchub.android.sync.Notifs
import xyz.synchub.android.sync.SyncService
import xyz.synchub.android.sync.Watchdog
import xyz.synchub.android.util.L
import xyz.synchub.android.util.Prefs

class SyncHubApp : Application() {
    override fun onCreate() {
        super.onCreate()
        L.init(filesDir)
        Notifs.createChannels(this)
        val p = Prefs.get(this)
        // 被系统杀掉后重新打开应用时恢复服务
        if (p.configured && p.serviceEnabled && SyncService.instance == null) {
            runCatching { SyncService.start(this, reason = "应用进程启动") }
        }
        if (p.configured && p.serviceEnabled) Watchdog.schedule(this)
    }
}
