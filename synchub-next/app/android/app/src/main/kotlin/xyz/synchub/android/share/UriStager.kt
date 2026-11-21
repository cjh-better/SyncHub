package xyz.synchub.android.share

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import xyz.synchub.android.util.L
import java.io.File

/**
 * 将外部分享或剪贴板中的 `content://` / `file://` URI 暂存到本应用私有缓存目录
 * `cacheDir/share/<ts>_<idx>/<displayName>`，确保原 Activity 关闭释放临时 URI 授权后，
 * Dart 引擎的后台发送协程仍可安全读取文件内容与元数据。
 */
object UriStager {
    private const val STALE_MS = 24 * 60 * 60 * 1000L

    fun sanitizeFileName(raw: String): String {
        val cleaned = raw
            .replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001F]"), "_")
            .trim()
            .trim('.')
        return when {
            cleaned.isEmpty() || cleaned == "." || cleaned == ".." -> ""
            cleaned.length > 200 -> {
                val dot = cleaned.lastIndexOf('.')
                if (dot > 0 && cleaned.length - dot <= 16) {
                    cleaned.substring(0, 180) + cleaned.substring(dot)
                } else {
                    cleaned.take(200)
                }
            }
            else -> cleaned
        }
    }

    fun resolveDisplayName(ctx: Context, uri: Uri, fallbackBase: String): String {
        var name: String? = null
        if (uri.scheme == "content") {
            runCatching {
                ctx.contentResolver.query(
                    uri,
                    arrayOf(OpenableColumns.DISPLAY_NAME),
                    null,
                    null,
                    null,
                )?.use { c ->
                    if (c.moveToFirst() && !c.isNull(0)) {
                        name = c.getString(0)
                    }
                }
            }
        }
        if (name.isNullOrBlank()) {
            name = uri.lastPathSegment?.substringAfterLast('/')
        }
        var safe = sanitizeFileName(name.orEmpty()).ifEmpty { fallbackBase }
        if (!safe.contains('.')) {
            val mime = runCatching { ctx.contentResolver.getType(uri) }.getOrNull()
            val ext = mime?.let { MimeTypeMap.getSingleton().getExtensionFromMimeType(it) }
            if (!ext.isNullOrBlank()) {
                safe = "$safe.$ext"
            }
        }
        return safe
    }

    fun stageAll(ctx: Context, uris: List<Uri>): List<String> {
        pruneOldStages(ctx)
        val ts = System.currentTimeMillis()
        val shareRoot = File(ctx.cacheDir, "share").apply { mkdirs() }
        val paths = ArrayList<String>(uris.size)
        uris.forEachIndexed { idx, uri ->
            try {
                val displayName = resolveDisplayName(ctx, uri, "shared_${ts}_$idx")
                val slotDir = File(shareRoot, "${ts}_$idx").apply { mkdirs() }
                val dest = File(slotDir, displayName)
                val copied = when (uri.scheme) {
                    "file" -> {
                        val src = uri.path?.let(::File)
                        if (src != null && src.isFile) {
                            src.inputStream().use { input ->
                                dest.outputStream().use { out -> input.copyTo(out) }
                            }
                            true
                        } else {
                            false
                        }
                    }
                    else -> {
                        ctx.contentResolver.openInputStream(uri)?.use { input ->
                            dest.outputStream().use { out -> input.copyTo(out) }
                            true
                        } ?: false
                    }
                }
                if (copied && dest.isFile) {
                    paths.add(dest.absolutePath)
                }
            } catch (e: Exception) {
                L.w("暂存分享文件失败 ($uri)", e)
            }
        }
        return paths
    }

    private fun pruneOldStages(ctx: Context) {
        runCatching {
            val root = File(ctx.cacheDir, "share")
            if (!root.isDirectory) return
            val cutoff = System.currentTimeMillis() - STALE_MS
            root.listFiles()?.forEach { child ->
                if (child.lastModified() < cutoff) {
                    child.deleteRecursively()
                }
            }
        }
    }
}
