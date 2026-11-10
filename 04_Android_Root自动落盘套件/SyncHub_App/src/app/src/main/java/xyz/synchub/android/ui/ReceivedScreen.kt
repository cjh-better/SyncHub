package xyz.synchub.android.ui

import android.widget.Toast
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import xyz.synchub.android.sync.Storage
import xyz.synchub.android.sync.TransferNotifier
import xyz.synchub.android.util.FileOpener
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** “已接收文件”：接收文件夹里的文件，点一下用系统应用打开，长按可分享。 */
@Composable
fun ReceivedScreen(act: MainActivity, onBack: () -> Unit) {
    val dir = remember { FileOpener.receiveDir(act) }
    var files by remember { mutableStateOf<List<File>?>(null) }
    var tick by remember { mutableStateOf(0) }
    LaunchedEffect(tick) { files = withContext(Dispatchers.IO) { FileOpener.listReceived(dir) } }
    // 从查看器 / 安装器返回时刷新
    val owner = LocalLifecycleOwner.current
    androidx.compose.runtime.DisposableEffect(owner) {
        val obs = androidx.lifecycle.LifecycleEventObserver { _, e -> if (e == androidx.lifecycle.Lifecycle.Event.ON_RESUME) tick++ }
        owner.lifecycle.addObserver(obs)
        onDispose { owner.lifecycle.removeObserver(obs) }
    }
    ReceivedContent(
        dirPath = dir.absolutePath, files = files, allFilesAccess = remember { Storage.canWriteDirect(act) },
        onBack = onBack,
        onOpen = { FileOpener.open(act, it) },
        onShare = { FileOpener.share(act, it) },
        onSystemFiles = {
            if (!FileOpener.openFolderInSystem(act, dir))
                Toast.makeText(act, "系统文件管理不支持直接打开这个文件夹，请在下面的列表中操作", Toast.LENGTH_LONG).show()
        },
    )
}

/** 无状态界面（便于截图测试）。files == null 表示读取中。 */
@Composable
fun ReceivedContent(
    dirPath: String, files: List<File>?, allFilesAccess: Boolean,
    onBack: () -> Unit, onOpen: (File) -> Unit, onShare: (File) -> Unit, onSystemFiles: () -> Unit,
    now: Long = System.currentTimeMillis(),
) {
    Column(Modifier.fillMaxSize().background(Mac.Bg).systemBarsPadding()) {
        TopBar("已接收文件", left = { LinkButton("‹ 返回") { onBack() } }, right = { LinkButton("文件管理") { onSystemFiles() } })
        LazyColumn(Modifier.fillMaxSize()) {
            item {
                Text(dirPath.replace("/storage/emulated/0", "手机存储"), color = Mac.Text2, fontSize = 12.sp,
                    modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 4.dp, bottom = 8.dp))
                if (!allFilesAccess) Text("未授予“所有文件访问”，这里只列出 SyncHub 自己保存的文件。",
                    color = Mac.Text3, fontSize = 12.sp, modifier = Modifier.padding(start = 20.dp, end = 20.dp, bottom = 8.dp))
            }
            when {
                files == null -> item { Text("读取中…", color = Mac.Text2, fontSize = 14.sp, modifier = Modifier.padding(20.dp)) }
                files.isEmpty() -> item {
                    MacCard(Modifier.padding(horizontal = 16.dp)) {
                        Text("还没有接收到文件。电脑或 Mac 发送的文件会自动保存到这里。", color = Mac.Text2, fontSize = 14.sp,
                            modifier = Modifier.padding(16.dp))
                    }
                }
                else -> itemsIndexed(files, key = { _, f -> f.absolutePath }) { i, f ->
                    val r = 12.dp
                    val shape = RoundedCornerShape(
                        topStart = if (i == 0) r else 0.dp, topEnd = if (i == 0) r else 0.dp,
                        bottomStart = if (i == files.lastIndex) r else 0.dp, bottomEnd = if (i == files.lastIndex) r else 0.dp)
                    Column(Modifier.padding(horizontal = 16.dp).background(Mac.Card, shape)) {
                        if (i > 0) Hairline(12)
                        FileRow(f, now, onOpen = { onOpen(f) }, onShare = { onShare(f) })
                    }
                }
            }
            item { Spacer(Modifier.height(32.dp)) }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun FileRow(f: File, now: Long, onOpen: () -> Unit, onShare: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.fillMaxWidth().combinedClickable(onClick = onOpen, onLongClick = { menu = true })
            .padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(f.name, color = Mac.Text, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                val ext = f.name.substringAfterLast('.', "").take(5).uppercase()
                val meta = buildString {
                    if (ext.isNotEmpty() && ext != f.name.uppercase()) append(ext).append(" · ")
                    append(TransferNotifier.fmt(f.length())).append(" · ").append(fmtTime(f.lastModified(), now))
                }
                Text(meta, color = Mac.Text2, fontSize = 12.sp, maxLines = 1)
            }
            Text(if (FileOpener.isApk(f.name)) "安装" else "打开", color = Mac.Accent, fontSize = 13.sp)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text(if (FileOpener.isApk(f.name)) "安装" else "打开") }, onClick = { menu = false; onOpen() })
            DropdownMenuItem(text = { Text("分享") }, onClick = { menu = false; onShare() })
        }
    }
}

internal fun fmtTime(t: Long, now: Long): String {
    val sameYear = SimpleDateFormat("yyyy", Locale.US).let { it.format(Date(t)) == it.format(Date(now)) }
    return SimpleDateFormat(if (sameYear) "MM-dd HH:mm" else "yyyy-MM-dd", Locale.US).format(Date(t))
}
