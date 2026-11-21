package xyz.synchub.android

import android.app.Application
import xyz.synchub.android.sync.Notifs
import xyz.synchub.android.sync.Watchdog
import xyz.synchub.android.util.L
import xyz.synchub.android.util.NativePrefs

class SyncHubApp : Application() {
    override fun onCreate() {
        super.onCreate()
        L.init(filesDir)
        Notifs.createChannels(this)
        val p = NativePrefs.get(this)
        if (p.isConfigured && p.serviceEnabled) {
            Watchdog.schedule(this)
        }
    }
}
