package xyz.synchub.android.root

import android.content.Context
import android.os.Process
import xyz.synchub.android.util.L
import xyz.synchub.android.util.Status
import java.util.Base64

/**
 * 管理 ClipHelper 子进程（su → app_process → 降权 shell），把剪贴板变化回调给同步服务。
 * 进程意外退出时按 3s → 60s 退避重启。
 */
class RootClipboardBridge(
    private val ctx: Context,
    private val onText: (String) -> Unit,
) {
    @Volatile private var proc: java.lang.Process? = null
    /** Root 进程最近一次看到的剪贴板文本 hash（用来确认应用写入是否真正生效）。 */
    @Volatile var lastSeenHash: String? = null
        private set
    @Volatile var ready = false
        private set
    @Volatile private var running = false
    private var thread: Thread? = null

    fun start() {
        if (running) return
        running = true
        thread = Thread({ loop() }, "root-clip-bridge").apply { isDaemon = true; start() }
    }

    fun stop() {
        running = false
        ready = false
        proc?.destroy()
        proc = null
        thread?.interrupt()
        Status.update { it.copy(rootHelperAlive = false) }
    }

    private fun loop() {
        var backoff = 3000L
        while (running) {
            val started = System.currentTimeMillis()
            try {
                runOnce()
            } catch (e: Exception) {
                L.w("Root 剪贴板进程异常", e)
            }
            Status.update { it.copy(rootHelperAlive = false) }
            if (!running) break
            if (System.currentTimeMillis() - started > 60_000) backoff = 3000L
            try { Thread.sleep(backoff) } catch (_: InterruptedException) { break }
            backoff = (backoff * 2).coerceAtMost(60_000)
        }
    }

    private fun runOnce() {
        val apk = ctx.applicationInfo.sourceDir
        val userId = Process.myUserHandle().hashCode() // UserHandle.hashCode() == userId
        val p = ProcessBuilder("su").redirectErrorStream(false).start()
        proc = p
        // 注意：不关闭 stdin，ClipHelper 以 stdin EOF 判断父进程是否退出
        val w = p.outputStream.bufferedWriter()
        w.write("export CLASSPATH=${RootShell.quote(apk)}\n")
        w.write("exec app_process /system/bin --nice-name=synchub_clip xyz.synchub.android.root.ClipHelper $userId\n")
        w.flush()
        Thread({ runCatching { p.errorStream.bufferedReader().forEachLine { L.w("clip-helper: $it") } } },
            "root-clip-stderr").apply { isDaemon = true; start() }
        p.inputStream.bufferedReader().forEachLine { line ->
            when {
                line.startsWith("READY") -> {
                    L.i("Root 剪贴板进程就绪: $line")
                    ready = true
                    Status.update { it.copy(rootHelperAlive = true) }
                }
                line.startsWith("BASE ") -> {
                    val text = runCatching { String(Base64.getDecoder().decode(line.substring(5)), Charsets.UTF_8) }.getOrNull()
                    if (!text.isNullOrEmpty()) lastSeenHash = xyz.synchub.android.net.Hashing.textHash(text)
                }
                line.startsWith("CLIP ") -> {
                    val text = runCatching { String(Base64.getDecoder().decode(line.substring(5)), Charsets.UTF_8) }.getOrNull()
                    if (!text.isNullOrEmpty()) {
                        lastSeenHash = xyz.synchub.android.net.Hashing.textHash(text)
                        L.i("Root 进程检测到剪贴板变化 (${text.length} 字)")
                        onText(text)
                    }
                }
                line.startsWith("ERR") -> L.w("clip-helper: $line")
            }
        }
        ready = false
        runCatching { p.waitFor() }
        L.w("Root 剪贴板进程退出 code=${runCatching { p.exitValue() }.getOrNull()}")
    }
}
