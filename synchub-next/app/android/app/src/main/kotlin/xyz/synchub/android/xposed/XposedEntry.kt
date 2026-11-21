package xyz.synchub.android.xposed

import de.robv.android.xposed.IXposedHookLoadPackage
import de.robv.android.xposed.XC_MethodHook
import de.robv.android.xposed.XC_MethodReplacement
import de.robv.android.xposed.XposedBridge
import de.robv.android.xposed.XposedHelpers
import de.robv.android.xposed.callbacks.XC_LoadPackage

/**
 * LSPosed 模块入口（经典 Xposed API 82）。作用域：
 *  - android（系统框架 / system_server）：放开本应用后台读写剪贴板（兼容 Android 10–16 及 ColorOS/RealmeUI/HyperOS/OneUI），
 *    并屏蔽 Android 12+ 的“已粘贴自剪贴板”提示。
 *  - xyz.synchub.android（本应用）：让 ModuleStatus.isActive() 返回 true，用于界面显示“模块已激活”。
 * 每个 hook 独立 try/catch，单个 ROM 上某个方法不存在不会影响其他 hook。
 */
class XposedEntry : IXposedHookLoadPackage {

    override fun handleLoadPackage(lpparam: XC_LoadPackage.LoadPackageParam) {
        when (lpparam.packageName) {
            SELF -> hookSelf(lpparam)
            "android" -> if (lpparam.processName == "android" || lpparam.processName == null) {
                hookSystem(lpparam.classLoader)
            }
        }
    }

    private fun hookSelf(lpparam: XC_LoadPackage.LoadPackageParam) {
        safe("ModuleStatus.isActive") {
            XposedHelpers.findAndHookMethod(
                "xyz.synchub.android.xposed.ModuleStatus",
                lpparam.classLoader,
                "isActive",
                XC_MethodReplacement.returnConstant(true),
            )
        }
        safe("ModuleStatus.frameworkVersion") {
            XposedHelpers.findAndHookMethod(
                "xyz.synchub.android.xposed.ModuleStatus",
                lpparam.classLoader,
                "frameworkVersion",
                XC_MethodReplacement.returnConstant(VERSION),
            )
        }
    }

    private fun hookSystem(cl: ClassLoader) {
        val cls = safe("find ClipboardService") {
            XposedHelpers.findClass("com.android.server.clipboard.ClipboardService", cl)
        } ?: return

        var accessHooks = 0

        // 1) Android 10–16：在 beforeHookedMethod 直接放行 clipboardAccessAllowed，
        //    不依赖 callingPackage 的固定参数下标（适配各厂商 ROM 重载），且跳过 AppOps.noteOp 与厂商拦截扩展。
        safe("hook clipboardAccessAllowed") {
            val n = XposedBridge.hookAllMethods(cls, "clipboardAccessAllowed", object : XC_MethodHook() {
                override fun beforeHookedMethod(param: MethodHookParam) {
                    try {
                        if (param.args?.any { it == SELF } == true) {
                            param.result = true
                        }
                    } catch (t: Throwable) {
                        XposedBridge.log("$TAG clipboardAccessAllowed before: $t")
                    }
                }
            }).size
            accessHooks += n
            XposedBridge.log("$TAG hooked clipboardAccessAllowed x$n")
        }

        // 2) 兼容 ColorOS / Realme UI / HyperOS / OneUI：在 ClipboardService 内部将本应用视为默认输入法豁免，
        //    同时覆盖后台读取与后台 setPrimaryClip 写入限制（仅作用于 ClipboardService 私有方法，不影响系统输入法）。
        safe("hook isDefaultIme") {
            val n = XposedBridge.hookAllMethods(cls, "isDefaultIme", object : XC_MethodHook() {
                override fun beforeHookedMethod(param: MethodHookParam) {
                    if (param.args?.any { it == SELF } == true) {
                        param.result = true
                    }
                }
            }).size
            accessHooks += n
            XposedBridge.log("$TAG hooked isDefaultIme x$n")
        }

        // 3) ColorOS / Realme UI / OnePlus 扩展类（若存在）：放行 *AccessAllowed* 校验。
        for (extName in listOf(
            "com.android.server.clipboard.ClipboardServiceExtImpl",
            "com.oplus.server.clipboard.ClipboardServiceExtImpl",
        )) {
            safe("hook $extName") {
                val extCls = XposedHelpers.findClassIfExists(extName, cl) ?: return@safe
                for (m in extCls.declaredMethods) {
                    if (m.returnType == Boolean::class.javaPrimitiveType &&
                        m.name.contains("Allowed", ignoreCase = true)
                    ) {
                        XposedBridge.hookMethod(m, object : XC_MethodHook() {
                            override fun beforeHookedMethod(param: MethodHookParam) {
                                if (param.args?.any { it == SELF } == true) {
                                    param.result = true
                                }
                            }
                        })
                        accessHooks++
                    }
                }
            }
        }

        // 4) Android 12+：showAccessNotificationLocked 对本应用不弹“SyncHub 已粘贴自剪贴板”提示。
        safe("hook showAccessNotificationLocked") {
            val n = XposedBridge.hookAllMethods(cls, "showAccessNotificationLocked", object : XC_MethodHook() {
                override fun beforeHookedMethod(param: MethodHookParam) {
                    if (param.args?.any { it == SELF } == true) {
                        param.result = null
                    }
                }
            }).size
            XposedBridge.log("$TAG hooked showAccessNotificationLocked x$n")
        }

        // 写入标记文件，应用通过 root 读取，用来确认“系统框架”钩子在本次开机真正生效（见 HookCheck）。
        writeMarker(accessHooks)
    }

    /** /data/system/synchub_lsposed：boot_id、钩子数量、模块版本。system_server 有写权限。 */
    private fun writeMarker(accessHooks: Int) {
        Thread({
            try {
                val boot = runCatching {
                    java.io.File("/proc/sys/kernel/random/boot_id").readText().trim()
                }.getOrDefault("")
                java.io.File(MARKER).writeText("$boot\n$accessHooks\n$VERSION\n")
            } catch (t: Throwable) {
                XposedBridge.log("$TAG write marker failed: $t")
            }
        }, "synchub-marker").start()
    }

    private inline fun <T> safe(what: String, block: () -> T): T? = try {
        block()
    } catch (t: Throwable) {
        XposedBridge.log("$TAG $what failed: $t")
        null
    }

    companion object {
        const val SELF = "xyz.synchub.android"
        const val TAG = "[SyncHub]"
        const val VERSION = 3
        const val MARKER = "/data/system/synchub_lsposed"
    }
}
