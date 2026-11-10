package xyz.synchub.android.net

import okhttp3.MediaType
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okio.BufferedSink
import okio.source
import org.json.JSONArray
import org.json.JSONObject
import java.io.InputStream
import java.io.OutputStream
import java.net.URLEncoder

/**
 * SyncHub API（synchub_server.py，经 nginx 暴露在 /api/hub/）。
 * 服务端要求 HTTP Basic 认证（账号与 SyncClipboard 相同），每个请求都带 Authorization 头。
 */
class HubClient(
    private val cfg: ServerConfig,
    private val http: OkHttpClient = Http.client,
    private val transfer: OkHttpClient = Http.transferClient,
) {
    fun listItems(limit: Int = 100, category: String? = null, q: String? = null): List<HubItem> {
        val qs = buildString {
            append("?limit=").append(limit)
            if (!category.isNullOrEmpty()) append("&category=").append(enc(category))
            if (!q.isNullOrEmpty()) append("&q=").append(enc(q))
        }
        val o = getJson("/api/hub/items$qs")
        return parseItems(o.optJSONArray("items")).hubOrder()
    }

    /** 磁盘容量与 SyncHub 占用（需要登录）。 */
    fun storage(): HubStorage = HubStorage.fromJson(getJson("/api/hub/storage"))

    /** 与 Windows / root 脚本相同的增量接口：since_id<=0 时只返回 latestId（不回补历史）。 */
    fun autoPull(sinceId: Long, device: String): AutoPullResult {
        val o = getJson("/api/hub/auto-pull?device=${enc(device)}&since_id=$sinceId")
        return AutoPullResult(o.optLong("latestId", sinceId), parseItems(o.optJSONArray("items")))
    }

    fun postText(text: String, from: String, syncClipboard: Boolean = false, starred: Boolean = false): HubItem {
        val body = JSONObject()
            .put("text", text).put("from", from)
            .put("starred", starred).put("syncClipboard", syncClipboard)
            .toString().toRequestBody(JSON)
        http.newCall(cfg.req("/api/hub/text").post(body).build()).execute().use { r ->
            val s = r.body?.string().orEmpty()
            if (!r.isSuccessful) throw ApiException(r.code, "POST /api/hub/text → HTTP ${r.code}: ${s.take(200)}")
            return HubItem.fromJson(JSONObject(s).getJSONObject("item"))
        }
    }

    /** 流式上传（与 Windows 客户端同协议：POST /api/hub/upload?filename=&from=，原始字节作 body）。 */
    fun upload(
        filename: String,
        length: Long,
        from: String,
        open: () -> InputStream,
        starred: Boolean = false,
        progress: (sent: Long, total: Long) -> Unit = { _, _ -> },
    ): HubItem {
        val body = object : RequestBody() {
            override fun contentType(): MediaType = "application/octet-stream".toMediaType()
            override fun contentLength(): Long = length
            override fun writeTo(sink: BufferedSink) {
                open().use { input ->
                    val buf = ByteArray(256 * 1024)
                    var sent = 0L
                    var lastReport = 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        sink.write(buf, 0, n)
                        sent += n
                        if (sent - lastReport > 512 * 1024 || sent == length) {
                            lastReport = sent; progress(sent, length)
                        }
                    }
                }
            }
        }
        // 服务端对 filename 先 parse_qs 再 unquote（解码两次），所以这里编码两次，"%"、"+" 等字符才能原样保留
        val qs = "?filename=${enc(enc(filename))}&from=${enc(from)}&starred=${if (starred) 1 else 0}&pinned=0"
        transfer.newCall(cfg.req("/api/hub/upload$qs").post(body).build()).execute().use { r ->
            val s = r.body?.string().orEmpty()
            if (!r.isSuccessful) throw ApiException(r.code, "上传失败 HTTP ${r.code}: ${s.take(200)}")
            val o = JSONObject(s)
            if (!o.optBoolean("ok")) throw ApiException(500, o.optString("error", "上传失败"))
            return HubItem.fromJson(o.getJSONObject("item"))
        }
    }

    /** 下载到输出流，返回字节数。 */
    fun download(item: HubItem, out: OutputStream, progress: (Long, Long) -> Unit = { _, _ -> }): Long {
        val path = item.downloadUrl ?: throw ApiException(400, "该条目没有文件")
        transfer.newCall(cfg.req(path).get().build()).execute().use { r ->
            if (!r.isSuccessful) throw ApiException(r.code, "下载失败 HTTP ${r.code}")
            val body = r.body!!
            val total = body.contentLength().takeIf { it > 0 } ?: item.size
            var got = 0L
            var last = 0L
            body.byteStream().use { input ->
                val buf = ByteArray(256 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    got += n
                    if (got - last > 512 * 1024) { last = got; progress(got, total) }
                }
            }
            progress(got, total)
            return got
        }
    }

    fun update(id: Long, starred: Boolean? = null, pinned: Boolean? = null): HubItem {
        val o = JSONObject()
        starred?.let { o.put("starred", it) }
        pinned?.let { o.put("pinned", it) }
        http.newCall(cfg.req("/api/hub/item/$id/update").post(o.toString().toRequestBody(JSON)).build()).execute().use { r ->
            val s = r.body?.string().orEmpty()
            if (!r.isSuccessful) throw ApiException(r.code, "更新失败 HTTP ${r.code}")
            return HubItem.fromJson(JSONObject(s).getJSONObject("item"))
        }
    }

    fun delete(id: Long) {
        http.newCall(cfg.req("/api/hub/item/$id/delete").post("{}".toRequestBody(JSON)).build()).execute().use { r ->
            if (!r.isSuccessful) throw ApiException(r.code, "删除失败 HTTP ${r.code}")
        }
    }

    private fun getJson(path: String): JSONObject {
        http.newCall(cfg.req(path).get().build()).execute().use { r ->
            val s = r.body?.string().orEmpty()
            if (!r.isSuccessful) throw ApiException(r.code, "GET $path → HTTP ${r.code}")
            val o = JSONObject(s)
            if (!o.optBoolean("ok", false)) throw ApiException(500, "服务器返回异常: ${s.take(200)}")
            return o
        }
    }

    private fun parseItems(arr: JSONArray?): List<HubItem> {
        if (arr == null) return emptyList()
        return (0 until arr.length()).map { HubItem.fromJson(arr.getJSONObject(it)) }
    }

    companion object {
        private val JSON = "application/json; charset=utf-8".toMediaType()
        fun enc(s: String): String = URLEncoder.encode(s, "UTF-8").replace("+", "%20")
    }
}
