package xyz.synchub.android.sync

import xyz.synchub.android.net.ClipProfile
import xyz.synchub.android.net.Hashing
import xyz.synchub.android.net.SyncClipboardClient

/** 持久化的同步状态（Android 端由 SharedPreferences 实现，测试用内存实现）。 */
interface SyncStateStore {
    var lastRemoteKey: String?
    var lastHubId: Long
}

class MemoryStateStore(override var lastRemoteKey: String? = null, override var lastHubId: Long = 0) : SyncStateStore

sealed class RemoteChange {
    data class Text(val text: String, val hash: String) : RemoteChange()
    data class Image(val name: String, val bytes: ByteArray, val hash: String) : RemoteChange()
}

/**
 * 剪贴板双向同步的纯逻辑部分（不依赖 Android，可在 JVM 单测）。
 * 防回环：只与“本机剪贴板当前已同步的内容”（[current]）比较——自己写入本地剪贴板后触发的回调、
 * 或刚推送的内容再次被轮询到时跳过；但再次复制更早出现过的内容（A→B→A）仍会正常同步。
 * [recent] 只用于自动接收跳过“剪贴板图片”这类已经通过剪贴板同步过的条目。
 * 每个推送 / 拉取决定（包括跳过的原因）都通过 [log] 输出，日志里只出现长度和 hash 前缀，不出现正文。
 */
class ClipSyncEngine(
    private val client: SyncClipboardClient,
    private val state: SyncStateStore,
    private val pullImages: () -> Boolean = { true },
    private val maxImageBytes: Long = 20L * 1024 * 1024,
    private val log: (String) -> Unit = {},
) {
    private val recent = LinkedHashSet<String>()
    /** 本机剪贴板当前内容对应的 key（文本 = 文本 hash，图片 = "IMG:"+内容 hash）。 */
    @Volatile private var current: String? = null
    /** 远端某个变化下载失败的次数（同一个 key 连续失败 3 次后放弃，避免卡死在坏条目上）。 */
    private var failKey: String? = null
    private var failCount = 0

    @Synchronized fun remember(hash: String) {
        if (hash.isEmpty()) return
        val h = hash.uppercase()
        recent.remove(h); recent.add(h)
        while (recent.size > 32) recent.remove(recent.first())
    }

    @Synchronized fun isKnown(hash: String) = hash.isNotEmpty() && recent.contains(hash.uppercase())

    /** 写入本机剪贴板失败时调用：撤销 [pollRemote] 里对 current 的更新，避免之后同内容的本地复制被误判为回环。 */
    @Synchronized fun release(key: String) { if (current == key.uppercase()) current = null }

    /** 本地文本变化 → 推送。返回 true 表示实际推送了。 */
    fun onLocalText(text: String, src: String = "local"): Boolean {
        if (text.isBlank()) { log("本地剪贴板[$src]: 空白文本，跳过"); return false }
        val hash = Hashing.textHash(text)
        synchronized(this) {
            if (current == hash) { log("本地剪贴板[$src]: ${text.length} 字 #${short(hash)} 与当前已同步内容相同（刚写入/刚推送），跳过"); return false }
            current = hash
        }
        try {
            client.pushText(text)
        } catch (e: Exception) {
            synchronized(this) { if (current == hash) current = null }
            throw e
        }
        remember(hash)
        state.lastRemoteKey = hash
        log("本地剪贴板[$src]: 已推送 ${text.length} 字 #${short(hash)}")
        return true
    }

    /** 本地图片变化 → 推送（Image 类型）。 */
    fun onLocalImage(fileName: String, bytes: ByteArray): Boolean {
        val hash = Hashing.fileProfileHash(fileName, Hashing.sha256Hex(bytes))
        val contentKey = ("IMG:" + Hashing.sha256Hex(bytes)).uppercase()
        synchronized(this) {
            if (current == contentKey) { log("本地图片 ${bytes.size} B 与当前已同步内容相同，跳过"); return false }
            current = contentKey
        }
        try {
            client.pushData("Image", fileName, bytes)
        } catch (e: Exception) {
            synchronized(this) { if (current == contentKey) current = null }
            throw e
        }
        remember(hash); remember(contentKey)
        state.lastRemoteKey = hash
        log("本地图片: 已推送 $fileName (${bytes.size} B)")
        return true
    }

    /**
     * 轮询远端。首次运行（没有任何同步记录）只记录当前远端状态，不覆盖本机剪贴板。
     * lastRemoteKey 只在远端内容真正处理完（下载成功 / 明确跳过）后才前进，
     * 下载失败时下次轮询会重试，而不是把这次变化丢掉。
     */
    fun pollRemote(): RemoteChange? {
        val p = client.getProfile()
        val key = keyOf(p)
        val last = state.lastRemoteKey
        if (key == last) return null
        if (last == null) {
            state.lastRemoteKey = key
            log("远端: 首次同步，记录当前远端 ${p.type} #${short(key)} 作为起点（不覆盖本机剪贴板）")
            return null
        }
        val change = try {
            when (p.type) {
                "Text" -> {
                    val full = client.fetchFullText(p)
                    if (full.isEmpty()) {
                        log("远端: 文本为空 #${short(key)}，跳过"); null
                    } else {
                        val h = Hashing.textHash(full)
                        remember(h); remember(key)
                        synchronized(this) {
                            if (current == h) { log("远端: 文本 ${full.length} 字 #${short(h)} 与本机剪贴板相同（自己刚推送的），跳过"); null }
                            else { current = h; RemoteChange.Text(full, h) }
                        }
                    }
                }
                "Image" -> when {
                    !pullImages() -> { log("远端: 图片 ${p.dataName}，已关闭图片同步，跳过"); null }
                    p.dataName.isNullOrEmpty() -> { log("远端: 图片没有 dataName，跳过"); null }
                    (p.size ?: 0) > maxImageBytes -> { log("远端: 图片 ${p.dataName} 过大 (${p.size} B)，跳过"); null }
                    else -> {
                        val bytes = client.getFile(p.dataName, maxImageBytes)
                        val contentKey = ("IMG:" + Hashing.sha256Hex(bytes)).uppercase()
                        remember(key); remember(contentKey)
                        synchronized(this) {
                            if (current == contentKey) { log("远端: 图片 ${p.dataName} 与本机剪贴板相同，跳过"); null }
                            else { current = contentKey; RemoteChange.Image(p.dataName, bytes, key) }
                        }
                    }
                }
                else -> { log("远端: ${p.type} ${p.dataName ?: ""}（文件交给自动接收处理），剪贴板跳过"); null }
            }
        } catch (e: Exception) {
            synchronized(this) {
                if (failKey == key) failCount++ else { failKey = key; failCount = 1 }
                if (failCount >= 3) {
                    state.lastRemoteKey = key; failKey = null; failCount = 0
                    log("远端: ${p.type} #${short(key)} 连续 3 次下载失败，放弃这一条: ${e.message}")
                }
            }
            throw e
        }
        state.lastRemoteKey = key
        synchronized(this) { failKey = null; failCount = 0 }
        return change
    }

    companion object {
        fun keyOf(p: ClipProfile): String =
            p.hash.ifEmpty { Hashing.textHash(p.type + "|" + p.text + "|" + (p.dataName ?: "")) }.uppercase()

        fun short(h: String) = h.takeLast(64).take(8)
    }
}
