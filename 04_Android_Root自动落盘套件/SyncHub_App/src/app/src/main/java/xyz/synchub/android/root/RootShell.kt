package xyz.synchub.android.root

import java.io.File
import java.util.concurrent.TimeUnit

/** 极简 su 封装（不引入 libsu）。 */
object RootShell {
    data class Result(val code: Int, val out: String) { val ok get() = code == 0 }

    @Volatile private var cached: Boolean? = null

    fun suExists(): Boolean = listOf("/system/bin/su", "/system/xbin/su", "/sbin/su", "/debug_ramdisk/su",
        "/data/adb/ksu/bin/su", "/data/adb/ap/bin/su").any { File(it).exists() } || pathHasSu()

    private fun pathHasSu() = (System.getenv("PATH") ?: "").split(':').any { File(it, "su").exists() }

    /** 会触发 Magisk / KernelSU / APatch 的授权弹窗（KernelSU 授权前 su 文件不可见，所以不预先检查 suExists）。 */
    fun requestRoot(): Boolean {
        val r = run("id", timeoutSec = 60)
        val ok = r.ok && r.out.contains("uid=0")
        cached = ok
        return ok
    }

    fun isRootGranted(): Boolean = cached ?: requestRoot()

    fun cachedRoot(): Boolean? = cached

    fun run(cmd: String, timeoutSec: Long = 30): Result = try {
        val p = ProcessBuilder("su").redirectErrorStream(true).start()
        p.outputStream.bufferedWriter().use { w -> w.write(cmd); w.write("\nexit\n") }
        val out = StringBuilder()
        val reader = Thread { runCatching { p.inputStream.bufferedReader().forEachLine { out.appendLine(it) } } }
        reader.start()
        if (!p.waitFor(timeoutSec, TimeUnit.SECONDS)) { p.destroy(); Result(-2, "timeout") }
        else { reader.join(2000); Result(p.exitValue(), out.toString().trim()) }
    } catch (e: Exception) {
        Result(-1, e.toString())
    }

    fun quote(s: String) = "'" + s.replace("'", "'\\''") + "'"
}
