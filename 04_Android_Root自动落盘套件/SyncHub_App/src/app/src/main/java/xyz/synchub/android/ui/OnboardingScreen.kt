package xyz.synchub.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import xyz.synchub.android.net.HubClient
import xyz.synchub.android.net.ServerConfig
import xyz.synchub.android.net.SyncClipboardClient
import xyz.synchub.android.root.RootSetup
import xyz.synchub.android.root.RootShell
import xyz.synchub.android.sync.SyncService
import xyz.synchub.android.util.Prefs
import xyz.synchub.android.xposed.ModuleStatus

/**
 * 首次启动：只需填一次服务器账号 → 点「连接并一键配置」→ 授予 Root。
 * 之后自动完成：通知 / 文件 / 后台 / 电池白名单 / 剪贴板权限，开启自动接收与开机自启，启动同步服务。
 */
@Composable
fun OnboardingScreen(act: MainActivity, onDone: () -> Unit) {
    val prefs = remember { Prefs.get(act) }
    val scope = rememberCoroutineScope()
    var url by remember { mutableStateOf(prefs.serverUrl) }
    var user by remember { mutableStateOf(prefs.username) }
    var pass by remember { mutableStateOf(prefs.password) }
    var hideToast by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val steps = remember { mutableStateListOf<Pair<String, Boolean?>>() }
    var oldScript by remember { mutableStateOf<RootSetup.OldScript?>(null) }
    var finished by remember { mutableStateOf(false) }

    fun log(name: String, ok: Boolean?) {
        val i = steps.indexOfFirst { it.first == name }
        if (i >= 0) steps[i] = name to ok else steps.add(name to ok)
    }

    fun finish() {
        prefs.onboarded = true
        prefs.serviceEnabled = true
        SyncService.start(act, SyncService.ACTION_RELOAD)
        finished = true
    }

    fun go() {
        error = null; busy = true; steps.clear()
        scope.launch {
            val cfg = ServerConfig(url, user, pass)
            log("连接服务器", null)
            val conn = withContext(Dispatchers.IO) {
                runCatching { SyncClipboardClient(cfg).getProfile(); HubClient(cfg).listItems(1) }
            }
            if (conn.isFailure) {
                log("连接服务器", false)
                error = "连接失败：${conn.exceptionOrNull()?.message}\n请检查地址、用户名和密码。"
                busy = false; return@launch
            }
            log("连接服务器", true)
            prefs.serverUrl = url; prefs.username = user; prefs.password = pass
            prefs.clipPush = true; prefs.clipPull = true; prefs.autoReceive = true; prefs.startOnBoot = true

            log("请求 Root 授权", null)
            val root = withContext(Dispatchers.IO) { RootShell.requestRoot() }
            log("请求 Root 授权", root)
            if (root) {
                val res = withContext(Dispatchers.IO) { RootSetup.run(act, hideToast && !ModuleStatus.isActive()) }
                res.forEach { log(it.name, it.ok) }
                prefs.rootSetupDone = true
                val old = withContext(Dispatchers.IO) { RootSetup.detectOldScript() }
                if (old.present || old.running) { oldScript = old; busy = false; return@launch }
            } else {
                // 无 Root：走标准系统授权弹窗
                act.requestNotificationPermission()
                if (!act.isIgnoringBattery()) act.requestIgnoreBattery()
                error = "未获得 Root：已改用系统授权。后台读取剪贴板需要 Root 或启用 LSPosed 模块，" +
                    "否则仅在打开本应用时同步本机剪贴板（写入电脑剪贴板到手机、自动接收、分享发送不受影响）。"
            }
            finish(); busy = false
        }
    }

    Column(Modifier.fillMaxSize().background(Mac.Bg).systemBarsPadding().imePadding().verticalScroll(rememberScrollState())) {
        Spacer(Modifier.height(40.dp))
        Box(Modifier.align(Alignment.CenterHorizontally).size(64.dp).background(Mac.Accent, RoundedCornerShape(16.dp)),
            contentAlignment = Alignment.Center) {
            Text("⇅", color = Color.White, fontSize = 30.sp, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.height(16.dp))
        Text("SyncHub", fontSize = 26.sp, fontWeight = FontWeight.SemiBold, color = Mac.Text,
            modifier = Modifier.align(Alignment.CenterHorizontally))
        Text("填一次账号，授予 Root，就和电脑端一样自动同步", fontSize = 14.sp, color = Mac.Text2,
            modifier = Modifier.align(Alignment.CenterHorizontally).padding(top = 4.dp, start = 24.dp, end = 24.dp))

        SectionTitle("服务器账号")
        MacCard(Modifier.padding(horizontal = 16.dp)) {
            Spacer(Modifier.height(8.dp))
            MacField("服务器地址", url, { url = it }, keyboard = KeyboardType.Uri)
            MacField("用户名", user, { user = it })
            MacField("密码", pass, { pass = it }, password = true)
            Row(Modifier.padding(start = 4.dp, end = 16.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Checkbox(hideToast, { hideToast = it }, colors = CheckboxDefaults.colors(checkedColor = Mac.Accent))
                Text("隐藏系统“已读取剪贴板”提示（Root 兼容模式下会以 Shell 名义提示；可在系统隐私设置中改回）",
                    fontSize = 12.sp, color = Mac.Text2)
            }
            if (xyz.synchub.android.util.Rom.isOplus) {
                Text(xyz.synchub.android.util.Rom.CLIP_HINT, fontSize = 12.sp, color = Mac.Orange,
                    modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 10.dp))
            }
        }
        Spacer(Modifier.height(20.dp))
        PrimaryButton(if (busy) "正在配置…" else "连接并一键配置", enabled = !busy && url.isNotBlank() && user.isNotBlank(),
            modifier = Modifier.padding(horizontal = 16.dp)) { go() }

        if (steps.isNotEmpty()) {
            SectionTitle("配置进度")
            MacCard(Modifier.padding(horizontal = 16.dp)) {
                steps.forEachIndexed { i, (name, ok) ->
                    if (i > 0) Hairline(36)
                    StatusRow(name, when (ok) { true -> "完成"; false -> "失败"; null -> "进行中…" },
                        when (ok) { true -> Mac.Green; false -> Mac.Orange; null -> Mac.Text3 })
                }
            }
        }
        error?.let {
            Text(it, color = if (finished) Mac.Text2 else Mac.Red, fontSize = 13.sp, modifier = Modifier.padding(16.dp))
        }
        if (finished) {
            PrimaryButton("完成", modifier = Modifier.padding(16.dp)) { onDone() }
        }
        Spacer(Modifier.height(24.dp))
    }

    oldScript?.let { old ->
        AlertDialog(
            onDismissRequest = {},
            title = { Text("发现旧版 Root 自动接收脚本") },
            text = {
                Text("检测到 ${RootSetup.OLD_SCRIPT}${if (old.running) "（正在运行）" else ""}。" +
                    "本应用已接管自动接收到 /sdcard/Download，两者同时运行会重复下载。\n\n" +
                    "是否停止并移除旧脚本？（会备份为 /data/adb/synchub_android.sh.bak，并沿用它的接收进度）")
            },
            confirmButton = {
                LinkButton("停止并移除") {
                    scope.launch {
                        val r = withContext(Dispatchers.IO) { RootSetup.removeOldScript(prefs, old) }
                        log(r.name, r.ok); oldScript = null; finish()
                    }
                }
            },
            dismissButton = {
                LinkButton("保留", color = Mac.Text2) {
                    old.lastId?.let { if (it > prefs.lastHubId) prefs.lastHubId = it }
                    oldScript = null; finish()
                }
            },
            containerColor = Color.White,
        )
    }
}

