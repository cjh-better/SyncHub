package xyz.synchub.android.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import xyz.synchub.android.net.HubClient
import xyz.synchub.android.net.HubItem
import xyz.synchub.android.net.HubStorage
import xyz.synchub.android.net.hubOrder
import xyz.synchub.android.root.RootShell
import xyz.synchub.android.sync.Storage
import xyz.synchub.android.sync.SyncService
import xyz.synchub.android.sync.TransferNotifier
import xyz.synchub.android.sync.TransferService
import xyz.synchub.android.util.ClipMode
import xyz.synchub.android.util.Prefs
import xyz.synchub.android.util.RuntimeStatus
import xyz.synchub.android.util.Status
import xyz.synchub.android.xposed.ModuleStatus

/** 与电脑端一样的单页状态：已连接 / 同步中 / 自动接收，下面是最近条目。 */
@Composable
fun HomeScreen(act: MainActivity, onSettings: () -> Unit) {
    val prefs = remember { Prefs.get(act) }
    val st by Status.flow.collectAsState()
    val scope = rememberCoroutineScope()
    var items by remember { mutableStateOf<List<HubItem>>(emptyList()) }
    var loadErr by remember { mutableStateOf<String?>(null) }
    var storage by remember { mutableStateOf<HubStorage?>(null) }
    var loading by remember { mutableStateOf(false) }
    var running by remember { mutableStateOf(prefs.serviceEnabled) }
    val module = remember { ModuleStatus.isActive() }

    fun refresh() {
        loading = true
        scope.launch {
            val r = withContext(Dispatchers.IO) { runCatching { HubClient(prefs.server()).listItems(60) } }
            r.onSuccess { items = it.hubOrder(); loadErr = null }.onFailure { loadErr = it.message }
            loading = false
            // 存储信息只是辅助显示：失败时保留上次结果，不报错
            withContext(Dispatchers.IO) { runCatching { HubClient(prefs.server()).storage() } }.onSuccess { storage = it }
        }
    }
    LaunchedEffect(Unit) { refresh() }
    LaunchedEffect(st.lastReceived, st.lastPush) { delay(800); refresh() }

    HomeContent(
        st = st, items = items, loadErr = loadErr, loading = loading, running = running, module = module,
        rootLabel = when (RootShell.cachedRoot()) { true -> "已授权"; false -> "未授权"; null -> if (prefs.rootSetupDone) "已配置" else "—" },
        rootOk = RootShell.cachedRoot() == true || prefs.rootSetupDone,
        serverUrl = prefs.serverUrl, autoReceive = prefs.autoReceive, saveDir = remember { Storage.sink(act).displayDir },
        onSettings = onSettings, onRefresh = { refresh() },
        onToggle = { if (running) { SyncService.stop(act); running = false } else { SyncService.start(act); running = true } },
        onItem = { onItemTap(act, it) },
        storage = storage,
    )
}

