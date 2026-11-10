package xyz.synchub.android.ui

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import xyz.synchub.android.net.HubClient
import xyz.synchub.android.net.HubItem
import xyz.synchub.android.sync.AutoReceiver
import xyz.synchub.android.sync.Storage
import xyz.synchub.android.sync.TransferNotifier
import xyz.synchub.android.sync.TransferService
import xyz.synchub.android.util.FileOpener
import xyz.synchub.android.util.L
import xyz.synchub.android.util.Prefs
import java.io.File

/**
 * 打开一个文件（通知点击、首页条目点击都走这里）。
 * 这是一个 Activity，所以从通知 PendingIntent.getActivity 直接启动，再由它启动查看器——
 * 不经过 BroadcastReceiver / Service，不受 Android 12+ “通知跳板”限制；任何失败都有提示。
 * 本机已有 → 直接打开；没有 → 带登录信息下载到接收文件夹（显示进度）后打开。
 */
class OpenFileActivity : ComponentActivity() {
    private var progress by mutableStateOf(0f)
    private var progressText by mutableStateOf("")
    private var title by mutableStateOf("")
    @Volatile private var cancelled = false
    private var downloading = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (!downloading) handle(intent)
    }

    private fun handle(i: Intent) {
        val path = i.getStringExtra(EXTRA_PATH)
        val name = i.getStringExtra(EXTRA_NAME) ?: path?.let { File(it).name } ?: ""
        val size = i.getLongExtra(EXTRA_SIZE, 0)
        // 1. 通知里带的路径
        path?.let { FileOpener.normalize(it) }?.takeIf { it.isFile }?.let { FileOpener.open(this, it); finish(); return }
        // 2. 接收文件夹里已有的同名同大小文件
        FileOpener.findLocal(FileOpener.receiveDir(this), AutoReceiver.sanitize(name), size)?.let {
            FileOpener.open(this, it); finish(); return
        }
        // 3. 从服务器下载后打开
        val url = i.getStringExtra(EXTRA_URL)
        if (url.isNullOrEmpty()) {
            android.widget.Toast.makeText(this, "本机没有这个文件，服务器上也已不存在", android.widget.Toast.LENGTH_SHORT).show()
            finish(); return
        }
        val item = HubItem(i.getLongExtra(EXTRA_ID, 0), i.getIntExtra(EXTRA_TYPE, 1), "", name, size, "", "", false, false,
            null, "", "", true, url)
        download(item)
    }

    private fun download(item: HubItem) {
        downloading = true
        title = item.filename
        progressText = "准备下载…"
        setContent { SyncHubTheme { DownloadCard(title, progress, progressText,
            onCancel = { cancelled = true; finish() },
            onBackground = { cancelled = true; TransferService.download(this, item); finish() }) } }
        val prefs = Prefs.get(this)
        lifecycleScope.launch {
            val r = withContext(Dispatchers.IO) {
                runCatching {
                    val sink = Storage.sink(this@OpenFileActivity)
                    val n0 = AutoReceiver.sanitize(item.filename.ifEmpty { "file_${item.id}" })
                    val n = if (sink.exists(n0)) AutoReceiver.uniqueName(sink, n0) else n0
                    val pf = sink.begin(n)
                    try {
                        HubClient(prefs.server()).download(item, pf.out) { got, total ->
                            if (cancelled) throw java.io.InterruptedIOException("已取消")
                            runOnUiThread {
                                progress = if (total > 0) (got.toFloat() / total).coerceIn(0f, 1f) else 0f
                                progressText = "${TransferNotifier.fmt(got)} / ${TransferNotifier.fmt(total)}"
                            }
                        }
                        pf.commit()
                    } catch (e: Throwable) { pf.abort(); throw e }
                }
            }
            if (cancelled) return@launch
            r.onSuccess { p ->
                L.i("已下载并打开 ${item.filename} → $p")
                FileOpener.open(this@OpenFileActivity, FileOpener.normalize(p))
            }.onFailure { e ->
                L.w("下载失败：${item.filename}", e)
                android.widget.Toast.makeText(this@OpenFileActivity, "下载失败：${e.message ?: e.javaClass.simpleName}",
                    android.widget.Toast.LENGTH_LONG).show()
            }
            finish()
        }
    }

    override fun onDestroy() {
        if (isFinishing) cancelled = true
        super.onDestroy()
    }

    companion object {
        const val EXTRA_PATH = "path"
        const val EXTRA_NAME = "name"
        const val EXTRA_SIZE = "size"
        const val EXTRA_ID = "id"
        const val EXTRA_URL = "url"
        const val EXTRA_TYPE = "type"

        /** 打开本机文件（通知用）。 */
        fun forPath(ctx: Context, path: String, name: String? = null): Intent =
            Intent(ctx, OpenFileActivity::class.java).putExtra(EXTRA_PATH, path)
                .putExtra(EXTRA_NAME, name ?: File(path).name)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        /** 打开云端条目：本机有就直接打开，没有就先下载。 */
        fun forItem(ctx: Context, it: HubItem): Intent =
            Intent(ctx, OpenFileActivity::class.java).putExtra(EXTRA_NAME, it.filename).putExtra(EXTRA_SIZE, it.size)
                .putExtra(EXTRA_ID, it.id).putExtra(EXTRA_TYPE, it.type).putExtra(EXTRA_URL, it.downloadUrl)
    }
}

/** 半透明背景上的小卡片：文件名、细进度条、已下载 / 总大小。 */
@Composable
fun DownloadCard(name: String, progress: Float, text: String, onCancel: () -> Unit, onBackground: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Color(0x33000000)), contentAlignment = Alignment.Center) {
        Column(Modifier.padding(horizontal = 40.dp).fillMaxWidth().background(Mac.Card, RoundedCornerShape(14.dp))
            .padding(start = 18.dp, end = 18.dp, top = 18.dp, bottom = 6.dp)) {
            Text("正在下载", color = Mac.Text2, fontSize = 12.sp)
            Spacer(Modifier.height(4.dp))
            Text(name, color = Mac.Text, fontSize = 15.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.height(12.dp))
            Row(Modifier.fillMaxWidth().height(4.dp).background(Mac.Fill, RoundedCornerShape(2.dp))) {
                if (progress > 0f) Box(Modifier.fillMaxWidth(progress).height(4.dp).background(Mac.Accent, RoundedCornerShape(2.dp)))
            }
            Spacer(Modifier.height(8.dp))
            Text(text + if (progress > 0f) " · ${(progress * 100).toInt()}%" else "", color = Mac.Text2, fontSize = 12.sp)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                LinkButton("后台下载") { onBackground() }
                LinkButton("取消", color = Mac.Red) { onCancel() }
            }
        }
    }
}
