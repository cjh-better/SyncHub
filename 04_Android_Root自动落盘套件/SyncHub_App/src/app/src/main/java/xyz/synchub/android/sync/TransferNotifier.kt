package xyz.synchub.android.sync

import android.content.Context
import androidx.core.app.NotificationCompat
import xyz.synchub.android.util.Status

/** 发送 / 接收的进度通知（每个任务一个通知，id 由 key 派生）。 */
object TransferNotifier {
    internal fun idOf(key: String) = 1000 + (key.hashCode() and 0x7ffff)

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
        // 有文件 → 点通知打开该文件；否则（如发送完成）→ 打开 App
        if (path != null) b.setContentIntent(Notifs.openFile(ctx, idOf(key), path))
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

    fun fmt(b: Long): String {
        if (b <= 0) return "0 B"
        val u = arrayOf("B", "KB", "MB", "GB")
        var v = b.toDouble(); var i = 0
        while (v >= 1024 && i < u.size - 1) { v /= 1024; i++ }
        return if (i == 0) "$b B" else String.format(java.util.Locale.US, "%.1f %s", v, u[i])
    }
}