/** 无状态界面（便于截图测试）。 */
@Composable
fun HomeContent(
    st: RuntimeStatus, items: List<HubItem>, loadErr: String?, loading: Boolean, running: Boolean, module: Boolean,
    rootLabel: String, rootOk: Boolean, serverUrl: String, autoReceive: Boolean, saveDir: String,
    onSettings: () -> Unit, onRefresh: () -> Unit, onToggle: () -> Unit, onItem: (HubItem) -> Unit,
    storage: HubStorage? = null,
) {
    Column(Modifier.fillMaxSize().background(Mac.Bg).systemBarsPadding()) {
        TopBar("SyncHub", right = { LinkButton("设置") { onSettings() } })
        LazyColumn(Modifier.fillMaxSize()) {
            item {
                SectionTitle("状态")
                MacCard(Modifier.padding(horizontal = 16.dp)) {
                    val connColor = when (st.connected) { true -> Mac.Green; false -> Mac.Red; null -> Mac.Text3 }
                    StatusRow("服务器", when (st.connected) { true -> "已连接"; false -> "连接失败"; null -> "—" },
                        connColor, sub = st.lastError ?: serverUrl)
                    Hairline(36)
                    val clipOk = running && st.clipMode != ClipMode.OFF
                    StatusRow("剪贴板同步", if (!running) "未运行" else st.clipMode.label,
                        when {
                            !clipOk -> Mac.Text3
                            st.clipMode == ClipMode.FOREGROUND -> Mac.Orange
                            st.clipMode == ClipMode.ROOT && !st.rootHelperAlive -> Mac.Orange
                            st.clipMode == ClipMode.LSPOSED && st.systemHookVerified == false -> Mac.Orange
                            else -> Mac.Green
                        },
                        sub = buildString {
                            st.lastPush?.let { append("↑ ").append(it) }
                            st.lastPull?.let { if (isNotEmpty()) append("\n"); append("↓ ").append(it) }
                            if (isEmpty()) append(when (st.clipMode) {
                                ClipMode.FOREGROUND -> "后台读取需 Root 或 LSPosed 模块；当前仅在打开应用时上传"
                                ClipMode.ROOT -> (if (st.rootHelperAlive) "Root 剪贴板进程运行中" else "Root 剪贴板进程启动中…") +
                                    (if (st.systemHookVerified == false) "（LSPosed 系统钩子未生效，已自动改用 Root；重启手机后可切回）" else "")
                                ClipMode.LSPOSED -> if (st.systemHookVerified == false) "系统框架钩子未生效，请确认作用域含“系统框架”并重启" else "后台读取已放开"
                                ClipMode.OFF -> "已关闭"
                            })
                        })
                    Hairline(36)
                    StatusRow("自动接收", if (autoReceive && running) "已开启" else "已关闭",
                        if (autoReceive && running) Mac.Green else Mac.Text3,
                        sub = if (autoReceive) (st.lastReceived?.let { "最近：$it" } ?: saveDir) else null)
                    Hairline(36)
                    StatusRow("LSPosed 模块", if (module) "已激活" else "未激活", if (module) Mac.Green else Mac.Text3,
                        sub = if (module) null else "可选；启用后剪贴板读取更稳定，且不显示读取提示")
                    Hairline(36)
                    StatusRow("Root", rootLabel, if (rootOk) Mac.Green else Mac.Text3)
                    st.transfers.values.forEach { t -> Hairline(36); StatusRow(t, "", Mac.Accent) }
                }
                Spacer(Modifier.height(12.dp))
                Box(Modifier.padding(horizontal = 16.dp)) {
                    if (running) LinkButton("停止同步", color = Mac.Red) { onToggle() }
                    else PrimaryButton("开始同步") { onToggle() }
                }
                if (storage != null) {
                    SectionTitle("存储空间")
                    MacCard(Modifier.padding(horizontal = 16.dp)) { StorageBlock(storage) }
                }
                Row(Modifier.fillMaxWidth().padding(end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    SectionTitle("最近条目")
                    Spacer(Modifier.weight(1f))
                    LinkButton(if (loading) "刷新中…" else "刷新") { onRefresh() }
                }
            }
            if (loadErr != null) item {
                Text("加载失败：$loadErr", color = Mac.Red, fontSize = 13.sp, modifier = Modifier.padding(16.dp))
            }
            itemsIndexed(items, key = { _, it -> it.id }) { i, it ->
                val r = 12.dp
                val shape = RoundedCornerShape(
                    topStart = if (i == 0) r else 0.dp, topEnd = if (i == 0) r else 0.dp,
                    bottomStart = if (i == items.lastIndex) r else 0.dp, bottomEnd = if (i == items.lastIndex) r else 0.dp)
                Column(Modifier.padding(horizontal = 16.dp).background(Mac.Card, shape)) {
                    if (i > 0) Hairline(12)
                    ItemRow(it) { onItem(it) }
                }
            }
            item { Spacer(Modifier.height(32.dp)) }
        }
    }
}

private fun onItemTap(act: MainActivity, it: HubItem) {
    if (it.isText) {
        act.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("SyncHub", it.text))
        Toast.makeText(act, "已复制", Toast.LENGTH_SHORT).show()
    } else if (it.downloadUrl != null && it.hasFile) {
        TransferService.download(act, it)
        Toast.makeText(act, "开始下载 ${it.filename}", Toast.LENGTH_SHORT).show()
    } else Toast.makeText(act, "文件已不在服务器上", Toast.LENGTH_SHORT).show()
}

@Composable
private fun ItemRow(it: HubItem, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        // 不再显示类型图标（与网页端一致）；文件类型以扩展名文字放在说明行里
        Column(Modifier.weight(1f)) {
            Text(if (it.isText) it.text.replace('\n', ' ') else it.filename, color = Mac.Text, fontSize = 15.sp,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            val meta = buildString {
                val ext = if (it.isText) "" else it.filename.substringAfterLast('.', "").take(5).uppercase()
                if (ext.isNotEmpty()) append(ext).append(" · ")
                append(it.fromDevice)
                append(" · ").append(it.createTimeLocal.drop(5).dropLast(3))
                if (!it.isText) append(" · ").append(TransferNotifier.fmt(it.size))
                if (it.pinned) append(" · 置顶")
                if (it.starred) append(" · ★ 收藏")
            }
            Text(meta, color = Mac.Text2, fontSize = 12.sp, maxLines = 1)
        }
        Text(if (it.isText) "复制" else "下载", color = Mac.Accent, fontSize = 13.sp)
    }
}

/** 极简存储条：细进度条 + 已用 / 共 / 剩余 + SyncHub 占用。 */
@Composable
fun StorageBlock(s: HubStorage) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp)) {
        val pct = s.usedFraction
        val barColor = when { pct >= 0.95f -> Mac.Red; pct >= 0.85f -> Mac.Orange; else -> Mac.Accent }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("已用 ${HubStorage.fmt(s.used)} / 共 ${HubStorage.fmt(s.total)}", color = Mac.Text, fontSize = 14.sp, modifier = Modifier.weight(1f))
            Text("${(pct * 100).toInt()}%", color = Mac.Text2, fontSize = 13.sp)
        }
        Spacer(Modifier.height(8.dp))
        Row(Modifier.fillMaxWidth().height(4.dp).background(Mac.Fill, RoundedCornerShape(2.dp))) {
            if (s.hubFraction > 0f) Box(Modifier.fillMaxWidth(s.hubFraction).height(4.dp).background(Color(0xFF5AC8FA), RoundedCornerShape(2.dp)))
            val rest = if (s.hubFraction < 1f) ((pct - s.hubFraction) / (1f - s.hubFraction)).coerceIn(0f, 1f) else 0f
            if (rest > 0f) Box(Modifier.fillMaxWidth(rest).height(4.dp).background(barColor, RoundedCornerShape(2.dp)))
        }
        Spacer(Modifier.height(8.dp))
        val sub = "剩余 ${HubStorage.fmt(s.free)}" + (s.hubBytes?.let { " · SyncHub 占用 ${HubStorage.fmt(it)}" } ?: "")
        Text(sub, color = Mac.Text2, fontSize = 12.sp)
    }
}
