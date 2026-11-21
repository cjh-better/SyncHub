package xyz.synchub.android.sync

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.app.NotificationCompat
import xyz.synchub.android.MainActivity
import xyz.synchub.android.R
import xyz.synchub.android.share.OpenFileActivity
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

object Notifs {
    const val CH_SYNC = "sync"
    const val CH_TRANSFER = "transfer"
    const val CH_RECEIVED = "received"
    const val ID_SYNC = 1
    const val ID_CLIP_BLOCKED = 2
    private const val RC_OPEN_APP = 100
    private val seq = AtomicInteger(2000)

    fun createChannels(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannels(
            listOf(
                NotificationChannel(CH_SYNC, "后台同步", NotificationManager.IMPORTANCE_MIN).apply {
                    description = "保持剪贴板同步与跨端文件传输运行"
                    setShowBadge(false)
                },
                NotificationChannel(CH_TRANSFER, "发送与接收进度", NotificationManager.IMPORTANCE_LOW),
                NotificationChannel(CH_RECEIVED, "收到文件", NotificationManager.IMPORTANCE_DEFAULT),
            ),
        )
    }

    /** 点击通知打开主界面。 */
    fun openApp(ctx: Context): PendingIntent = PendingIntent.getActivity(
        ctx,
        RC_OPEN_APP,
        Intent(ctx, MainActivity::class.java)
            .setAction(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP,
            ),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /** 点击通知直接进入 OpenFileActivity（避免通知跳板限制）打开已接收的文件或所在目录。 */
    fun openFile(ctx: Context, requestCode: Int, path: String): PendingIntent = PendingIntent.getActivity(
        ctx,
        requestCode,
        OpenFileActivity.forPath(ctx, path),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    fun builder(ctx: Context, ch: String): NotificationCompat.Builder =
        NotificationCompat.Builder(ctx, ch)
            .setSmallIcon(R.drawable.ic_stat_sync)
            .setColor(0xFF007AFF.toInt())
            .setContentIntent(openApp(ctx))

    fun notify(ctx: Context, id: Int, n: Notification) {
        try {
            ctx.getSystemService(NotificationManager::class.java).notify(id, n)
        } catch (_: SecurityException) { }
    }

    /** 文件接收完成通知：点击跳转到 OpenFileActivity 打开该文件。 */
    fun filesReceived(ctx: Context, paths: List<String>, title: String, from: String) {
        createChannels(ctx)
        val id = seq.incrementAndGet()
        val firstPath = paths.firstOrNull()
        val displayTitle = when {
            title.isNotBlank() -> "📥 已接收 $title"
            paths.size > 1 && firstPath != null -> "📥 已接收 ${File(firstPath).name} 等 ${paths.size} 个文件"
            firstPath != null -> "📥 已接收 ${File(firstPath).name}"
            else -> "📥 已接收文件"
        }
        val body = buildString {
            if (from.isNotBlank()) append("来自 ").append(from)
            if (firstPath != null) {
                if (isNotEmpty()) append(" · ")
                val dest = if (paths.size > 1) File(firstPath).parent ?: firstPath else firstPath
                append("已保存到 ").append(dest)
            }
        }.ifBlank { "点击打开已接收的文件" }

        val b = builder(ctx, CH_RECEIVED)
            .setContentTitle(displayTitle)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
        if (firstPath != null) {
            b.setContentIntent(openFile(ctx, id, firstPath))
        }
        notify(ctx, id, b.build())
    }

    /** 剪贴板写入被系统拦截时提示用户在设置中改为“始终允许”。 */
    fun clipBlocked(ctx: Context, oplus: Boolean) {
        val pi = PendingIntent.getActivity(
            ctx,
            ID_CLIP_BLOCKED,
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + ctx.packageName))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val text = if (oplus) {
            "电脑复制的内容没能写入手机剪贴板。请打开 设置 → 应用 → SyncHub → 权限 → 剪贴板，改为“始终允许”。"
        } else {
            "电脑复制的内容没能写入手机剪贴板。请在系统设置里允许 SyncHub 始终访问剪贴板（包括后台）。"
        }
        notify(
            ctx,
            ID_CLIP_BLOCKED,
            builder(ctx, CH_RECEIVED)
                .setContentTitle("剪贴板权限需要改为“始终允许”")
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setContentIntent(pi)
                .setAutoCancel(true)
                .build(),
        )
    }

    fun cancelClipBlocked(ctx: Context) = runCatching { cancel(ctx, ID_CLIP_BLOCKED) }

    fun cancel(ctx: Context, id: Int) =
        ctx.getSystemService(NotificationManager::class.java).cancel(id)
}
