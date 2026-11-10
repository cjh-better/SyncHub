package xyz.synchub.android.net

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import java.net.URLEncoder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/**
 * SyncClipboard 官方服务器协议（WebDAV 兼容 API，与 Windows/macOS 官方客户端互通）：
 *   GET  /SyncClipboard.json        GET /file/{dataName}
 *   PUT  /file/{dataName}           PUT /SyncClipboard.json
 */
class SyncClipboardClient(
    private val cfg: ServerConfig,
    private val http: OkHttpClient = Http.client,
) {
    fun getProfile(): ClipProfile {
        http.newCall(cfg.req("/SyncClipboard.json").get().build()).execute().use { r ->
            if (!r.isSuccessful) throw ApiException(r.code, "GET SyncClipboard.json → HTTP ${r.code}")
            return ClipProfile.parse(r.body!!.string())
        }
    }

    fun getFile(dataName: String, maxBytes: Long = 64L * 1024 * 1024): ByteArray {
        http.newCall(cfg.req("/file/" + enc(dataName)).get().build()).execute().use { r ->
            if (!r.isSuccessful) throw ApiException(r.code, "GET /file/$dataName → HTTP ${r.code}")
            val len = r.body!!.contentLength()
            if (len > maxBytes) throw ApiException(413, "文件过大 ($len B)")
            return r.body!!.bytes()
        }
    }

    fun putFile(dataName: String, bytes: ByteArray) {
        val body = bytes.toRequestBody("application/octet-stream".toMediaType())
        http.newCall(cfg.req("/file/" + enc(dataName)).put(body).build()).execute().use { r ->
            if (!r.isSuccessful) throw ApiException(r.code, "PUT /file/$dataName → HTTP ${r.code}: ${r.body?.string()?.take(200)}")
        }
    }

    fun putProfile(p: ClipProfile) {
        val body = p.toJson().toRequestBody("application/json; charset=utf-8".toMediaType())
        http.newCall(cfg.req("/SyncClipboard.json").put(body).build()).execute().use { r ->
            if (!r.isSuccessful) throw ApiException(r.code, "PUT SyncClipboard.json → HTTP ${r.code}: ${r.body?.string()?.take(200)}")
        }
    }

    /** 读取远端完整文本（长文本 hasData=true 时从 /file 下载）。 */
    fun fetchFullText(p: ClipProfile): String {
        if (p.type != "Text") return p.text
        if (!p.hasData || p.dataName.isNullOrEmpty()) return p.text
        return String(getFile(p.dataName), Charsets.UTF_8)
    }

    /** 推送文本，返回 profile hash。超过 10240 字符时按官方客户端行为改用 .txt 附件。 */
    fun pushText(text: String): String {
        val hash = Hashing.textHash(text)
        if (text.length > TEXT_THRESHOLD) {
            val name = "Text_${timeName()}.txt"
            val bytes = text.toByteArray(Charsets.UTF_8)
            putFile(name, bytes)
            putProfile(ClipProfile("Text", hash, text.substring(0, TEXT_THRESHOLD), true, name,
                transferDataHash = Hashing.sha256Hex(bytes), size = text.length.toLong()))
        } else {
            putProfile(ClipProfile("Text", hash, text, false, null, size = text.length.toLong()))
        }
        return hash
    }

    /** 推送图片 / 单文件（type = Image 或 File），返回 profile hash。 */
    fun pushData(type: String, fileName: String, bytes: ByteArray): String {
        val contentHash = Hashing.sha256Hex(bytes)
        val hash = Hashing.fileProfileHash(fileName, contentHash)
        putFile(fileName, bytes)
        putProfile(ClipProfile(type, hash, fileName, true, fileName, transferDataHash = contentHash, size = bytes.size.toLong()))
        return hash
    }

    companion object {
        const val TEXT_THRESHOLD = 10240
        private fun enc(s: String) = URLEncoder.encode(s, "UTF-8").replace("+", "%20")
        fun timeName(): String =
            SimpleDateFormat("yyyy-MM-dd_HH-mm-ss", Locale.US).format(Date()) + "_" +
                UUID.randomUUID().toString().replace("-", "").take(8)
    }
}
