package xyz.synchub.android.share

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import xyz.synchub.android.sync.SyncService
import xyz.synchub.android.sync.Watchdog
import xyz.synchub.android.util.L
import xyz.synchub.android.util.Prefs

/** 开机 / 应用更新后自动启动同步服务。 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val a = intent.action ?: return
        val p = Prefs.get(ctx)
        when (a) {
            // 覆盖安装（升级）会杀掉正在运行的服务；只要用户之前开着同步就恢复，不受“开机自启”开关影响
            Intent.ACTION_MY_PACKAGE_REPLACED -> if (p.configured && p.serviceEnabled) {
                L.i("应用已更新，恢复同步服务")
                SyncService.start(ctx, reason = "应用更新后")
                Watchdog.schedule(ctx)
            }
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON", "com.htc.intent.action.QUICKBOOT_POWERON" ->
                if (p.configured && p.serviceEnabled && p.startOnBoot) {
                    SyncService.start(ctx, reason = "开机")
                    Watchdog.schedule(ctx)
                }
        }
    }
}
