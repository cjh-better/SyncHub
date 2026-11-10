package xyz.synchub.android.net

import org.json.JSONObject

/** SyncClipboard.json 剪贴板描述（v3.1.1+ 协议，字段大小写敏感，官方服务器输出 camelCase）。 */
data class ClipProfile(
    val type: String,          // Text / Image / File / Group
    val hash: String,
    val text: String,
    val hasData: Boolean,
    val dataName: String?,
    val transferDataHash: String? = null,
    val size: Long? = null,
) {
    fun toJson(): String {
        val o = JSONObject()
        o.put("type", type)
        o.put("hash", hash)
        o.put("text", text)
        o.put("hasData", hasData)
        if (dataName != null) o.put("dataName", dataName) else o.put("dataName", JSONObject.NULL)
        if (transferDataHash != null) o.put("transferDataHash", transferDataHash)
        if (size != null) o.put("size", size)
        return o.toString()
    }

    companion object {
        /** 兼容 camelCase（官方服务器）与 PascalCase（SyncHub 直接写入的文件 / 旧版）。 */
        fun parse(json: String): ClipProfile {
            val o = JSONObject(json)
            fun s(name: String): String? {
                val keys = listOf(name, name.replaceFirstChar { it.uppercase() })
                for (k in keys) if (o.has(k) && !o.isNull(k)) return o.optString(k)
                return null
            }
            fun b(name: String): Boolean {
                for (k in listOf(name, name.replaceFirstChar { it.uppercase() }))
                    if (o.has(k) && !o.isNull(k)) return o.optBoolean(k)
                return false
            }
            fun l(name: String): Long? {
                for (k in listOf(name, name.replaceFirstChar { it.uppercase() }))
                    if (o.has(k) && !o.isNull(k)) return o.optLong(k)
                return null
            }
            // 旧版协议 (v2) 字段 Clipboard / File 作为后备
            val text = s("text") ?: s("clipboard") ?: ""
            val dataName = s("dataName") ?: s("file")?.takeIf { it.isNotEmpty() }
            return ClipProfile(
                type = s("type") ?: "Text",
                hash = s("hash") ?: "",
                text = text,
                hasData = b("hasData") || (dataName != null && (s("type") ?: "Text") != "Text"),
                dataName = dataName,
                transferDataHash = s("transferDataHash"),
                size = l("size"),
            )
        }
    }
}

/** /api/hub/items 与 /api/hub/auto-pull 返回的条目。 */
data class HubItem(
    val id: Long,
    val type: Int,             // 0 Text, 1 File, 2 Image, 3 Group
    val text: String,
    val filename: String,
    val size: Long,
    val hash: String,
    val createTimeLocal: String,
    val starred: Boolean,
    val pinned: Boolean,
    val remainingSeconds: Long?,
    val fromDevice: String,
    val category: String,
    val hasFile: Boolean,
    val downloadUrl: String?,
) {
    val isText get() = type == 0

    companion object {
        fun fromJson(o: JSONObject) = HubItem(
            id = o.optLong("id"),
            type = o.optInt("type"),
            text = o.optString("text", ""),
            filename = o.optString("filename", ""),
            size = o.optLong("size", 0),
            hash = o.optString("hash", ""),
            createTimeLocal = o.optString("createTimeLocal", ""),
            starred = o.optBoolean("starred"),
            pinned = o.optBoolean("pinned"),
            remainingSeconds = if (o.isNull("remainingSeconds")) null else o.optLong("remainingSeconds"),
            fromDevice = o.optString("fromDevice", ""),
            category = o.optString("category", ""),
            hasFile = o.optBoolean("hasFile"),
            downloadUrl = if (o.isNull("downloadUrl")) null else o.optString("downloadUrl").ifEmpty { null },
        )
    }
}

data class AutoPullResult(val latestId: Long, val items: List<HubItem>)

class ApiException(val code: Int, message: String) : Exception(message)
