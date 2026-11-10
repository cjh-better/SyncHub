package xyz.synchub.android.util

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

enum class ClipMode(val label: String) {
    LSPOSED("LSPosed 模块"), ROOT("Root 兼容模式"), FOREGROUND("仅前台"), OFF("已关闭")
}

data class RuntimeStatus(
    val serviceRunning: Boolean = false,
    val connected: Boolean? = null,
    val lastError: String? = null,
    val lastOkAt: Long = 0,
    val clipMode: ClipMode = ClipMode.OFF,
    val rootHelperAlive: Boolean = false,
    val systemHookVerified: Boolean? = null,
    val lastPush: String? = null,
    val lastPull: String? = null,
    val lastReceived: String? = null,
    val transfers: Map<String, String> = emptyMap(),
)

object Status {
    val flow = MutableStateFlow(RuntimeStatus())
    fun update(f: (RuntimeStatus) -> RuntimeStatus) = flow.update(f)
}
