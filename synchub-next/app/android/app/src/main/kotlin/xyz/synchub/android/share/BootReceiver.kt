package xyz.synchub.android.share

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import xyz.synchub.android.sync.SyncService
import xyz.synchub.android.sync.Watchdog
import xyz.synchub.android.util.L
import xyz.synchub.android.util.NativePrefs

/** 开机 / 应用覆盖升级后自动启动常驻同步服务。 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val action = intent.action ?: return
        val p = NativePrefs.get(ctx)
        when (action) {
            Intent.ACTION_MY_PACKAGE_REPLACED -> if (p.isConfigured && p.serviceEnabled) {
                L.i("应用已更新，自动恢复同步服务")
                SyncService.start(ctx, reason = "应用更新后")
                Watchdog.schedule(ctx)
            }
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
            -> if (p.isConfigured && p.serviceEnabled && p.startOnBoot) {
                L.i("系统开机完成，自动拉起同步服务")
                SyncService.start(ctx, reason = "开机自启")
                Watchdog.schedule(ctx)
            }
        }
    }
}
