package xyz.synchub.android.util

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import android.webkit.MimeTypeMap
import android.widget.Toast
import androidx.core.content.FileProvider
import java.io.File

/**
 * 用系统应用打开 / 分享已接收的文件（FileProvider content:// + 临时读权限）。
 * APK 走系统安装器（需要“安装未知应用”授权，没有时先跳到授权页）。
 */
object FileOpener {
    enum class Result { OPENED, NO_APP, NEED_INSTALL_PERMISSION, MISSING, ERROR }

    private val extraMime = mapOf(
        "apk" to "application/vnd.android.package-archive",
        "md" to "text/markdown",
        "log" to "text/plain",
        "txt" to "text/plain",
        "csv" to "text/csv",
        "json" to "application/json",
        "xml" to "text/xml",
        "yaml" to "text/plain",
        "yml" to "text/plain",
        "py" to "text/plain",
        "kt" to "text/plain",
        "dart" to "text/plain",
        "swift" to "text/plain",
        "sh" to "text/plain",
        "pdf" to "application/pdf",
        "zip" to "application/zip",
        "7z" to "application/x-7z-compressed",
        "rar" to "application/vnd.rar",
        "gz" to "application/gzip",
        "tgz" to "application/gzip",
        "png" to "image/png",
        "jpg" to "image/jpeg",
        "jpeg" to "image/jpeg",
        "gif" to "image/gif",
        "webp" to "image/webp",
        "heic" to "image/heic",
        "heif" to "image/heif",
        "bmp" to "image/bmp",
        "mp4" to "video/mp4",
        "mov" to "video/quicktime",
        "mkv" to "video/x-matroska",
        "webm" to "video/webm",
        "mp3" to "audio/mpeg",
        "m4a" to "audio/mp4",
        "wav" to "audio/wav",
        "flac" to "audio/flac",
        "aac" to "audio/aac",
        "doc" to "application/msword",
        "docx" to "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls" to "application/vnd.ms-excel",
        "xlsx" to "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt" to "application/vnd.ms-powerpoint",
        "pptx" to "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    )

    /** 按扩展名取 MIME：先查内置表（各 ROM 的 MimeTypeMap 不全），再查系统表，最后 application/octet-stream。 */
    fun mimeOf(
        name: String,
        platform: (String) -> String? = { e ->
            runCatching { MimeTypeMap.getSingleton().getMimeTypeFromExtension(e) }.getOrNull()
        },
    ): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        if (ext.isEmpty() || ext == name.lowercase()) return "application/octet-stream"
        return extraMime[ext] ?: platform(ext) ?: "application/octet-stream"
    }

    fun isApk(name: String): Boolean = name.lowercase().endsWith(".apk")

    /** "/sdcard/…" → "/storage/emulated/0/…"（FileProvider 的 external-path 以后者为根）。 */
    fun normalize(path: String): File {
        val root = Environment.getExternalStorageDirectory().absolutePath
        return when {
            path.startsWith("/sdcard/") -> File(root, path.removePrefix("/sdcard/"))
            path == "/sdcard" -> File(root)
            else -> File(path)
        }
    }

    /** 接收文件夹：优先使用配置目录，否则默认 /storage/emulated/0/Download/<子目录>。 */
    fun receiveDir(ctx: Context): File {
        val prefs = NativePrefs.get(ctx)
        if (prefs.recvDir.isNotEmpty()) return normalize(prefs.recvDir)
        val base = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        val sub = prefs.saveSubdir
        return if (sub.isEmpty()) base else File(base, sub)
    }

    /** 在接收文件夹里找这个条目的本地副本：同名，或重名时生成的 "名称 (n).ext"。 */
    fun findLocal(dir: File, name: String, size: Long = 0L): File? {
        if (name.isEmpty()) return null
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        for (i in 0..20) {
            val f = File(dir, if (i == 0) name else "$base ($i)$ext")
            if (f.isFile && (size <= 0 || f.length() == size)) return f
        }
        return null
    }

    fun uriFor(ctx: Context, f: File): Uri =
        FileProvider.getUriForFile(ctx, ctx.packageName + ".files", f)

    fun viewIntent(ctx: Context, f: File, mime: String = mimeOf(f.name)): Intent =
        Intent(Intent.ACTION_VIEW)
            .setDataAndType(uriFor(ctx, f), mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)

    fun canInstallApks(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < 26 || ctx.packageManager.canRequestPackageInstalls()

    /** 打开文件；所有失败都给出提示。建议在主线程调用。 */
    fun open(ctx: Context, f: File): Result {
        if (!f.isFile) {
            toast(ctx, "文件不存在：${f.name}")
            return Result.MISSING
        }
        if (!f.canRead()) {
            toast(ctx, "没有读取权限：请在设置里允许 SyncHub“所有文件访问”")
            return Result.MISSING
        }
        if (isApk(f.name) && !canInstallApks(ctx)) {
            toast(ctx, "请允许 SyncHub“安装未知应用”，返回后再点一次即可安装", long = true)
            runCatching {
                ctx.startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:" + ctx.packageName),
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            }
            return Result.NEED_INSTALL_PERMISSION
        }
        return try {
            val mime = mimeOf(f.name)
            val exact = viewIntent(ctx, f, mime)
            if (mime != "application/octet-stream" && exact.resolveActivity(ctx.packageManager) != null) {
                ctx.startActivity(exact)
                Result.OPENED
            } else {
                val any = viewIntent(ctx, f, "*/*")
                if (any.resolveActivity(ctx.packageManager) == null) {
                    toast(ctx, "没有可以打开此文件的应用")
                    Result.NO_APP
                } else {
                    ctx.startActivity(
                        Intent.createChooser(any, "打开方式").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    Result.OPENED
                }
            }
        } catch (_: ActivityNotFoundException) {
            toast(ctx, "没有可以打开此文件的应用")
            Result.NO_APP
        } catch (e: Exception) {
            L.w("打开文件失败：${f.name}", e)
            toast(ctx, "无法打开：${e.message ?: e.javaClass.simpleName}")
            Result.ERROR
        }
    }

    fun openFolderInSystem(ctx: Context, dir: File): Boolean {
        val root = Environment.getExternalStorageDirectory().absolutePath
        val rel = dir.absolutePath.removePrefix(root).trim('/')
        val doc = DocumentsContract.buildDocumentUri(
            "com.android.externalstorage.documents",
            "primary:$rel",
        )
        val candidates = listOf(
            Intent(Intent.ACTION_VIEW).setDataAndType(doc, DocumentsContract.Document.MIME_TYPE_DIR),
            Intent(Intent.ACTION_VIEW).setDataAndType(doc, "resource/folder"),
        )
        for (i in candidates) {
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            if (i.resolveActivity(ctx.packageManager) != null && runCatching { ctx.startActivity(i) }.isSuccess) {
                return true
            }
        }
        return false
    }

    private fun toast(ctx: Context, s: String, long: Boolean = false) =
        Toast.makeText(ctx.applicationContext, s, if (long) Toast.LENGTH_LONG else Toast.LENGTH_SHORT).show()
}
