package xyz.synchub.android.root

/**
 * 确认 LSPosed 的“系统框架”钩子在本次开机真的生效了。
 * ModuleStatus.isActive() 只说明“本应用”作用域生效；在 LSPosed 里刚启用模块 / 刚更新模块但没重启手机、
 * 或作用域没勾“系统框架”时，它照样返回 true，但系统并没有放开后台读取剪贴板——
 * 1.0.1 及以前此时会选择“LSPosed 模式”，应用一到后台剪贴板上传就静默失效。
 */
object HookCheck {
    enum class State(val label: String) {
        ACTIVE("系统框架钩子已生效"),
        NO_MARKER("本次开机未加载系统框架钩子（模块刚启用/刚更新后未重启，或作用域未勾选“系统框架”）"),
        STALE("系统框架钩子来自旧版模块（更新后尚未重启手机）"),
        NO_HOOK("系统框架已加载模块，但没有找到 clipboardAccessAllowed（此 ROM 不兼容）"),
        UNKNOWN("无法确认（未获得 Root）"),
    }

    data class Result(val state: State, val detail: String)

    const val CURRENT_VERSION = 2

    fun parse(out: String): Result {
        val parts = out.split("---")
        val boot = parts.getOrNull(0)?.trim().orEmpty()
        val marker = parts.getOrNull(1)?.trim()?.lines()?.map { it.trim() }.orEmpty()
        if (marker.isEmpty() || marker[0].isEmpty()) return Result(State.NO_MARKER, "marker 不存在")
        val mBoot = marker[0]
        val hooks = marker.getOrNull(1)?.toIntOrNull() ?: 0
        val ver = marker.getOrNull(2)?.toIntOrNull() ?: 0
        val d = "hooks=$hooks ver=$ver sameBoot=${mBoot == boot}"
        return when {
            boot.isNotEmpty() && mBoot != boot -> Result(State.NO_MARKER, d)
            hooks <= 0 -> Result(State.NO_HOOK, d)
            ver < CURRENT_VERSION -> Result(State.STALE, d)
            else -> Result(State.ACTIVE, d)
        }
    }

    /** 需要 root；没有 root 时返回 UNKNOWN。 */
    fun check(): Result {
        if (RootShell.cachedRoot() != true && !RootShell.isRootGranted()) return Result(State.UNKNOWN, "no root")
        val r = RootShell.run("cat /proc/sys/kernel/random/boot_id; echo ---; cat ${xyz.synchub.android.xposed.XposedEntry.MARKER} 2>/dev/null", timeoutSec = 15)
        if (!r.ok && !r.out.contains("---")) return Result(State.UNKNOWN, "su 失败: ${r.out.take(80)}")
        return parse(r.out)
    }
}
