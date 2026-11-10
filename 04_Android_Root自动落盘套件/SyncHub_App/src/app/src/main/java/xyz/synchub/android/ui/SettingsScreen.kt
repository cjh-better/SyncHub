package xyz.synchub.android.ui

import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import xyz.synchub.android.root.RootSetup
import xyz.synchub.android.root.RootShell
import xyz.synchub.android.sync.SyncService
import xyz.synchub.android.util.L
import xyz.synchub.android.util.Prefs

@Composable
fun SettingsScreen(act: MainActivity, onBack: () -> Unit, onLogs: () -> Unit, onRerunSetup: () -> Unit) {
    val p = remember { Prefs.get(act) }
    val scope = rememberCoroutineScope()
    var url by remember { mutableStateOf(p.serverUrl) }
    var user by remember { mutableStateOf(p.username) }
    var pass by remember { mutableStateOf(p.password) }
    var device by remember { mutableStateOf(p.deviceName) }
    var sub by remember { mutableStateOf(p.saveSubdir) }
    var interval by remember { mutableFloatStateOf(p.pollIntervalSec.toFloat()) }
    var push by remember { mutableStateOf(p.clipPush) }
    var pull by remember { mutableStateOf(p.clipPull) }
    var images by remember { mutableStateOf(p.clipImages) }
    var recv by remember { mutableStateOf(p.autoReceive) }
    var boot by remember { mutableStateOf(p.startOnBoot) }
    var useRoot by remember { mutableStateOf(p.useRootClipboard) }

    fun save() {
        p.serverUrl = url; p.username = user; p.password = pass; p.deviceName = device; p.saveSubdir = sub
        p.pollIntervalSec = interval.toInt(); p.clipPush = push; p.clipPull = pull; p.clipImages = images
        p.autoReceive = recv; p.startOnBoot = boot; p.useRootClipboard = useRoot
        if (p.serviceEnabled) SyncService.start(act, SyncService.ACTION_RELOAD)
        Toast.makeText(act, "已保存", Toast.LENGTH_SHORT).show()
        onBack()
    }

    Column(Modifier.fillMaxSize().background(Mac.Bg).systemBarsPadding().imePadding()) {
        TopBar("设置", left = { LinkButton("‹ 返回") { onBack() } }, right = { LinkButton("保存") { save() } })
        Column(Modifier.verticalScroll(rememberScrollState())) {
            SectionTitle("服务器")
            MacCard(Modifier.padding(horizontal = 16.dp)) {
                Spacer(Modifier.height(8.dp))
                MacField("服务器地址", url, { url = it }, keyboard = KeyboardType.Uri)
                MacField("用户名", user, { user = it })
                MacField("密码（加密保存在本机）", pass, { pass = it }, password = true)
                MacField("本机名称（发送来源）", device, { device = it })
                Spacer(Modifier.height(8.dp))
            }

            SectionTitle("剪贴板同步")
            MacCard(Modifier.padding(horizontal = 16.dp)) {
                SwitchRow("上传本机剪贴板", "复制的文字（及图片）发送到电脑", push) { push = it }
                Hairline()
                SwitchRow("接收电脑剪贴板", "电脑复制的内容自动写入手机剪贴板", pull) { pull = it }
                Hairline()
                SwitchRow("同步图片", "≤ 20 MB；上传图片需 LSPosed 模块", images) { images = it }
                Hairline()
                SwitchRow("使用 Root 兼容模式", "未启用 LSPosed 模块时用 Root 后台读取剪贴板", useRoot) { useRoot = it }
                if (xyz.synchub.android.util.Rom.isOplus) {
                    Hairline()
                    ActionRow("剪贴板权限：改为“始终允许”") { xyz.synchub.android.util.Rom.openAppDetails(act) }
                    Text(xyz.synchub.android.util.Rom.CLIP_HINT, fontSize = 12.sp, color = Mac.Text2,
                        modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 10.dp))
                }
                Hairline()
                Column(Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("轮询间隔", color = Mac.Text, fontSize = 15.sp, modifier = Modifier.weight(1f))
                        Text("${interval.toInt()} 秒", color = Mac.Text2, fontSize = 14.sp)
                    }
                    Slider(interval, { interval = it }, valueRange = 1f..30f, steps = 28,
                        colors = SliderDefaults.colors(thumbColor = Mac.Accent, activeTrackColor = Mac.Accent, inactiveTrackColor = Mac.Fill))
                    Text("熄屏时自动放慢为 4 倍（最长 30 秒），断网时指数退避", color = Mac.Text2, fontSize = 12.sp)
                }
            }

            SectionTitle("自动接收")
            MacCard(Modifier.padding(horizontal = 16.dp)) {
                SwitchRow("自动保存电脑发来的文件", "与 Windows 端相同：不重复下载，记录已接收位置", recv) { recv = it }
                Hairline()
                MacField("保存到 Download/ 下的子目录（留空 = Download 根目录）", sub, { sub = it })
                Spacer(Modifier.height(8.dp))
            }

            SectionTitle("运行")
            MacCard(Modifier.padding(horizontal = 16.dp)) {
                SwitchRow("开机自动启动", null, boot) { boot = it }
                Hairline()
                ActionRow("重新运行 Root 一键配置", "重新授予权限、电池白名单、检测旧版脚本") { onRerunSetup() }
                Hairline()
                ActionRow("电池优化白名单", if (act.isIgnoringBattery()) "已在白名单中" else "未加入，后台可能被系统冻结") { act.requestIgnoreBattery() }
                Hairline()
                ActionRow("通知权限") { act.requestNotificationPermission() }
                Hairline()
                ActionRow("所有文件访问权限", "用于直接写入 /sdcard/Download（无 Root 时手动授予）") { act.requestAllFilesAccess() }
                Hairline()
                ActionRow("检测旧版 Root 自动接收脚本") {
                    scope.launch {
                        val msg = withContext(Dispatchers.IO) {
                            if (!RootShell.isRootGranted()) "需要 Root" else {
                                val o = RootSetup.detectOldScript()
                                if (!o.present && !o.running) "未发现旧脚本"
                                else { RootSetup.removeOldScript(p, o); "已停止并移除（备份为 .bak）" }
                            }
                        }
                        Toast.makeText(act, msg, Toast.LENGTH_LONG).show()
                    }
                }
                Hairline()
                ActionRow("查看日志") { onLogs() }
            }
            Text("SyncHub Android ${xyz.synchub.android.BuildConfig.VERSION_NAME} · 同时是 LSPosed 模块（作用域：系统框架 + 本应用）",
                color = Mac.Text3, fontSize = 12.sp, modifier = Modifier.padding(16.dp))
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
fun LogsScreen(onBack: () -> Unit) {
    val lines = remember { L.lines() }
    val ctx = androidx.compose.ui.platform.LocalContext.current
    Column(Modifier.fillMaxSize().background(Mac.Bg).systemBarsPadding()) {
        TopBar("日志", left = { LinkButton("‹ 返回") { onBack() } }, right = { LinkButton("分享") {
            val st = xyz.synchub.android.util.Status.flow.value
            val head = "SyncHub ${xyz.synchub.android.BuildConfig.VERSION_NAME} · Android ${android.os.Build.VERSION.RELEASE} · " +
                "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}\n" +
                "服务运行=${st.serviceRunning} 连接=${st.connected} 模式=${st.clipMode.label} Root进程=${st.rootHelperAlive} " +
                "系统钩子=${st.systemHookVerified} 错误=${st.lastError}\n\n"
            val send = android.content.Intent(android.content.Intent.ACTION_SEND).setType("text/plain")
                .putExtra(android.content.Intent.EXTRA_SUBJECT, "SyncHub 日志")
                .putExtra(android.content.Intent.EXTRA_TEXT, head + L.text())
            runCatching { ctx.startActivity(android.content.Intent.createChooser(send, "分享日志")) }
        } })
        Column(Modifier.verticalScroll(rememberScrollState()).padding(12.dp).fillMaxWidth()) {
            if (lines.isEmpty()) Text("暂无日志", color = Mac.Text2)
            lines.forEach { Text(it, fontSize = 11.sp, color = Mac.Text, modifier = Modifier.padding(vertical = 2.dp)) }
        }
    }
}
