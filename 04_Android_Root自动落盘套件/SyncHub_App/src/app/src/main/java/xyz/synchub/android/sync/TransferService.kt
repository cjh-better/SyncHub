package xyz.synchub.android.sync

import android.app.Service
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.OpenableColumns
import android.widget.Toast
import xyz.synchub.android.net.HubClient
import xyz.synchub.android.net.HubItem
import xyz.synchub.android.net.SyncClipboardClient
import xyz.synchub.android.util.L
import xyz.synchub.android.util.Prefs
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * 系统菜单发送 / 手动下载用的短时前台服务（dataSync）。任务串行执行，队列清空后自动停止。
 */
class TransferService : Service() {
    private val exec = Executors.newSingleThreadExecutor()
    private val pending = AtomicInteger(0)
    private val main = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n = Notifs.builder(this, Notifs.CH_TRANSFER).setContentTitle("SyncHub 正在传输…")
            .setSilent(true).setOngoing(true).build()
        startForeground(2, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        if (intent == null) { maybeStop(); return START_NOT_STICKY }
        pending.incrementAndGet()
        exec.execute {
            try { handle(intent) } catch (e: Exception) { L.w("传输任务失败", e) }
            finally { if (pending.decrementAndGet() == 0) main.post { maybeStop() } }
        }
        return START_NOT_STICKY
    }

    private fun maybeStop() { if (pending.get() == 0) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() } }

    override fun onDestroy() { exec.shutdown(); super.onDestroy() }

    private fun handle(i: Intent) {
        val prefs = Prefs.get(this)
        when (i.action) {
            ACTION_UPLOAD -> {
                val uris = ArrayList<Uri>()
                i.clipData?.let { cd -> for (k in 0 until cd.itemCount) cd.getItemAt(k).uri?.let(uris::add) }
                for (u in uris) uploadOne(prefs, u)
            }
            ACTION_TEXT -> sendText(prefs, i.getStringExtra(EXTRA_TEXT) ?: return)
            ACTION_DOWNLOAD -> {
                val item = HubItem(i.getLongExtra("id", 0), i.getIntExtra("type", 1), "", i.getStringExtra("filename") ?: "file",
                    i.getLongExtra("size", 0), "", "", false, false, null, "", "", true, i.getStringExtra("url"))
                download(prefs, item)
            }
        }
    }

    private fun uploadOne(prefs: Prefs, uri: Uri) {
        var name = "upload_${System.currentTimeMillis()}"
        var size = -1L
        runCatching {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    c.getString(0)?.let { name = it }
                    if (!c.isNull(1)) size = c.getLong(1)
                }
            }
        }
        if (!name.contains('.')) {
            contentResolver.getType(uri)?.let { t ->
                android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(t)?.let { name += ".$it" }
            }
        }
        if (size < 0) size = runCatching { contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length } }.getOrNull() ?: -1
        val key = "up-$uri"
        try {
            if (size < 0) throw IllegalStateException("无法获取文件大小")
            TransferNotifier.progress(this, key, "发送 $name", 0, size)
            HubClient(prefs.server()).upload(name, size, prefs.deviceName, { contentResolver.openInputStream(uri)!! }) { s, t ->
                TransferNotifier.progress(this, key, "发送 $name", s, t)
            }
            TransferNotifier.done(this, key, "✅ 已发送 $name", "${TransferNotifier.fmt(size)} · 电脑端将自动接收")
            L.i("已上传 $name ($size B)")
        } catch (e: Exception) {
            TransferNotifier.failed(this, key, "发送失败：$name", e.message ?: e.toString())
            L.w("上传失败 $name", e)
        }
    }

    /**
     * 文本：优先走 SyncClipboard 协议（同时写入服务器历史 = SyncHub 列表，并同步到电脑剪贴板）；
     * 失败时退回 /api/hub/text。
     */
    private fun sendText(prefs: Prefs, text: String) {
        try {
            val hash = SyncClipboardClient(prefs.server()).pushText(text)
            prefs.lastRemoteKey = hash
            toast("已发送到 SyncHub（电脑剪贴板已同步）")
        } catch (e: Exception) {
            L.w("SyncClipboard 推送失败，改用 /api/hub/text", e)
            try {
                HubClient(prefs.server()).postText(text, prefs.deviceName, syncClipboard = false)
                toast("已发送到 SyncHub")
            } catch (e2: Exception) {
                toast("发送失败：${e2.message}")
            }
        }
    }

    private fun download(prefs: Prefs, item: HubItem) {
        val key = "dl-${item.id}"
        val sink = Storage.sink(this)
        val name0 = AutoReceiver.sanitize(item.filename)
        val name = if (sink.exists(name0)) AutoReceiver.uniqueName(sink, name0) else name0
        val pf = sink.begin(name)
        try {
            HubClient(prefs.server()).download(item, pf.out) { g, t -> TransferNotifier.progress(this, key, "下载 $name", g, t) }
            val path = pf.commit()
            TransferNotifier.done(this, key, "📥 已下载 $name", "已保存到 $path", path)
        } catch (e: Exception) {
            pf.abort()
            TransferNotifier.failed(this, key, "下载失败：$name", e.message ?: e.toString())
        }
    }

    private fun toast(s: String) = main.post { Toast.makeText(applicationContext, s, Toast.LENGTH_SHORT).show() }

    companion object {
        const val ACTION_UPLOAD = "xyz.synchub.android.UPLOAD"
        const val ACTION_TEXT = "xyz.synchub.android.SEND_TEXT"
        const val ACTION_DOWNLOAD = "xyz.synchub.android.DOWNLOAD"
        const val EXTRA_TEXT = "text"

        fun upload(ctx: Context, uris: List<Uri>) {
            if (uris.isEmpty()) return
            val cd = ClipData.newRawUri("files", uris[0])
            for (k in 1 until uris.size) cd.addItem(ClipData.Item(uris[k]))
            val i = Intent(ctx, TransferService::class.java).setAction(ACTION_UPLOAD)
            i.clipData = cd
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            ctx.startForegroundService(i)
        }

        fun sendText(ctx: Context, text: String) =
            ctx.startForegroundService(Intent(ctx, TransferService::class.java).setAction(ACTION_TEXT).putExtra(EXTRA_TEXT, text))

        fun download(ctx: Context, item: HubItem) =
            ctx.startForegroundService(Intent(ctx, TransferService::class.java).setAction(ACTION_DOWNLOAD)
                .putExtra("id", item.id).putExtra("type", item.type).putExtra("filename", item.filename)
                .putExtra("size", item.size).putExtra("url", item.downloadUrl))
    }
}
