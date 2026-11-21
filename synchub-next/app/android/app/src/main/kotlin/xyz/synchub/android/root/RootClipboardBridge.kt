package xyz.synchub.android.root

import android.content.Context
import android.os.Build
import android.os.Process
import xyz.synchub.android.util.Hashing
import xyz.synchub.android.util.L
import xyz.synchub.android.util.Status
import java.io.BufferedWriter
import java.util.Base64

/**
 * 管理 ClipHelper 子进程（su → app_process → 降权 shell），把剪贴板变化回调给同步服务，
 * 并提供毫秒级 `writeText` 后台写剪贴板通道（彻底绕过 ColorOS/RealmeUI 等系统对后台写剪贴板的拦截）。
 * 进程意外退出时按 3s → 60s 退避重启。
 */
class RootClipboardBridge(
    private val ctx: Context,
    private val onText: (String) -> Unit,
) {
    @Volatile private var proc: java.lang.Process? = null
    @Volatile private var stdinWriter: BufferedWriter? = null
    private val writeLock = Any()

    /** Root 进程最近一次看到的剪贴板文本与摘要（用于剪贴板快照回退与回读确认）。 */
    @Volatile var lastSeenText: String? = null
        private set

    @Volatile var lastSeenHash: String? = null
        private set

    @Volatile var ready: Boolean = false
        private set

    @Volatile private var running = false
    private var thread: Thread? = null
    @Volatile private var stderrThread: Thread? = null

    fun start() {
        if (running) return
        running = true
        thread = Thread({ loop() }, "root-clip-bridge").apply {
            isDaemon = true
            start()
        }
    }

    fun stop() {
        running = false
        ready = false
        synchronized(writeLock) {
            runCatching { stdinWriter?.close() }
            stdinWriter = null
        }
        runCatching { proc?.outputStream?.close() }
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                proc?.destroyForcibly()
            } else {
                proc?.destroy()
            }
        }
        proc = null
        stderrThread?.interrupt()
        stderrThread = null
        thread?.interrupt()
        thread = null
        Status.update { it.copy(rootHelperAlive = false) }
    }

    /** 通过已常驻的 ClipHelper (uid 2000 com.android.shell) 写入剪贴板文本。 */
    fun writeText(text: String): Boolean {
        if (!ready) return false
        val encoded = Base64.getEncoder().encodeToString(text.toByteArray(Charsets.UTF_8))
        synchronized(writeLock) {
            val w = stdinWriter ?: return false
            return try {
                lastSeenText = text
                lastSeenHash = Hashing.textHash(text)
                w.write("SET $encoded\n")
                w.flush()
                true
            } catch (t: Throwable) {
                L.w("通过 Root 守护进程写入剪贴板失败", t)
                false
            }
        }
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
            try {
                Thread.sleep(backoff)
            } catch (_: InterruptedException) {
                break
            }
            backoff = (backoff * 2).coerceAtMost(60_000)
        }
    }

    private fun runOnce() {
        val apk = ctx.applicationInfo.sourceDir
        val userId = Process.myUserHandle().hashCode()
        val p = ProcessBuilder("su").redirectErrorStream(false).start()
        proc = p
        // 注意：不关闭 stdin，ClipHelper 以 stdin EOF 判断父进程是否退出，并接收 `SET <base64>` 指令
        val w = p.outputStream.bufferedWriter(Charsets.UTF_8)
        synchronized(writeLock) {
            stdinWriter = w
            w.write("export CLASSPATH=${RootShell.quote(apk)}\n")
            w.write("exec app_process /system/bin --nice-name=synchub_clip xyz.synchub.android.root.ClipHelper $userId\n")
            w.flush()
        }
        stderrThread = Thread(
            { runCatching { p.errorStream.bufferedReader().forEachLine { L.w("clip-helper: $it") } } },
            "root-clip-stderr",
        ).apply {
            isDaemon = true
            start()
        }
        p.inputStream.bufferedReader().forEachLine { line ->
            when {
                line.startsWith("READY") -> {
                    L.i("Root 剪贴板进程就绪: $line")
                    ready = true
                    Status.update { it.copy(rootHelperAlive = true) }
                }
                line.startsWith("BASE ") -> {
                    val text = runCatching {
                        String(Base64.getDecoder().decode(line.substring(5)), Charsets.UTF_8)
                    }.getOrNull()
                    if (!text.isNullOrEmpty()) {
                        lastSeenText = text
                        lastSeenHash = Hashing.textHash(text)
                    }
                }
                line.startsWith("CLIP ") -> {
                    val text = runCatching {
                        String(Base64.getDecoder().decode(line.substring(5)), Charsets.UTF_8)
                    }.getOrNull()
                    if (!text.isNullOrEmpty()) {
                        lastSeenText = text
                        lastSeenHash = Hashing.textHash(text)
                        L.i("Root 进程检测到剪贴板变化 (${text.length} 字)")
                        onText(text)
                    }
                }
                line.startsWith("WROTE ") -> {
                    L.i("已通过 Root 通道写入远端剪贴板 (${line.substring(6).trim()} 字)")
                }
                line.startsWith("ERR") -> L.w("clip-helper: $line")
            }
        }
        ready = false
        synchronized(writeLock) {
            stdinWriter = null
        }
        runCatching { p.waitFor() }
        L.w("Root 剪贴板进程退出 code=${runCatching { p.exitValue() }.getOrNull()}")
    }

    companion object {
        /** 当未常驻 RootClipboardBridge（例如处于 LSPosed 模式）但后台写剪贴板被系统拦截时的单次 Root 补偿写入。 */
        fun writeOnceViaRoot(ctx: Context, text: String): Boolean {
            if (!RootShell.probeRoot(timeoutSec = 5)) return false
            val apk = ctx.applicationInfo.sourceDir
            val userId = Process.myUserHandle().hashCode()
            val encoded = Base64.getEncoder().encodeToString(text.toByteArray(Charsets.UTF_8))
            val cmd = "CLASSPATH=${RootShell.quote(apk)} app_process /system/bin " +
                "xyz.synchub.android.root.ClipHelper --set $userId ${RootShell.quote(encoded)}"
            val r = RootShell.run(cmd, timeoutSec = 8)
            return r.ok && r.out.contains("OK")
        }
    }
}
