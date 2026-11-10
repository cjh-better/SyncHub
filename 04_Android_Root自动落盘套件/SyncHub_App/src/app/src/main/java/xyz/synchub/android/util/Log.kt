package xyz.synchub.android.util

import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 日志：内存环形缓冲 + 文件（filesDir/logs/synchub.log，超过 256 KB 轮转为 .1）。
 * 写文件是为了进程被系统杀掉 / 应用更新后，设置 → 查看日志 里仍能看到之前发生了什么。
 * 日志里不记录剪贴板正文和账号密码，只记录长度与 hash 前缀。
 */
object L {
    private const val MAX_MEM = 500
    private const val MAX_FILE = 256 * 1024L
    private val buf = ArrayDeque<String>()
    private val fmt = SimpleDateFormat("MM-dd HH:mm:ss", Locale.US)
    @Volatile private var file: File? = null

    /** 在 Application.onCreate 调用：载入上次进程留下的日志尾部。 */
    @Synchronized fun init(dir: File) {
        if (file != null) return
        runCatching {
            val d = File(dir, "logs").apply { mkdirs() }
            val f = File(d, "synchub.log")
            file = f
            val old = (File(d, "synchub.log.1").takeIf { it.exists() }?.readLines().orEmpty() +
                (if (f.exists()) f.readLines() else emptyList())).takeLast(MAX_MEM)
            buf.clear(); buf.addAll(old)
        }
    }

    @Synchronized fun i(msg: String) { runCatching { Log.i("SyncHub", msg) }; add("I", msg) }
    @Synchronized fun w(msg: String, t: Throwable? = null) {
        runCatching { Log.w("SyncHub", msg, t) }
        add("W", msg + (t?.let { " — ${it.javaClass.simpleName}: ${it.message}" } ?: ""))
    }
    @Synchronized fun lines(): List<String> = buf.toList().asReversed()
    @Synchronized fun text(): String = buf.joinToString("\n")

    private fun add(level: String, msg: String) {
        val line = "${fmt.format(Date())} $level $msg"
        buf.addLast(line)
        while (buf.size > MAX_MEM) buf.removeFirst()
        val f = file ?: return
        runCatching {
            if (f.length() > MAX_FILE) f.renameTo(File(f.parentFile, "synchub.log.1"))
            f.appendText(line + "\n")
        }
    }
}
