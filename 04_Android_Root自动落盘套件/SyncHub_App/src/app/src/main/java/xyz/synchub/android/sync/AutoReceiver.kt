package xyz.synchub.android.sync

import xyz.synchub.android.net.HubClient
import xyz.synchub.android.net.HubItem
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream

/** 落盘目标（Android 上为 /sdcard/Download/<子目录> 直接写文件，或 MediaStore.Downloads）。 */
interface FileSink {
    fun existsWithSize(name: String, size: Long): Boolean
    fun exists(name: String): Boolean
    fun begin(name: String): PendingFile
    val displayDir: String
}

interface PendingFile {
    val out: OutputStream
    fun commit(): String     // 返回最终可读路径
    fun abort()
}

class DirectFileSink(private val dir: File) : FileSink {
    override val displayDir: String get() = dir.absolutePath
    override fun existsWithSize(name: String, size: Long): Boolean {
        val f = File(dir, name); return f.isFile && size > 0 && f.length() == size
    }
    override fun exists(name: String) = File(dir, name).exists()
    override fun begin(name: String): PendingFile {
        dir.mkdirs()
        val target = File(dir, name)
        val part = File(dir, "$name.downloading")
        val fos = FileOutputStream(part)
        return object : PendingFile {
            override val out: OutputStream = fos
            override fun commit(): String {
                fos.close()
                if (!part.renameTo(target)) { part.copyTo(target, true); part.delete() }
                return target.absolutePath
            }
            override fun abort() { runCatching { fos.close() }; part.delete() }
        }
    }
}

data class Received(val item: HubItem, val path: String)

/**
 * 与 Windows 客户端 / 原 root 脚本一致的自动接收逻辑：
 * GET /api/hub/auto-pull?device=android&since_id=<last>；已存在且大小一致则跳过；同名不同大小 → "名称 (1).ext"；
 * 全部成功后才推进 last_id（单个条目连续失败 3 次后放弃，避免卡死）。
 */
class AutoReceiver(
    private val hub: HubClient,
    private val state: SyncStateStore,
    private val sinkProvider: () -> FileSink,
    private val device: String = "android",
    private val skipHash: (String) -> Boolean = { false },
    private val onProgress: (HubItem, Long, Long) -> Unit = { _, _, _ -> },
) {
    private val failures = HashMap<Long, Int>()

    fun pollOnce(): List<Received> {
        val last = state.lastHubId
        val res = hub.autoPull(last, device)
        if (last <= 0) {           // 首次：只记录位置，不回补历史（与服务端语义一致）
            state.lastHubId = res.latestId
            return emptyList()
        }
        val sink = sinkProvider()
        val out = ArrayList<Received>()
        var blocked = false
        for (item in res.items) {
            if (item.downloadUrl == null) continue
            if (item.hash.isNotEmpty() && skipHash(item.hash)) continue
            if ((failures[item.id] ?: 0) >= 3) continue
            val name = sanitize(item.filename.ifEmpty { "file_${item.id}" })
            if (sink.existsWithSize(name, item.size)) continue
            val finalName = if (sink.exists(name)) uniqueName(sink, name) else name
            val pf = sink.begin(finalName)
            try {
                hub.download(item, pf.out) { got, total -> onProgress(item, got, total) }
                out += Received(item, pf.commit())
                failures.remove(item.id)
            } catch (e: Exception) {
                pf.abort()
                failures[item.id] = (failures[item.id] ?: 0) + 1
                blocked = true
            }
        }
        if (!blocked && res.latestId > last) state.lastHubId = res.latestId
        return out
    }

    companion object {
        fun sanitize(name: String): String {
            val base = name.substringAfterLast('/').substringAfterLast('\\')
            return base.replace(Regex("[\\u0000-\\u001f:*?\"<>|]"), "_").trim().ifEmpty { "file" }.take(200)
        }

        fun uniqueName(sink: FileSink, name: String): String {
            val dot = name.lastIndexOf('.')
            val (b, e) = if (dot > 0) name.substring(0, dot) to name.substring(dot) else name to ""
            var i = 1
            while (true) {
                val c = "$b ($i)$e"
                if (!sink.exists(c)) return c
                i++
            }
        }
    }
}
