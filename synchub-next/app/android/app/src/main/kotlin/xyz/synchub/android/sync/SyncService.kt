package xyz.synchub.android.sync

import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.webkit.MimeTypeMap
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import xyz.synchub.android.BuildConfig
import xyz.synchub.android.SyncHubEngineHost
import xyz.synchub.android.root.HookCheck
import xyz.synchub.android.root.RootClipboardBridge
import xyz.synchub.android.root.RootSetup
import xyz.synchub.android.root.RootShell
import xyz.synchub.android.util.ClipMode
import xyz.synchub.android.util.L
import xyz.synchub.android.util.NativePrefs
import xyz.synchub.android.util.Rom
import xyz.synchub.android.util.Status
import xyz.synchub.android.xposed.ModuleStatus
import java.io.File
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 常驻前台服务：
 * 1) 宿主单实例共享 [SyncHubEngineHost] (`FlutterEngine`)，确保 MainActivity 关闭或开机自启后后台仍持续连接网关；
 * 2) 自动识别 Magisk / KernelSU / APatch Root 授权与 LSPosed 钩子状态，智能选择 `LSPOSED` -> `ROOT` -> `FOREGROUND`；
 * 3) 当 LSPosed 刚启用未重启手机或 ROM 拦截后台读取时，零感秒切 `ROOT` (`app_process` 降权 `com.android.shell`) 兜底；
 * 4) 监听亮屏/熄屏广播与网络连接恢复，向 Dart 推送 `screen_state` 与 `network_available` 事件。
 */
