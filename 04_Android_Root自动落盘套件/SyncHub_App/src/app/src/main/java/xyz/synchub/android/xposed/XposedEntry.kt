package xyz.synchub.android.xposed

import de.robv.android.xposed.IXposedHookLoadPackage
import de.robv.android.xposed.XC_MethodHook
import de.robv.android.xposed.XC_MethodReplacement
import de.robv.android.xposed.XposedBridge
import de.robv.android.xposed.XposedHelpers
import de.robv.android.xposed.callbacks.XC_LoadPackage

/**
 * LSPosed 模块入口（经典 Xposed API 82）。作用域：
 *  - android（系统框架 / system_server）：放开本应用后台读取剪贴板，并屏蔽 Android 12+ 的“已粘贴”提示。
 *  - xyz.synchub.android（本应用）：让 ModuleStatus.isActive() 返回 true，用于界面显示“模块已激活”。
 * 每个 hook 独立 try/catch，单个 ROM 上某个方法不存在不会影响其他 hook。
 */
class XposedEntry : IXposedHookLoadPackage {

    override fun handleLoadPackage(lpparam: XC_LoadPackage.LoadPackageParam) {
        when (lpparam.packageName) {
            SELF -> hookSelf(lpparam)
            "android" -> if (lpparam.processName == "android" || lpparam.processName == null) hookSystem(lpparam.classLoader)
        }
    }

    private fun hookSelf(lpparam: XC_LoadPackage.LoadPackageParam) {
        safe("ModuleStatus.isActive") {
            XposedHelpers.findAndHookMethod("xyz.synchub.android.xposed.ModuleStatus", lpparam.classLoader,
                "isActive", XC_MethodReplacement.returnConstant(true))
        }
        safe("ModuleStatus.frameworkVersion") {
            XposedHelpers.findAndHookMethod("xyz.synchub.android.xposed.ModuleStatus", lpparam.classLoader,
                "frameworkVersion", XC_MethodReplacement.returnConstant(VERSION))
        }
    }

    private fun hookSystem(cl: ClassLoader) {
        val cls = safe("find ClipboardService") {
            XposedHelpers.findClass("com.android.server.clipboard.ClipboardService", cl)
        } ?: return

        // 1) Android 10–15：clipboardAccessAllowed(int op, String callingPackage, ...) 的所有重载。
        //    参数 1 恒为 callingPackage；原结果为 false 且调用方是本应用时改为 true。
        //    这同时覆盖 getPrimaryClip / hasPrimaryClip / getPrimaryClipDescription 以及
        //    剪贴板变化监听回调的分发过滤（notifyPrimaryClipChanged 内部同样调用此方法）。
        var accessHooks = 0
        safe("hook clipboardAccessAllowed") {
            val n = XposedBridge.hookAllMethods(cls, "clipboardAccessAllowed", object : XC_MethodHook() {
                override fun afterHookedMethod(param: MethodHookParam) {
                    try {
                        val pkg = param.args.getOrNull(1) as? String ?: return
                        if (pkg == SELF && param.result == false) param.result = true
                    } catch (t: Throwable) { XposedBridge.log("$TAG clipboardAccessAllowed cb: $t") }
                }
            }).size
            accessHooks = n
            XposedBridge.log("$TAG hooked clipboardAccessAllowed x$n")
        }

        // 2) Android 12+：showAccessNotificationLocked(String callingPackage, int uid, int userId, Clipboard)
        //    对本应用不弹“SyncHub 已粘贴自剪贴板”提示。
        safe("hook showAccessNotificationLocked") {
            val n = XposedBridge.hookAllMethods(cls, "showAccessNotificationLocked", object : XC_MethodHook() {
                override fun beforeHookedMethod(param: MethodHookParam) {
                    if (param.args.getOrNull(0) == SELF) param.result = null
                }
            }).size
            XposedBridge.log("$TAG hooked showAccessNotificationLocked x$n")
        }

        // 写入标记文件，应用通过 root 读取，用来确认“系统框架”钩子在本次开机真正生效（见 HookCheck）。
        writeMarker(accessHooks)

        // 3) 部分 ROM / 版本在 isDefaultIme 之外还有 Content Capture 判断等；不处理。
        //    若 1) 在某 ROM 上 0 个重载（方法被改名），记录日志便于反馈。
    }

    /** /data/system/synchub_lsposed：boot_id、clipboardAccessAllowed 钩子数量、模块版本。system_server 有写权限。 */
    private fun writeMarker(accessHooks: Int) {
        Thread({
            try {
                val boot = runCatching { java.io.File("/proc/sys/kernel/random/boot_id").readText().trim() }.getOrDefault("")
                java.io.File(MARKER).writeText("$boot\n$accessHooks\n$VERSION\n")
            } catch (t: Throwable) { XposedBridge.log("$TAG write marker failed: $t") }
        }, "synchub-marker").start()
    }

    private inline fun <T> safe(what: String, block: () -> T): T? = try {
        block()
    } catch (t: Throwable) {
        XposedBridge.log("$TAG $what failed: $t"); null
    }

    companion object {
        const val SELF = "xyz.synchub.android"
        const val TAG = "[SyncHub]"
        const val VERSION = 2
        const val MARKER = "/data/system/synchub_lsposed"
    }
}
