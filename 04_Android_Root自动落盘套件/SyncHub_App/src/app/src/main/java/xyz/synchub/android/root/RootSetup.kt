package xyz.synchub.android.root

import android.content.Context
import android.os.Build
import xyz.synchub.android.util.L
import xyz.synchub.android.util.Prefs

/**
 * “授予 Root 后一键配置”：把原本需要用户逐个去设置里点的权限一次性用 root 完成。
 * 每一步独立执行并记录结果，失败不影响后续步骤。
 */
object RootSetup {
    const val OLD_SCRIPT = "/data/adb/service.d/synchub_android.sh"
    const val OLD_STATE = "/data/adb/synchub_last_id"

    data class Step(val name: String, val ok: Boolean, val detail: String = "")

    data class OldScript(val present: Boolean, val running: Boolean, val lastId: Long?)

    fun run(ctx: Context, hideClipboardToast: Boolean): List<Step> {
        val pkg = ctx.packageName
        val steps = ArrayList<Step>()
        fun step(name: String, cmd: String) {
            val r = RootShell.run(cmd)
            steps += Step(name, r.ok, r.out.take(200))
            L.i("RootSetup $name → ${r.code} ${r.out.take(120)}")
        }
        if (Build.VERSION.SDK_INT >= 33) step("通知权限", "pm grant $pkg android.permission.POST_NOTIFICATIONS")
        // 存储：Android 11+ 授予“所有文件访问”，直接写 /sdcard/Download；Android 10 授予传统存储权限
        if (Build.VERSION.SDK_INT >= 30) step("文件访问 (/sdcard/Download)", "appops set $pkg MANAGE_EXTERNAL_STORAGE allow")
        else step("存储权限", "pm grant $pkg android.permission.WRITE_EXTERNAL_STORAGE; pm grant $pkg android.permission.READ_EXTERNAL_STORAGE")
        step("剪贴板 AppOp", "appops set $pkg READ_CLIPBOARD allow")
        step("后台运行", "appops set $pkg RUN_IN_BACKGROUND allow; appops set $pkg RUN_ANY_IN_BACKGROUND allow")
        step("电池优化白名单", "dumpsys deviceidle whitelist +$pkg")
        if (Build.VERSION.SDK_INT >= 31) {
            // 待机分组设为 active，避免被系统限流
            step("应用待机分组", "am set-standby-bucket $pkg active")
        }
        if (hideClipboardToast && Build.VERSION.SDK_INT >= 31) {
            // Root 兼容模式下读取方是 Shell，系统会弹“Shell 已粘贴…”提示；这是系统设置里的
            // “显示剪贴板访问通知”开关，可随时在 设置 → 隐私 中改回。
            step("关闭系统剪贴板读取提示", "settings put secure clipboard_show_access_notifications 0")
        }
        return steps
    }

    fun detectOldScript(): OldScript {
        val r = RootShell.run(
            "[ -f $OLD_SCRIPT ] && echo PRESENT; " +
                "for p in /proc/[0-9]*; do grep -qs synchub_android[.]sh \$p/cmdline && echo RUNNING && break; done; " +
                "[ -f $OLD_STATE ] && echo \"LAST=\$(cat $OLD_STATE)\""
        )
        val lastId = Regex("LAST=(\\d+)").find(r.out)?.groupValues?.get(1)?.toLongOrNull()
        return OldScript(r.out.contains("PRESENT"), r.out.contains("RUNNING"), lastId)
    }

    /** 停止并移除旧版 Magisk service.d 脚本（先备份到 /data/adb/synchub_android.sh.bak）。 */
    fun removeOldScript(prefs: Prefs, old: OldScript): Step {
        old.lastId?.let { if (it > prefs.lastHubId) prefs.lastHubId = it }   // 继承旧脚本进度，避免重复下载
        val r = RootShell.run(
            "for p in /proc/[0-9]*; do grep -qs synchub_android[.]sh \$p/cmdline && kill \${p#/proc/}; done; " +
                "[ -f $OLD_SCRIPT ] && mv -f $OLD_SCRIPT /data/adb/synchub_android.sh.bak; echo done"
        )
        L.i("移除旧脚本 → ${r.out}")
        return Step("停止并移除旧版 Root 脚本", r.ok, "已备份到 /data/adb/synchub_android.sh.bak")
    }
}