class SyncService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val clipExecutor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val clipSetupLock = Mutex()
    private val selfTestFallbackInFlight = AtomicBoolean(false)

    private lateinit var prefs: NativePrefs
    private var rootBridge: RootClipboardBridge? = null
    private var clipListener: ClipboardManager.OnPrimaryClipChangedListener? = null

    @Volatile private var screenOn = true
    @Volatile private var lastNullClipLog = 0L
    @Volatile private var lastNoFallbackLog = 0L
    @Volatile private var forceRoot = false

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            when (i.action) {
                PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED -> {
                    val pm = c.getSystemService(PowerManager::class.java)
                    val isDoze = pm?.isDeviceIdleMode == true
                    L.i("Doze mode broadcast: isDeviceIdleMode=$isDoze")
                    SyncHubEngineHost.emitEvent(
                        mapOf(
                            "type" to "doze_mode_changed",
                            "doze" to isDoze,
                            "idle" to isDoze,
                        ),
                    )
                }
                Intent.ACTION_SCREEN_ON, Intent.ACTION_SCREEN_OFF -> {
                    val isOn = i.action != Intent.ACTION_SCREEN_OFF
                    screenOn = isOn
                    SyncHubEngineHost.emitEvent(
                        mapOf(
                            "type" to "screen_state",
                            "screenOn" to isOn,
                            "interactive" to isOn,
                            "on" to isOn,
                            "state" to if (isOn) "on" else "off",
                        ),
                    )
                }
            }
        }
    }

    private val netCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            SyncHubEngineHost.emitEvent(
                mapOf(
                    "type" to "network_available",
                    "available" to true,
                ),
            )
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        prefs = NativePrefs.get(this)
        instance = this
        L.i(
            "同步服务启动 v${BuildConfig.VERSION_NAME} (Android ${Build.VERSION.RELEASE}/SDK ${Build.VERSION.SDK_INT}, " +
                "${Build.MANUFACTURER} ${Build.MODEL}) 上传=${prefs.clipPush} 图片=${prefs.clipImages}",
        )
        if (Rom.isOplus) L.i("提示：" + Rom.CLIP_HINT)

        // 先进入前台服务，满足 Android 5 秒前台通知时限要求
        if (!goForeground("正在启动…")) {
            stopSelf()
            return
        }

        // 启动或复用单实例共享 FlutterEngine
        runCatching { SyncHubEngineHost.ensureEngine(applicationContext) }
            .onFailure { L.w("SyncService 初始化 FlutterEngine 失败", it) }

        screenOn = runCatching { getSystemService(PowerManager::class.java).isInteractive }.getOrDefault(true)
        ContextCompat.registerReceiver(
            this,
            screenReceiver,
            IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_ON)
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
            },
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        runCatching {
            getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(netCallback)
        }

        Status.update { it.copy(serviceRunning = true) }
        scope.launch { safeRun("剪贴板来源初始化") { setupClipSource() } }
        Watchdog.schedule(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                L.i("用户在通知栏点击了“停止”")
                prefs.serviceEnabled = false
                Watchdog.cancel(this)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_RELOAD -> requestReload()
        }
        intent?.getStringExtra(EXTRA_REASON)?.let { L.i("服务启动原因: $it") }
        if (intent == null) L.i("服务由系统重新拉起 (START_STICKY)")
        runCatching { SyncHubEngineHost.ensureEngine(applicationContext) }
        goForeground(null)
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        L.i("主界面从最近任务划掉（后台同步服务保持运行）")
        super.onTaskRemoved(rootIntent)
    }

    override fun onTimeout(startId: Int) {
        L.w("系统前台服务超时，停止并等待看门狗拉起")
        stopSelf()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        L.w("系统前台服务超时 (type=$fgsType)，停止并等待看门狗拉起")
        stopSelf()
    }

    override fun onDestroy() {
        L.i("同步服务停止 (serviceEnabled=${prefs.serviceEnabled})")
        if (instance === this) instance = null
        scope.cancel()
        rootBridge?.stop()
        rootBridge = null
        clipListener?.let {
            runCatching { getSystemService(ClipboardManager::class.java).removePrimaryClipChangedListener(it) }
        }
        clipListener = null
        runCatching { unregisterReceiver(screenReceiver) }
        runCatching { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(netCallback) }
        clipExecutor.shutdownNow()
        SyncHubEngineHost.releaseWakeLock()
        Status.update { it.copy(serviceRunning = false, clipMode = ClipMode.OFF, rootHelperAlive = false) }
        super.onDestroy()
    }

    /** 看门狗每 15 分钟检查：确保共享 FlutterEngine 在线，以及 Root 剪贴板守护进程未掉线。 */
    fun healthCheck() {
        main.post {
            runCatching { SyncHubEngineHost.ensureEngine(applicationContext) }
                .onFailure { L.w("看门狗恢复 FlutterEngine 失败", it) }
        }
        val st = Status.flow.value
        if (st.clipMode == ClipMode.ROOT && (rootBridge == null || !st.rootHelperAlive) && prefs.clipPush) {
            requestReload()
        }
    }

    fun requestReload() {
        scope.launch { safeRun("重新加载剪贴板来源") { setupClipSource() } }
    }

    fun latestRootText(): String? = rootBridge?.takeIf { it.ready }?.lastSeenText
    fun latestRootHash(): String? = rootBridge?.takeIf { it.ready }?.lastSeenHash
    fun writeClipboardViaRoot(text: String): Boolean = rootBridge?.writeText(text) == true

    /**
     * 前台界面获得窗口焦点时调用：
     * 1) 若用户在 KernelSU / APatch / Magisk 管理器刚刚授予了 Root 并切回应用，自动检测并无缝升级至 Root 守护；
     * 2) 主动读取并推送当前剪贴板。
     */
    fun onForegroundFocus() {
        val st = Status.flow.value
        if (prefs.clipPush && prefs.useRootClipboard &&
            (st.clipMode == ClipMode.FOREGROUND || (st.clipMode == ClipMode.LSPOSED && st.systemHookVerified == false))
        ) {
            scope.launch {
                if (RootShell.probeRoot(timeoutSec = 4)) {
                    prefs.rootGrantedOnce = true
                    if (st.clipMode == ClipMode.LSPOSED && st.systemHookVerified == false) {
                        forceRoot = true
                    }
                    safeRun("切回前台自动激活 Root 守护") { setupClipSource() }
                }
            }
        }
        if (prefs.clipPush &&
            (st.clipMode == ClipMode.FOREGROUND || (st.clipMode == ClipMode.LSPOSED && st.systemHookVerified == false))
        ) {
            main.post { onSystemClipChanged() }
        }
    }

    private suspend fun safeRun(name: String, block: suspend () -> Unit) {
        try {
            block()
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (t: Throwable) {
            L.w("$name 失败", t)
        }
    }

    private suspend fun setupClipSource() = clipSetupLock.withLock { setupClipSourceLocked() }

    private suspend fun teardownClipSource() {
        rootBridge?.stop()
        rootBridge = null
        withContext(Dispatchers.Main) {
            clipListener?.let {
                runCatching { getSystemService(ClipboardManager::class.java).removePrimaryClipChangedListener(it) }
            }
            clipListener = null
        }
    }

    private suspend fun setupClipSourceLocked() {
        teardownClipSource()
        if (!prefs.clipPush) {
            setMode(ClipMode.OFF)
            L.i("剪贴板上传已关闭")
            return
        }

        val module = ModuleStatus.isActive()
        // 主动探测 Root（兼容用户在 KernelSU / APatch / Magisk 管理器中直接授权而无需先点应用内按钮）
        val hasRoot = RootShell.cachedRoot() == true || RootShell.probeRoot(timeoutSec = 8)
        if (hasRoot && !prefs.rootGrantedOnce) {
            prefs.rootGrantedOnce = true
            L.i("已自动识别到系统 Root 授权 (uid=0)")
        }
        if (hasRoot && !prefs.rootSetupDone) {
            prefs.rootSetupDone = true
            runCatching {
                RootSetup.run(applicationContext, hideClipboardToast = !module)
                RootSetup.detectOldScript(prefs)
            }.onFailure { L.w("自动执行初始 Root 权限配置异常", it) }
        }

        val rootOk = prefs.useRootClipboard && hasRoot
        var hookVerified: Boolean? = null

        val mode = when {
            forceRoot && rootOk -> {
                hookVerified = false
                L.i("LSPosed 后台读取受限，已无缝启用 Root 兼容模式守护")
                ClipMode.ROOT
            }
            module && rootOk -> {
                val hc = HookCheck.check()
                L.i("LSPosed 系统框架钩子检测: ${hc.state.label} (${hc.detail})")
                if (hc.state == HookCheck.State.ACTIVE || hc.state == HookCheck.State.STALE) {
                    hookVerified = true
                    ClipMode.LSPOSED
                } else {
                    hookVerified = false
                    L.i("LSPosed 系统框架钩子本次开机未加载（启用/更新模块后重启手机即可生效）→ 当前自动使用 Root 兼容模式")
                    ClipMode.ROOT
                }
            }
            module -> ClipMode.LSPOSED
            rootOk -> ClipMode.ROOT
            else -> ClipMode.FOREGROUND
        }

        val prevMode = Status.flow.value.clipMode
        Status.update { it.copy(systemHookVerified = hookVerified) }
        setMode(mode)
        if (mode == ClipMode.FOREGROUND && prevMode != ClipMode.FOREGROUND) {
            L.w("未检测到 LSPosed 或 Root 授权：剪贴板在打开 SyncHub 界面时自动上传")
        }

        when (mode) {
            ClipMode.ROOT -> {
                rootBridge = RootClipboardBridge(this) { text ->
                    emitLocalClipText(text, "root")
                }.also { it.start() }
            }
            else -> withContext(Dispatchers.Main) {
                val cm = getSystemService(ClipboardManager::class.java)
                val listener = ClipboardManager.OnPrimaryClipChangedListener { onSystemClipChanged() }
                cm.addPrimaryClipChangedListener(listener)
                clipListener = listener
            }
        }
        if (prevMode != mode) {
            L.i("剪贴板监听模式: ${mode.label}")
        }
    }

    private fun setMode(m: ClipMode) {
        Status.update { it.copy(clipMode = m) }
        main.post { goForeground(null) }
    }

    private fun onSystemClipChanged() = try {
        onSystemClipChangedInner()
    } catch (t: Throwable) {
        L.w("处理系统剪贴板变化失败", t)
    }

    private fun onSystemClipChangedInner() {
        SyncHubEngineHost.incrementClipboardChangeCount()
        val mode = Status.flow.value.clipMode
        val cm = getSystemService(ClipboardManager::class.java)
        val clip = try {
            cm.primaryClip
        } catch (e: Exception) {
            L.w("读取系统剪贴板失败", e)
            null
        }
        if (clip == null || clip.itemCount == 0) {
            if (mode == ClipMode.LSPOSED && runCatching { cm.hasPrimaryClip() }.getOrDefault(false)) {
                Status.update { it.copy(systemHookVerified = false) }
            }
            val now = System.currentTimeMillis()
            if (now - lastNullClipLog > 60_000) {
                lastNullClipLog = now
                L.w("剪贴板变化但读到空内容（模式 ${mode.label}）：后台读取可能受限")
            }
            if (mode == ClipMode.LSPOSED && !appVisible) {
                lsposedSelfTestFailed("后台回调读不到剪贴板内容")
            }
            return
        }

        if (mode == ClipMode.LSPOSED) {
            Status.update { it.copy(systemHookVerified = true) }
        }

        val item = clip.getItemAt(0)
        val desc = clip.description
        val uri = item.uri
        val mime = uri?.let { runCatching { contentResolver.getType(it) }.getOrNull() }
            ?: (0 until desc.mimeTypeCount).map { desc.getMimeType(it) }.firstOrNull { it.startsWith("image/") }

        if (uri != null && mime != null && mime.startsWith("image/")) {
            // 跳过我们自己通过 writeClipboardImage 写入的远端图片 URI，防止死循环回声
            if (uri.authority == "$packageName.files") return
            if (prefs.clipImages) {
                emitLocalClipImage(uri, mime, mode.name.lowercase(Locale.ROOT))
            }
            return
        }

        val text = item.text?.toString() ?: item.htmlText
        if (text.isNullOrEmpty()) return
        emitLocalClipText(text, mode.name.lowercase(Locale.ROOT))
    }

    private fun emitLocalClipText(text: String, source: String) {
        if (!prefs.clipPush || text.isEmpty()) return
        if (SyncHubEngineHost.shouldSuppressLocalText(text)) return
        SyncHubEngineHost.emitEvent(
            mapOf(
                "type" to "clipboard_text",
                "text" to text,
                "source" to source,
            ),
        )
    }

    private fun emitLocalClipImage(uri: Uri, mime: String, source: String) {
        if (clipExecutor.isShutdown) return
        runCatching {
            clipExecutor.execute {
                try {
                    val bytes = contentResolver.openInputStream(uri)?.use { s ->
                        val buf = s.readBytes()
                        if (buf.size > MAX_CLIP_IMAGE_BYTES) null else buf
                    } ?: return@execute
                    if (bytes.isEmpty() || SyncHubEngineHost.shouldSuppressLocalImage(bytes)) return@execute

                    val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: "png"
                    val name = SyncHubEngineHost.newClipboardImageName(ext)
                    val outDir = File(cacheDir, "clip_out").apply { mkdirs() }
                    outDir.listFiles()?.forEach { runCatching { it.delete() } }
                    val staged = File(outDir, name).apply { writeBytes(bytes) }

                    SyncHubEngineHost.emitEvent(
                        mapOf(
                            "type" to "clipboard_image",
                            "bytes" to bytes,
                            "fileName" to name,
                            "path" to staged.absolutePath,
                            "mimeType" to mime,
                            "source" to source,
                        ),
                    )
                } catch (t: Throwable) {
                    L.w("读取剪贴板图片失败", t)
                }
            }
        }
    }

    private fun lsposedSelfTestFailed(why: String) {
        if (forceRoot || !selfTestFallbackInFlight.compareAndSet(false, true)) return
        Status.update { it.copy(systemHookVerified = false) }
        scope.launch {
            try {
                val hasRoot = RootShell.cachedRoot() == true || RootShell.probeRoot(timeoutSec = 8, force = true)
                if (hasRoot) {
                    prefs.rootGrantedOnce = true
                }
                if (prefs.useRootClipboard && hasRoot) {
                    forceRoot = true
                    L.w("LSPosed 模式自检未通过（$why，通常因模块刚启用未重启手机）→ 已自动切换到 Root 兼容模式")
                    safeRun("切换至 Root 兼容模式") { setupClipSource() }
                } else {
                    val now = System.currentTimeMillis()
                    if (now - lastNoFallbackLog > 60_000) {
                        lastNoFallbackLog = now
                        L.w(
                            "LSPosed 系统框架钩子尚未生效（$why）：若刚启用模块请重启手机；" +
                                "若使用 KernelSU/APatch/Magisk，请在管理器中授予 SyncHub 超级用户权限即可免重启自动兜底",
                        )
                    }
                }
            } finally {
                selfTestFallbackInFlight.set(false)
            }
        }
    }

    private fun goForeground(text: String?): Boolean = try {
        goForegroundInner(text)
        true
    } catch (t: Throwable) {
        L.w("无法进入前台服务（请将 SyncHub 电池策略设为“无限制/允许后台运行”）", t)
        false
    }

    private fun goForegroundInner(text: String?) {
        val st = Status.flow.value
        val content = text ?: buildString {
            append("剪贴板：").append(st.clipMode.label)
            if (prefs.autoReceive) append(" · 跨端实时传输运行中")
        }
        val stopPi = PendingIntent.getService(
            this,
            1,
            Intent(this, SyncService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = Notifs.builder(this, Notifs.CH_SYNC)
            .setContentTitle("SyncHub 同步中")
            .setContentText(content)
            .setOngoing(true)
            .setSilent(true)
            .addAction(0, "停止", stopPi)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(Notifs.ID_SYNC, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(Notifs.ID_SYNC, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        }
    }

    companion object {
        private const val MAX_CLIP_IMAGE_BYTES = 20 * 1024 * 1024

        const val ACTION_STOP = "xyz.synchub.android.STOP"
        const val ACTION_RELOAD = "xyz.synchub.android.RELOAD"
        const val EXTRA_REASON = "reason"

        @Volatile var instance: SyncService? = null
        @Volatile var appVisible: Boolean = false

        fun start(ctx: Context, action: String? = null, reason: String? = null) {
            NativePrefs.get(ctx).serviceEnabled = true
            val i = Intent(ctx, SyncService::class.java).setAction(action)
            reason?.let { i.putExtra(EXTRA_REASON, it) }
            try {
                ContextCompat.startForegroundService(ctx, i)
            } catch (e: Exception) {
                L.w("无法启动前台服务 (${reason ?: action ?: "手动"})", e)
            }
        }

        fun stop(ctx: Context) {
            L.i("停止同步服务")
            NativePrefs.get(ctx).serviceEnabled = false
            Watchdog.cancel(ctx)
            runCatching { ctx.stopService(Intent(ctx, SyncService::class.java)) }
        }
    }
}
