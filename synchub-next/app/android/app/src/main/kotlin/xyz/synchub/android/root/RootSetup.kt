package xyz.synchub.android.root

import android.content.Context
import android.os.Build
import xyz.synchub.android.util.L
import xyz.synchub.android.util.NativePrefs

/**
 * “授予 Root 后一键配置”：把原本需要用户逐个去设置里点的权限一次性用 root 完成，
 * 包括 Android 14–16 / ColorOS 的 UID 级剪贴板读写 AppOps，并检测/迁移旧版脚本。
 */
object RootSetup {
    const val OLD_SCRIPT_GLOB = "/data/adb/service.d/synchub_*.sh"
    const val OLD_STATE = "/data/adb/synchub_last_id"

    data class Step(val name: String, val ok: Boolean, val detail: String = "")

    data class OldScript(
        val present: Boolean,
        val running: Boolean,
        val lastId: Long?,
        val files: List<String> = emptyList(),
    )

    fun run(ctx: Context, hideClipboardToast: Boolean): List<Step> {
        val pkg = ctx.packageName
        val steps = ArrayList<Step>()
        fun step(name: String, cmd: String) {
            val r = RootShell.run(cmd)
            steps += Step(name, r.ok, r.out.take(200))
            L.i("RootSetup $name → ${r.code} ${r.out.take(120)}")
        }
        if (Build.VERSION.SDK_INT >= 33) {
            step("通知权限", "pm grant $pkg android.permission.POST_NOTIFICATIONS")
        }
        if (Build.VERSION.SDK_INT >= 30) {
            step("文件访问 (/sdcard/Download)", "appops set $pkg MANAGE_EXTERNAL_STORAGE allow")
        } else {
            step(
                "存储权限",
                "pm grant $pkg android.permission.WRITE_EXTERNAL_STORAGE; pm grant $pkg android.permission.READ_EXTERNAL_STORAGE",
            )
        }
        step(
            "剪贴板后台读写 AppOp",
            "appops set $pkg READ_CLIPBOARD allow; " +
                "cmd appops set --uid $pkg READ_CLIPBOARD allow 2>/dev/null || true; " +
                "cmd appops set $pkg WRITE_CLIPBOARD allow 2>/dev/null || true; " +
                "cmd appops set --uid $pkg WRITE_CLIPBOARD allow 2>/dev/null || true",
        )
        step(
            "后台常驻与免休眠",
            "appops set $pkg RUN_IN_BACKGROUND allow; " +
                "appops set $pkg RUN_ANY_IN_BACKGROUND allow; " +
                "cmd appops set $pkg SYSTEM_EXEMPT_FROM_HIBERNATION allow 2>/dev/null || true",
        )
        step("电池优化白名单", "dumpsys deviceidle whitelist +$pkg")
        if (Build.VERSION.SDK_INT >= 31) {
            step("应用待机分组", "am set-standby-bucket $pkg active")
        }
        if (hideClipboardToast && Build.VERSION.SDK_INT >= 31) {
            step(
                "关闭系统剪贴板读取提示",
                "settings put secure clipboard_show_access_notifications 0; " +
                    "device_config put clipboard show_access_notifications false 2>/dev/null || true",
            )
        }
        return steps
    }

    fun detectOldScript(prefs: NativePrefs? = null): OldScript {
        val r = RootShell.run(
            "for f in $OLD_SCRIPT_GLOB; do [ -f \"\$f\" ] && echo \"FILE=\$f\"; done; " +
                "for p in /proc/[0-9]*; do grep -Eqs 'synchub_[^/]*[.]sh' \"\$p/cmdline\" && echo RUNNING && break; done; " +
                "[ -f $OLD_STATE ] && echo \"LAST=\$(cat $OLD_STATE)\"",
        )
        val files = Regex("^FILE=(.+)$", RegexOption.MULTILINE)
            .findAll(r.out)
            .map { it.groupValues[1].trim() }
            .filter { it.isNotEmpty() }
            .toList()
        val lastId = Regex("LAST=(\\d+)").find(r.out)?.groupValues?.get(1)?.toLongOrNull()
        if (prefs != null && lastId != null && lastId > prefs.migratedLastHubId) {
            prefs.migratedLastHubId = lastId
        }
        return OldScript(
            present = files.isNotEmpty(),
            running = r.out.contains("RUNNING"),
            lastId = lastId,
            files = files,
        )
    }

    /** 停止并移除旧版 Magisk/KernelSU service.d 脚本（备份到 `/data/adb/<文件名>.bak`，并迁移 `synchub_last_id`）。 */
    fun removeOldScript(prefs: NativePrefs, old: OldScript = detectOldScript(prefs)): Step {
        old.lastId?.let {
            if (it > prefs.migratedLastHubId) prefs.migratedLastHubId = it
        }
        val r = RootShell.run(
            "for p in /proc/[0-9]*; do grep -Eqs 'synchub_[^/]*[.]sh' \"\$p/cmdline\" && kill \"\${p#/proc/}\"; done; " +
                "for f in $OLD_SCRIPT_GLOB; do [ -f \"\$f\" ] && mv -f \"\$f\" \"/data/adb/\$(basename \"\$f\").bak\"; done; " +
                "echo done",
        )
        L.i("移除旧脚本 → ${r.out}")
        return Step("停止并移除旧版 Root 脚本", r.ok, "已备份到 /data/adb/*.sh.bak")
    }
}
