package xyz.synchub.android.root

import android.os.Build
import java.io.File
import java.util.concurrent.TimeUnit

/** 极简 su 封装（不引入 libsu，兼容 Magisk / KernelSU / APatch）。 */
object RootShell {
    data class Result(val code: Int, val out: String) {
        val ok get() = code == 0
    }

    @Volatile private var grantedCache: Boolean = false
    @Volatile private var lastDeniedAt: Long = 0L

    fun suExists(): Boolean = listOf(
        "/system/bin/su",
        "/system/xbin/su",
        "/sbin/su",
        "/debug_ramdisk/su",
        "/data/adb/ksu/bin/su",
        "/data/adb/ap/bin/su",
    ).any { File(it).exists() } || pathHasSu()

    private fun pathHasSu(): Boolean =
        (System.getenv("PATH") ?: "").split(':').any { it.isNotEmpty() && File(it, "su").exists() }

    /**
     * 非侵入式检测或请求 Root：
     * - KernelSU / APatch：用户在管理器中开启 SyncHub 的超级用户权限后，`su` 立即可见且毫秒级静默返回 `uid=0`；
     *   未授权时 `ProcessBuilder("su")` 立即抛出 IOException 返回 false，绝不卡顿。
     * - Magisk：若已授权直接返回 true；首次调用会弹出授权框。
     * - 绝不永久缓存 `false`（仅做 3 秒防抖），保证用户在管理器里补授 Root 后切回应用立即生效！
     */
    fun probeRoot(timeoutSec: Long = 8, force: Boolean = false): Boolean {
        if (grantedCache) return true
        val now = System.currentTimeMillis()
        if (!force && now - lastDeniedAt < 3_000L) {
            return false
        }
        val r = run("id", timeoutSec = timeoutSec)
        val ok = r.ok && r.out.contains("uid=0")
        if (ok) {
            grantedCache = true
            lastDeniedAt = 0L
        } else {
            lastDeniedAt = System.currentTimeMillis()
        }
        return ok
    }

    /** 主动触发 Magisk / KernelSU / APatch 授权检测（最长等待 60s 供用户点击允许）。 */
    fun requestRoot(): Boolean = probeRoot(timeoutSec = 60, force = true)

    fun isRootGranted(): Boolean = if (grantedCache) true else probeRoot(timeoutSec = 8, force = false)

    fun cachedRoot(): Boolean? = if (grantedCache) true else null

    fun run(cmd: String, timeoutSec: Long = 30): Result = try {
        val p = ProcessBuilder("su").redirectErrorStream(true).start()
        p.outputStream.bufferedWriter().use { w ->
            w.write(cmd)
            w.write("\nexit\n")
        }
        val out = StringBuilder()
        val reader = Thread {
            runCatching {
                p.inputStream.bufferedReader().forEachLine { out.appendLine(it) }
            }
        }
        reader.start()
        if (!p.waitFor(timeoutSec, TimeUnit.SECONDS)) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                p.destroyForcibly()
            } else {
                p.destroy()
            }
            reader.interrupt()
            reader.join(500)
            Result(-2, "timeout")
        } else {
            reader.join(2000)
            Result(p.exitValue(), out.toString().trim())
        }
    } catch (e: Exception) {
        Result(-1, e.toString())
    }

    fun quote(s: String): String = "'" + s.replace("'", "'\\''") + "'"
}
