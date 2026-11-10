package xyz.synchub.android.sync

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.core.app.NotificationCompat
import androidx.core.content.FileProvider
import xyz.synchub.android.util.Status
import java.io.File

/** 发送 / 接收的进度通知（每个任务一个通知，id 由 key 派生）。 */
object TransferNotifier {
    private fun idOf(key: String) = 1000 + (key.hashCode() and 0x7ffff)

    fun progress(ctx: Context, key: String, title: String, sent: Long, total: Long) {
        val pct = if (total > 0) (sent * 100 / total).toInt() else 0
        val n = Notifs.builder(ctx, Notifs.CH_TRANSFER)
            .setContentTitle(title)
            .setContentText("${fmt(sent)} / ${fmt(total)}")
            .setProgress(100, pct, total <= 0)
            .setOngoing(true).setOnlyAlertOnce(true).setSilent(true)
            .build()
        Notifs.notify(ctx, idOf(key), n)
        Status.update { it.copy(transfers = it.transfers + (key to "$title · $pct%")) }
    }

    fun done(ctx: Context, key: String, title: String, text: String, path: String? = null) {
        val b = Notifs.builder(ctx, Notifs.CH_RECEIVED)
            .setContentTitle(title).setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
        path?.let { openIntent(ctx, it) }?.let { b.setContentIntent(it) }
        Notifs.notify(ctx, idOf(key), b.build())
        Status.update { it.copy(transfers = it.transfers - key) }
    }

    fun failed(ctx: Context, key: String, title: String, err: String) {
        val n = Notifs.builder(ctx, Notifs.CH_RECEIVED)
            .setContentTitle(title).setContentText(err)
            .setStyle(NotificationCompat.BigTextStyle().bigText(err))
            .setAutoCancel(true).build()
        Notifs.notify(ctx, idOf(key), n)
        Status.update { it.copy(transfers = it.transfers - key) }
    }

    private fun openIntent(ctx: Context, path: String): PendingIntent? = try {
        val f = File(path)
        if (!f.isFile) null else {
            val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.files", f)
            val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(f.extension.lowercase()) ?: "*/*"
            val i = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            PendingIntent.getActivity(ctx, idOf(path), i, PendingIntent.FLAG_IMMUTABLE)
        }
    } catch (_: Exception) { null }

    fun fmt(b: Long): String {
        if (b <= 0) return "0 B"
        val u = arrayOf("B", "KB", "MB", "GB")
        var v = b.toDouble(); var i = 0
        while (v >= 1024 && i < u.size - 1) { v /= 1024; i++ }
        return if (i == 0) "$b B" else String.format(java.util.Locale.US, "%.1f %s", v, u[i])
    }
}
