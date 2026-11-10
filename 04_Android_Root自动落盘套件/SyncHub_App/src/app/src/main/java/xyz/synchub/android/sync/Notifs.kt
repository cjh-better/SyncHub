package xyz.synchub.android.sync

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import xyz.synchub.android.R
import xyz.synchub.android.ui.MainActivity

object Notifs {
    const val CH_SYNC = "sync"
    const val CH_TRANSFER = "transfer"
    const val CH_RECEIVED = "received"
    const val ID_SYNC = 1

    fun createChannels(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannels(listOf(
            NotificationChannel(CH_SYNC, "后台同步", NotificationManager.IMPORTANCE_MIN).apply {
                description = "保持剪贴板同步与自动接收运行"; setShowBadge(false)
            },
            NotificationChannel(CH_TRANSFER, "发送与下载进度", NotificationManager.IMPORTANCE_LOW),
            NotificationChannel(CH_RECEIVED, "收到文件", NotificationManager.IMPORTANCE_DEFAULT),
        ))
    }

    fun openApp(ctx: Context): PendingIntent = PendingIntent.getActivity(ctx, 0,
        Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    fun builder(ctx: Context, ch: String) = NotificationCompat.Builder(ctx, ch)
        .setSmallIcon(R.drawable.ic_stat_sync)
        .setColor(0xFF007AFF.toInt())
        .setContentIntent(openApp(ctx))

    fun notify(ctx: Context, id: Int, n: android.app.Notification) {
        try { ctx.getSystemService(NotificationManager::class.java).notify(id, n) } catch (_: SecurityException) { }
    }

    const val ID_CLIP_BLOCKED = 2

    /** 剪贴板写入被系统拦截：提示把 SyncHub 的剪贴板权限改为“始终允许”，点击打开应用详情页。 */
    fun clipBlocked(ctx: Context, oplus: Boolean) {
        val pi = PendingIntent.getActivity(ctx, 2,
            Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:" + ctx.packageName))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val text = if (oplus) "电脑复制的内容没能写入手机剪贴板。请打开 设置 → 应用 → SyncHub → 权限 → 剪贴板，改为“始终允许”。"
            else "电脑复制的内容没能写入手机剪贴板。请在系统设置里允许 SyncHub 始终访问剪贴板（包括后台）。"
        notify(ctx, ID_CLIP_BLOCKED, builder(ctx, CH_RECEIVED)
            .setContentTitle("剪贴板权限需要改为“始终允许”")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build())
    }

    fun cancelClipBlocked(ctx: Context) = runCatching { cancel(ctx, ID_CLIP_BLOCKED) }

    fun cancel(ctx: Context, id: Int) = ctx.getSystemService(NotificationManager::class.java).cancel(id)
}
