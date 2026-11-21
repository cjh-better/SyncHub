package xyz.synchub.android.root

import xyz.synchub.android.xposed.XposedEntry

/**
 * 确认 LSPosed 的“系统框架”钩子在本次开机真正生效。
 * ModuleStatus.isActive() 只说明“本应用”作用域生效；若刚启用/更新模块未重启手机、或作用域未勾选“系统框架”，
 * 系统框架钩子并未加载，此时会自动退回 Root 兼容模式立即工作。
 */
object HookCheck {
    enum class State(val label: String) {
        ACTIVE("系统框架钩子已生效"),
        NO_MARKER("待重启生效（模块刚启用或刚更新，重启前自动由 Root 守护兜底）"),
        STALE("系统框架钩子运行中（旧版钩子，重启后升级到最新版）"),
        NO_HOOK("系统框架已加载模块，但未匹配到剪贴板方法（已由 Root 守护兜底）"),
        UNKNOWN("待校验系统框架状态"),
    }

    data class Result(val state: State, val detail: String)

    const val CURRENT_VERSION = 3

    fun parse(out: String): Result {
        val parts = out.split("---")
        val boot = parts.getOrNull(0)?.trim().orEmpty()
        val marker = parts.getOrNull(1)?.trim()?.lines()?.map { it.trim() }.orEmpty()
        if (marker.isEmpty() || marker[0].isEmpty()) return Result(State.NO_MARKER, "marker 不存在（需重启手机使系统框架加载钩子）")
        val mBoot = marker[0]
        val hooks = marker.getOrNull(1)?.toIntOrNull() ?: 0
        val ver = marker.getOrNull(2)?.toIntOrNull() ?: 0
        val d = "hooks=$hooks ver=$ver sameBoot=${mBoot == boot}"
        return when {
            boot.isNotEmpty() && mBoot != boot -> Result(State.NO_MARKER, "$d（上次开机遗留，需重启手机）")
            hooks <= 0 -> Result(State.NO_HOOK, d)
            ver < CURRENT_VERSION -> Result(State.STALE, d)
            else -> Result(State.ACTIVE, d)
        }
    }

    /** 需要 root；没有 root 时返回 UNKNOWN。 */
    fun check(): Result {
        if (!RootShell.probeRoot(timeoutSec = 6)) {
            return Result(State.UNKNOWN, "no root")
        }
        val r = RootShell.run(
            "cat /proc/sys/kernel/random/boot_id; echo ---; cat ${XposedEntry.MARKER} 2>/dev/null",
            timeoutSec = 10,
        )
        if (!r.ok && !r.out.contains("---")) return Result(State.UNKNOWN, "su 失败: ${r.out.take(80)}")
        return parse(r.out)
    }
}
