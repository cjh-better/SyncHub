package xyz.synchub.android.sync

import android.app.Service
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.content.FileProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import xyz.synchub.android.net.Hashing
import xyz.synchub.android.net.HubClient
import xyz.synchub.android.net.SyncClipboardClient
import xyz.synchub.android.root.HookCheck
import xyz.synchub.android.root.RootClipboardBridge
import xyz.synchub.android.root.RootShell
import xyz.synchub.android.util.ClipMode
import xyz.synchub.android.util.L
import xyz.synchub.android.util.Prefs
import xyz.synchub.android.util.Status
import xyz.synchub.android.xposed.ModuleStatus
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * 常驻前台服务：剪贴板双向同步 + SyncHub 自动接收。
 * 轮询间隔可配；熄屏时 ×4（最长 30s），连续失败指数退避到 60s，网络恢复 / 亮屏时立即唤醒。
 */
class SyncService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val pushExecutor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val kickClip = Channel<Unit>(Channel.CONFLATED)
    private val kickRecv = Channel<Unit>(Channel.CONFLATED)
    private lateinit var prefs: Prefs
    @Volatile private lateinit var engine: ClipSyncEngine
    private var rootBridge: RootClipboardBridge? = null
    private var clipListener: ClipboardManager.OnPrimaryClipChangedListener? = null
    @Volatile private var screenOn = true
    /** 两个轮询协程最近一次跑完一轮的时间，看门狗据此判断是否卡死。 */
    @Volatile private var clipTick = 0L
    @Volatile private var recvTick = 0L
    private var clipJob: kotlinx.coroutines.Job? = null
    private var recvJob: kotlinx.coroutines.Job? = null
    @Volatile private var lastNullClipLog = 0L
    /** 最近一次收到系统剪贴板变化回调的时间。 */
    @Volatile private var lastCallbackAt = 0L
    /** LSPosed 模式自检失败（后台收不到回调 / 读不到内容）后，本次服务生命周期内强制使用 Root 模式。 */
    @Volatile private var forceRoot = false

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            screenOn = i.action != Intent.ACTION_SCREEN_OFF
            if (screenOn) { kickClip.trySend(Unit); kickRecv.trySend(Unit) }
        }
    }
    private val netCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) { kickClip.trySend(Unit); kickRecv.trySend(Unit) }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        prefs = Prefs.get(this)
        instance = this
        L.i("同步服务启动 v${xyz.synchub.android.BuildConfig.VERSION_NAME} (Android ${Build.VERSION.RELEASE}/SDK ${Build.VERSION.SDK_INT}, " +
            "${Build.MANUFACTURER} ${Build.MODEL}) 已配置=${prefs.configured} 账号存储=${if (prefs.secureAvailable) "正常" else "不可用"} " +
            "上传=${prefs.clipPush} 下载=${prefs.clipPull} 间隔=${prefs.pollIntervalSec}s")
        if (isOplus()) L.i("提示：" + xyz.synchub.android.util.Rom.CLIP_HINT)
        if (!prefs.secureAvailable) L.w("加密账号存储不可用：用户名/密码读不到，同步不会进行。请到 设置 里重新填写账号并保存")
        else if (!prefs.configured) L.w("未配置服务器或用户名：同步不会进行。请到 设置 里填写")
        if (!goForeground("正在启动…")) { stopSelf(); return }
        engine = newEngine()
        screenOn = getSystemService(PowerManager::class.java).isInteractive
        androidx.core.content.ContextCompat.registerReceiver(this, screenReceiver, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON); addAction(Intent.ACTION_SCREEN_OFF)
        }, androidx.core.content.ContextCompat.RECEIVER_NOT_EXPORTED)
        runCatching { getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(netCallback) }
        Status.update { it.copy(serviceRunning = true) }
        scope.launch { safeRun("剪贴板来源初始化") { setupClipSource() } }
        startLoops()
        Watchdog.schedule(this)
    }

    private fun newEngine() = ClipSyncEngine(SyncClipboardClient(prefs.server()), prefs,
        pullImages = { prefs.clipImages }, log = { L.i(it) })

    /** 协程意外结束（任何 Throwable）时记录并在 5 秒后重启，保证轮询永远不会静默停止。 */
    private fun startLoops() {
        if (clipJob?.isActive != true) clipJob = scope.launch { supervised("剪贴板拉取") { clipPullLoop() } }
        if (recvJob?.isActive != true) recvJob = scope.launch { supervised("自动接收") { receiveLoop() } }
    }

    private suspend fun supervised(name: String, block: suspend () -> Unit) {
        while (scope.isActive) {
            try { block() } catch (e: kotlinx.coroutines.CancellationException) {
                if (!scope.isActive) throw e
                L.w("$name 循环被取消，5 秒后重启", e)
            } catch (t: Throwable) {
                L.w("$name 循环异常退出，5 秒后重启", t)
            }
            if (!scope.isActive) break
            delay(5000)
        }
    }

    private suspend fun safeRun(name: String, block: suspend () -> Unit) {
        try { block() } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (t: Throwable) { L.w("$name 失败", t) }
    }

    /** 看门狗每 15 分钟调用：轮询协程超过 3 分钟没有完成一轮就重启它们。 */
    fun healthCheck() {
        val now = System.currentTimeMillis()
        val stale = 180_000L
        if (prefs.configured && prefs.clipPull && now - clipTick > stale) {
            L.w("看门狗：剪贴板拉取 ${(now - clipTick) / 1000}s 没有进展，重启该循环"); clipJob?.cancel(); clipJob = null
        }
        if (prefs.configured && prefs.autoReceive && now - recvTick > stale) {
            L.w("看门狗：自动接收 ${(now - recvTick) / 1000}s 没有进展，重启该循环"); recvJob?.cancel(); recvJob = null
        }
        startLoops()
        if (Status.flow.value.clipMode == ClipMode.ROOT && rootBridge == null && prefs.clipPush)
            scope.launch { safeRun("剪贴板来源重建") { reload() } }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> { L.i("用户在通知里点了“停止”"); prefs.serviceEnabled = false; Watchdog.cancel(this); stopSelf(); return START_NOT_STICKY }
            ACTION_KICK -> { kickClip.trySend(Unit); kickRecv.trySend(Unit) }
            ACTION_RELOAD -> scope.launch { safeRun("重新加载") { reload() } }
        }
        intent?.getStringExtra(EXTRA_REASON)?.let { L.i("启动请求: $it") }
        if (intent == null) L.i("服务被系统重新拉起 (START_STICKY)")
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        L.i("应用已从最近任务划掉（服务继续运行）")
        super.onTaskRemoved(rootIntent)
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        L.w("系统前台服务超时 (type=$fgsType)，停止并等待看门狗重启")
        stopSelf()
    }

    override fun onDestroy() {
        L.i("同步服务停止 (serviceEnabled=${prefs.serviceEnabled})")
        if (instance === this) instance = null
        scope.cancel()
        rootBridge?.stop()
        clipListener?.let { getSystemService(ClipboardManager::class.java).removePrimaryClipChangedListener(it) }
        runCatching { unregisterReceiver(screenReceiver) }
        runCatching { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(netCallback) }
        pushExecutor.shutdownNow()
        Status.update { it.copy(serviceRunning = false, clipMode = ClipMode.OFF, rootHelperAlive = false) }
        super.onDestroy()
    }

    private suspend fun reload() {
        engine = newEngine()
        clipSetupLock.withLock { setupClipSourceLocked() }
        kickClip.trySend(Unit); kickRecv.trySend(Unit)
    }

    // ---------------- 本地剪贴板 → 服务器 ----------------

    private val clipSetupLock = kotlinx.coroutines.sync.Mutex()

    private suspend fun setupClipSource() = clipSetupLock.withLock { setupClipSourceLocked() }

    private suspend fun teardownClipSource() {
        rootBridge?.stop(); rootBridge = null
        withContext(Dispatchers.Main) {
            clipListener?.let { getSystemService(ClipboardManager::class.java).removePrimaryClipChangedListener(it) }
            clipListener = null
        }
    }

    private suspend fun setupClipSourceLocked() {
        // 先拆掉旧的来源，避免 onCreate 与 RELOAD 并发时出现两个 Root 进程 / 两个监听器
        teardownClipSource()
        if (!prefs.clipPush) { setMode(ClipMode.OFF); L.i("剪贴板上传已关闭"); return }
        val module = ModuleStatus.isActive()
        val rootOk = prefs.useRootClipboard && RootShell.isRootGranted()
        var hookVerified: Boolean? = null
        val mode = when {
            forceRoot && rootOk -> {
                hookVerified = false
                L.w("LSPosed 模式自检失败过，本次改用 Root 兼容模式")
                ClipMode.ROOT
            }
            module && rootOk -> {
                // 只有“系统框架”钩子在本次开机真正生效时才用 LSPosed 模式；否则后台根本收不到剪贴板变化
                val hc = HookCheck.check()
                L.i("LSPosed 系统框架钩子检测: ${hc.state.label} (${hc.detail})")
                if (hc.state == HookCheck.State.ACTIVE || hc.state == HookCheck.State.STALE) { hookVerified = true; ClipMode.LSPOSED }
                else {
                    hookVerified = false
                    L.w("LSPosed 系统框架钩子未生效 → 改用 Root 兼容模式读取剪贴板。若想用 LSPosed 模式：在 LSPosed 里确认作用域勾选“系统框架”，然后重启手机")
                    ClipMode.ROOT
                }
            }
            module -> ClipMode.LSPOSED
            rootOk -> ClipMode.ROOT
            else -> ClipMode.FOREGROUND
        }
        Status.update { it.copy(systemHookVerified = hookVerified) }
        setMode(mode)
        if (mode == ClipMode.FOREGROUND) L.w("没有 Root 授权也没有 LSPosed 模块：手机剪贴板只在打开 SyncHub 时上传")
        when (mode) {
            ClipMode.ROOT -> rootBridge = RootClipboardBridge(this) { text -> pushText(text, "root") }.also { it.start() }
            else -> withContext(Dispatchers.Main) {
                // LSPosed 模式下系统允许本应用后台读取；“仅前台”模式下只有应用在前台时回调才会成功
                val cm = getSystemService(ClipboardManager::class.java)
                val l = ClipboardManager.OnPrimaryClipChangedListener { onSystemClipChanged() }
                cm.addPrimaryClipChangedListener(l)
                clipListener = l
            }
        }
        L.i("剪贴板来源: ${mode.label}")
    }

    private fun isOplus() = xyz.synchub.android.util.Rom.isOplus

    private fun setMode(m: ClipMode) {
        Status.update { it.copy(clipMode = m) }
        goForeground(null)
    }

    private fun onSystemClipChanged() = try { onSystemClipChangedInner() } catch (t: Throwable) {
        L.w("处理剪贴板变化失败", t)   // 主线程上的异常绝不能让进程崩溃
    }

    private fun onSystemClipChangedInner() {
        lastCallbackAt = System.currentTimeMillis()
        L.i("收到系统剪贴板变化回调（模式 ${Status.flow.value.clipMode.label}，应用${if (appVisible) "在前台" else "在后台"}）")
        val cm = getSystemService(ClipboardManager::class.java)
        val clip = try { cm.primaryClip } catch (e: Exception) { L.w("读取剪贴板失败", e); null }
        if (clip == null || clip.itemCount == 0) {
            if (Status.flow.value.clipMode == ClipMode.LSPOSED && runCatching { cm.hasPrimaryClip() }.getOrDefault(false))
                Status.update { it.copy(systemHookVerified = false) }
            val now = System.currentTimeMillis()
            if (now - lastNullClipLog > 60_000) {
                lastNullClipLog = now
                L.w("剪贴板变化了，但读到的内容为空（模式 ${Status.flow.value.clipMode.label}）：系统可能拒绝了后台读取剪贴板")
            }
            if (Status.flow.value.clipMode == ClipMode.LSPOSED && !appVisible) lsposedSelfTestFailed("后台回调里读不到剪贴板内容")
            return
        }
        if (Status.flow.value.clipMode == ClipMode.LSPOSED) Status.update { it.copy(systemHookVerified = true) }
        val item = clip.getItemAt(0)
        val desc = clip.description
        val uri = item.uri
        val mime = uri?.let { runCatching { contentResolver.getType(it) }.getOrNull() }
            ?: (0 until desc.mimeTypeCount).map { desc.getMimeType(it) }.firstOrNull { it.startsWith("image/") }
        if (uri != null && mime != null && mime.startsWith("image/")) {
            if (uri.authority == "$packageName.files") return   // 我们自己写入的远端图片
            if (prefs.clipImages) pushImage(uri, mime)
            return
        }
        val text = item.text?.toString() ?: item.htmlText
        if (text == null) { L.i("剪贴板变化：不是文本（${desc.getMimeType(0)}），跳过"); return }
        pushText(text, "system")
    }

    /** 由前台界面（获得焦点时）调用，“仅前台”模式下也能把当前剪贴板推上去。 */
    fun onForegroundFocus() {
        if (prefs.clipPush) main.post { onSystemClipChanged() }
    }

    fun pushText(text: String, src: String) {
        if (!prefs.clipPush) { L.i("剪贴板上传已关闭，忽略本地变化"); return }
        if (!prefs.configured) { L.w("未配置账号，忽略本地剪贴板变化"); return }
        if (pushExecutor.isShutdown) return
        runCatching { pushExecutor.execute {
            try {
                if (engine.onLocalText(text, src)) {
                    L.i("已推送文本 (${text.length} 字, 来源 $src)")
                    Status.update { it.copy(lastPush = preview(text), connected = true, lastError = null, lastOkAt = System.currentTimeMillis()) }
                }
            } catch (t: Throwable) {
                L.w("推送剪贴板失败 (${text.length} 字, 来源 $src)", t); markError(t)
            }
        } }   // 服务销毁后 executor 已关闭：忽略迟到的回调
    }

    private fun pushImage(uri: android.net.Uri, mime: String) {
        if (pushExecutor.isShutdown) return
        runCatching { pushExecutor.execute {
            try {
                val bytes = contentResolver.openInputStream(uri)?.use { s ->
                    val buf = s.readBytes(); if (buf.size > 20 * 1024 * 1024) null else buf
                } ?: return@execute
                val ext = android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: "png"
                val name = "IMG_" + SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date()) + "." + ext
                if (engine.onLocalImage(name, bytes)) {
                    L.i("已推送图片 $name (${bytes.size} B)")
                    Status.update { it.copy(lastPush = "图片 $name", connected = true, lastError = null) }
                }
            } catch (t: Throwable) { L.w("推送图片失败", t); markError(t) }
        } }
    }

    // ---------------- 服务器 → 本地剪贴板 ----------------

    private suspend fun clipPullLoop() {
        var fails = 0
        var polls = 0L
        var lastBeat = System.currentTimeMillis()
        var idleLogged = false
        while (scope.isActive) {
            clipTick = System.currentTimeMillis()
            if (prefs.clipPull && prefs.configured) {
                idleLogged = false
                try {
                    polls++
                    when (val ch = engine.pollRemote()) {
                        is RemoteChange.Text -> writeRemoteText(ch)
                        is RemoteChange.Image -> {
                            val dir = File(cacheDir, "clip").apply { mkdirs() }
                            dir.listFiles()?.forEach { it.delete() }
                            val f = File(dir, AutoReceiver.sanitize(ch.name)).apply { writeBytes(ch.bytes) }
                            val uri = FileProvider.getUriForFile(this, "$packageName.files", f)
                            withContext(Dispatchers.Main) {
                                getSystemService(ClipboardManager::class.java)
                                    .setPrimaryClip(remoteClip(ClipData.newUri(contentResolver, "SyncHub", uri)))
                            }
                            Status.update { it.copy(lastPull = "图片 ${ch.name}") }
                            L.i("已写入远端图片 ${ch.name}")
                        }
                        null -> Unit
                    }
                    if (fails > 0) L.i("剪贴板拉取已恢复（之前连续失败 $fails 次）")
                    fails = 0
                    markOk()
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (t: Throwable) {
                    fails++
                    if (fails <= 3 || fails % 20 == 0) L.w("拉取剪贴板失败 (#$fails)", t)
                    markError(t)
                }
            } else if (!idleLogged) {
                idleLogged = true
                L.w("剪贴板拉取暂停：下载=${prefs.clipPull} 已配置=${prefs.configured}")
            }
            val now = System.currentTimeMillis()
            if (now - lastBeat > 30 * 60_000L) {
                lastBeat = now
                val st = Status.flow.value
                L.i("心跳：30 分钟内拉取 $polls 次，连续失败 $fails，模式 ${st.clipMode.label}，Root 进程=${st.rootHelperAlive}，亮屏=$screenOn")
                polls = 0
            }
            waitNext(kickClip, fails)
        }
    }

    @Volatile private var writeWarned = false

    /**
     * 把远端文本写入手机剪贴板并回读确认真的生效（有读取能力时：应用自身回读，或 Root 剪贴板进程观察到这段文本）。
     * 写入被系统静默拦截时（例如 ColorOS / realme UI 的剪贴板权限是“仅在使用中允许”）记 W 日志并发通知提示用户。
     */
    private suspend fun writeRemoteText(ch: RemoteChange.Text) {
        val mode = Status.flow.value.clipMode
        val cm = getSystemService(ClipboardManager::class.java)
        suspend fun readHash(): String? = withContext(Dispatchers.Main) {
            runCatching { cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString() }.getOrNull()
        }?.let { Hashing.textHash(it) }
        val bridge = rootBridge?.takeIf { it.ready }
        val prevText = readHash()
        val prevRoot = bridge?.lastSeenHash
        val before = System.currentTimeMillis()
        val err = withContext(Dispatchers.Main) {
            runCatching { cm.setPrimaryClip(remoteClip(ClipData.newPlainText("SyncHub", ch.text))) }.exceptionOrNull()
        }
        if (err != null) L.w("写入剪贴板抛出异常", err)
        var nowText: String? = null
        var confirmed = false
        val deadline = System.currentTimeMillis() + 6000   // Root 进程监听失效时靠 5 秒轮询才能看到
        while (System.currentTimeMillis() < deadline) {
            delay(300)
            nowText = readHash()
            if (nowText == ch.hash || (bridge != null && bridge.lastSeenHash == ch.hash)) { confirmed = true; break }
            if (nowText == null && bridge == null) break
        }
        val vis = if (appVisible) "前台" else "后台"
        if (mode == ClipMode.LSPOSED && !appVisible && lastCallbackAt < before && nowText == null)
            lsposedSelfTestFailed("后台写入剪贴板后既没收到变化回调也读不回内容")
        when {
            confirmed -> {
                L.i("已写入远端文本到手机剪贴板 (${ch.text.length} 字, 已回读确认, 模式 ${mode.label}, 应用在$vis)")
                Status.update { it.copy(lastPull = preview(ch.text)) }
                if (writeWarned) { writeWarned = false; Notifs.cancelClipBlocked(this) }
            }
            nowText == null && bridge == null -> {
                L.i("已写入远端文本到手机剪贴板 (${ch.text.length} 字, 无读取权限无法回读确认, 模式 ${mode.label}, 应用在$vis)")
                Status.update { it.copy(lastPull = preview(ch.text)) }
            }
            (nowText != null && nowText != prevText) || (nowText == null && bridge?.lastSeenHash != prevRoot) ->
                L.i("写入后剪贴板已被其他新内容覆盖（用户又复制了别的），不重写")
            else -> {
                engine.release(ch.hash)
                L.w("写入剪贴板没有生效：系统剪贴板仍是写入前的内容（应用在$vis，模式 ${mode.label}）。" +
                    "系统拦截了后台写剪贴板——请在系统设置里把 SyncHub 的“剪贴板”权限改为“始终允许”" +
                    (if (isOplus()) "（realme/OPPO/OnePlus：设置 → 应用 → SyncHub → 权限 → 剪贴板 → 始终允许）" else ""))
                if (!writeWarned) { writeWarned = true; Notifs.clipBlocked(this, isOplus()) }
                if (err != null) throw err
            }
        }
    }

    private fun lsposedSelfTestFailed(why: String) {
        if (forceRoot) return
        Status.update { it.copy(systemHookVerified = false) }
        if (prefs.useRootClipboard && RootShell.cachedRoot() == true) {
            forceRoot = true
            L.w("LSPosed 模式自检失败（$why）→ 系统框架钩子没有起作用，切换到 Root 兼容模式")
            scope.launch { safeRun("切换到 Root 模式") { clipSetupLock.withLock { setupClipSourceLocked() } } }
        } else {
            L.w("LSPosed 模式自检失败（$why），且没有 Root 授权，无法切换：手机剪贴板只能在打开 SyncHub 时上传")
        }
    }

    // ---------------- SyncHub 自动接收 ----------------

    private suspend fun receiveLoop() {
        var fails = 0
        var receiver: AutoReceiver? = null
        var cfgKey = ""
        while (scope.isActive) {
            recvTick = System.currentTimeMillis()
            if (prefs.autoReceive && prefs.configured) {
                val key = prefs.server().toString() + prefs.deviceName
                if (receiver == null || key != cfgKey) {
                    cfgKey = key
                    receiver = AutoReceiver(HubClient(prefs.server()), prefs, { Storage.sink(this) },
                        device = prefs.deviceName.lowercase(), skipHash = { engine.isKnown(it) },
                        onProgress = { item, got, total -> TransferNotifier.progress(this, "recv-${item.id}", "接收 ${item.filename}", got, total) })
                }
                try {
                    val got = receiver.pollOnce()
                    for (r in got) {
                        TransferNotifier.done(this, "recv-${r.item.id}", "📥 已接收 ${r.item.filename}",
                            "来自 ${r.item.fromDevice} · 已保存到 ${r.path}", r.path)
                        Status.update { it.copy(lastReceived = r.item.filename) }
                        L.i("已接收 ${r.item.filename} → ${r.path}")
                    }
                    fails = 0; markOk()
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (t: Throwable) {
                    fails++
                    if (fails <= 3 || fails % 20 == 0) L.w("自动接收轮询失败 (#$fails)", t)
                    markError(t)
                }
            }
            waitNext(kickRecv, fails, minSec = 3)
        }
    }

    private suspend fun waitNext(kick: Channel<Unit>, fails: Int, minSec: Int = 1) {
        var ms = prefs.pollIntervalSec.coerceAtLeast(minSec) * 1000L
        if (!screenOn) ms = (ms * 4).coerceAtMost(30_000)
        if (fails > 0) ms = (ms shl fails.coerceAtMost(5)).coerceAtMost(60_000)
        withTimeoutOrNull(ms) { kick.receive() }
        delay(50)
    }

    private fun markOk() = Status.update {
        it.copy(connected = true, lastError = null, lastOkAt = System.currentTimeMillis())
    }
    private fun markError(e: Throwable) = Status.update { it.copy(connected = false, lastError = e.message ?: e.toString()) }

    /** Android 13+：标记为“来自其他设备”的剪贴板内容（系统据此调整剪贴板预览浮层）。 */
    private fun remoteClip(c: ClipData): ClipData {
        if (Build.VERSION.SDK_INT >= 33) {
            c.description.extras = android.os.PersistableBundle().apply {
                putBoolean("android.content.extra.IS_REMOTE_DEVICE", true)
            }
        }
        return c
    }

    private fun preview(s: String) = s.replace('\n', ' ').take(60)

    /** 返回 false 表示系统拒绝了前台服务（例如 Android 12+ 从后台被拉起且不在电池白名单）。不再让进程崩溃。 */
    private fun goForeground(text: String?): Boolean = try {
        goForegroundInner(text); true
    } catch (t: Throwable) {
        L.w("无法进入前台服务（请在系统设置里把 SyncHub 设为“不限制电池/允许后台运行”）", t); false
    }

    private fun goForegroundInner(text: String?) {
        val st = Status.flow.value
        val content = text ?: buildString {
            append("剪贴板：").append(st.clipMode.label)
            if (prefs.autoReceive) append(" · 自动接收已开启")
        }
        val n = Notifs.builder(this, Notifs.CH_SYNC)
            .setContentTitle("SyncHub 同步中")
            .setContentText(content)
            .setOngoing(true)
            .setSilent(true)
            .addAction(0, "停止", android.app.PendingIntent.getService(this, 1,
                Intent(this, SyncService::class.java).setAction(ACTION_STOP), android.app.PendingIntent.FLAG_IMMUTABLE))
            .build()
        if (Build.VERSION.SDK_INT >= 34)
            startForeground(Notifs.ID_SYNC, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        else
            startForeground(Notifs.ID_SYNC, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
    }

    companion object {
        const val ACTION_STOP = "xyz.synchub.android.STOP"
        const val ACTION_KICK = "xyz.synchub.android.KICK"
        const val ACTION_RELOAD = "xyz.synchub.android.RELOAD"
        @Volatile var instance: SyncService? = null
        /** MainActivity 是否在前台（onResume/onPause 维护）。 */
        @Volatile var appVisible = false

        const val EXTRA_REASON = "reason"

        fun start(ctx: Context, action: String? = null, reason: String? = null) {
            Prefs.get(ctx).serviceEnabled = true
            val i = Intent(ctx, SyncService::class.java).setAction(action)
            reason?.let { i.putExtra(EXTRA_REASON, it) }
            try { ctx.startForegroundService(i) } catch (e: Exception) { L.w("无法启动前台服务 (${reason ?: action ?: "手动"})", e) }
        }

        fun stop(ctx: Context) {
            L.i("用户手动停止同步")
            Prefs.get(ctx).serviceEnabled = false
            Watchdog.cancel(ctx)
            ctx.stopService(Intent(ctx, SyncService::class.java))
        }
    }
}
