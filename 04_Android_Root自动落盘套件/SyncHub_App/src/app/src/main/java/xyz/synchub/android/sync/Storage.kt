package xyz.synchub.android.sync

import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import xyz.synchub.android.util.Prefs
import java.io.File
import java.io.OutputStream

object Storage {
    /** 能否直接写 /sdcard/Download（Android 11+ 需“所有文件访问”，Android 10 需 WRITE_EXTERNAL_STORAGE + legacy）。 */
    fun canWriteDirect(ctx: Context): Boolean =
        if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager()
        else ctx.checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

    fun sink(ctx: Context): FileSink {
        val sub = Prefs.get(ctx).saveSubdir
        return if (canWriteDirect(ctx)) {
            val base = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            ScanningSink(ctx, DirectFileSink(if (sub.isEmpty()) base else File(base, sub)))
        } else MediaStoreSink(ctx, sub)
    }

    private class ScanningSink(private val ctx: Context, private val inner: DirectFileSink) : FileSink by inner {
        override fun begin(name: String): PendingFile {
            val pf = inner.begin(name)
            return object : PendingFile by pf {
                override fun commit(): String {
                    val path = pf.commit()
                    MediaScannerConnection.scanFile(ctx, arrayOf(path), null, null)
                    return path
                }
            }
        }
    }

    /** 无文件权限时的后备：MediaStore.Downloads（Android 10+，无需权限，只能看到本应用写入的文件）。 */
    private class MediaStoreSink(private val ctx: Context, private val sub: String) : FileSink {
        private val rel = Environment.DIRECTORY_DOWNLOADS + "/" + (if (sub.isEmpty()) "" else "$sub/")
        override val displayDir get() = "/sdcard/$rel"
        private val coll: Uri = MediaStore.Downloads.EXTERNAL_CONTENT_URI

        private fun query(name: String): Long? {
            ctx.contentResolver.query(coll, arrayOf(MediaStore.MediaColumns.SIZE),
                "${MediaStore.MediaColumns.RELATIVE_PATH}=? AND ${MediaStore.MediaColumns.DISPLAY_NAME}=?",
                arrayOf(rel, name), null)?.use { c -> if (c.moveToFirst()) return c.getLong(0) }
            return null
        }
        override fun existsWithSize(name: String, size: Long) = size > 0 && query(name) == size
        override fun exists(name: String) = query(name) != null
        override fun begin(name: String): PendingFile {
            val ext = name.substringAfterLast('.', "").lowercase()
            val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
            val cv = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, rel)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = ctx.contentResolver.insert(coll, cv) ?: throw IllegalStateException("MediaStore insert 失败")
            val os = ctx.contentResolver.openOutputStream(uri) ?: throw IllegalStateException("无法写入 $uri")
            return object : PendingFile {
                override val out: OutputStream = os
                override fun commit(): String {
                    os.close()
                    ctx.contentResolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
                    return "/sdcard/$rel$name"
                }
                override fun abort() { runCatching { os.close() }; ctx.contentResolver.delete(uri, null, null) }
            }
        }
    }
}
