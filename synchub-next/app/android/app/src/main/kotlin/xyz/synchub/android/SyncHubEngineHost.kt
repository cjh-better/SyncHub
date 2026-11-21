package xyz.synchub.android

import android.Manifest
import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.os.PowerManager
import android.provider.OpenableColumns
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import xyz.synchub.android.root.HookCheck
import xyz.synchub.android.root.RootClipboardBridge
import xyz.synchub.android.root.RootSetup
import xyz.synchub.android.root.RootShell
import xyz.synchub.android.share.UriStager
import xyz.synchub.android.sync.Notifs
import xyz.synchub.android.sync.SyncService
import xyz.synchub.android.sync.Watchdog
import xyz.synchub.android.util.FileOpener
import xyz.synchub.android.util.Hashing
import xyz.synchub.android.util.L
import xyz.synchub.android.util.NativePrefs
import xyz.synchub.android.util.Rom
import xyz.synchub.android.util.SecureStore
import xyz.synchub.android.util.Status
import xyz.synchub.android.xposed.ModuleStatus
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger

/**
 * 进程级共享 FlutterEngine 宿主：
 * 无论由 MainActivity、SyncService（含开机自启）、ShareActivity、ProcessTextActivity 还是 ClipSendActivity 唤起，
 * 始终复用同一个单实例 FlutterEngine，保证后台 WebSocket / 局域网直连 / 剪贴板同步持续在线。
 */
object SyncHubEngineHost {
    const val ENGINE_ID = "synchub_shared_engine"
    private val clipboardImageSeq = AtomicInteger(0)

    /** Same-second screenshots stay distinct. The counter is not truncated. */
    fun newClipboardImageName(ext: String, now: Date = Date()): String {
        val stamp = SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.US).format(now)
        val seq = clipboardImageSeq.incrementAndGet().toString().padStart(4, '0')
        val clean = ext.trim().trimStart('.').ifEmpty { "png" }
        return "IMG_${stamp}_$seq.$clean"
    }
    private const val MAX_EVENT_BUFFER = 64
    private const val MAX_CLIP_IMAGE_BYTES = 20 * 1024 * 1024

    private val mainHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile private var engine: FlutterEngine? = null
    private var eventSink: EventChannel.EventSink? = null
    private val pendingEvents = ArrayDeque<Map<String, Any?>>(MAX_EVENT_BUFFER)

    @Volatile private var lastSelfWrittenTextHash: String? = null
    @Volatile private var lastEmittedTextHash: String? = null
    @Volatile private var lastEmittedImageHash: String? = null
    @Volatile private var writeWarned = false

    @Volatile private var clipboardChangeCount: Int = 1

    fun incrementClipboardChangeCount() {
        clipboardChangeCount++
    }

    private var wakeLock: PowerManager.WakeLock? = null
    @Volatile private var wakeLockAcquiredAt = 0L

    @Synchronized
    fun acquireWakeLock(appCtx: Context, timeoutMs: Long = 10 * 60 * 1000L): Boolean {
        try {
            if (wakeLock == null) {
                val pm = appCtx.getSystemService(PowerManager::class.java)
                wakeLock = pm?.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "SyncHub::FileTransferWakeLock"
                )?.apply {
                    setReferenceCounted(false)
                }
            }
            wakeLock?.let { wl ->
                if (!wl.isHeld) {
                    wl.acquire(timeoutMs)
                    wakeLockAcquiredAt = System.currentTimeMillis()
                    L.i("WakeLock acquired for file transfer (timeout=${timeoutMs}ms)")
                }
            }
            return true
        } catch (t: Throwable) {
            L.w("Failed to acquire WakeLock", t)
            return false
        }
    }

    @Synchronized
    fun releaseWakeLock(): Boolean {
        try {
            wakeLock?.let { wl ->
                if (wl.isHeld) {
                    wl.release()
                    L.i("WakeLock released (held for ${System.currentTimeMillis() - wakeLockAcquiredAt}ms)")
                }
            }
            wakeLockAcquiredAt = 0L
            return true
        } catch (t: Throwable) {
            L.w("Failed to release WakeLock", t)
            return false
        }
    }

    fun isWakeLockHeld(): Boolean = wakeLock?.isHeld == true

    fun currentEngine(): FlutterEngine? = engine

    fun ensureEngine(context: Context): FlutterEngine {
        engine?.let { return it }
        val appCtx = context.applicationContext
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return ensureEngineOnMain(appCtx)
        }
        var created: FlutterEngine? = null
        var failure: Throwable? = null
        val latch = CountDownLatch(1)
        mainHandler.post {
            try {
                created = ensureEngineOnMain(appCtx)
            } catch (t: Throwable) {
                failure = t
            } finally {
                latch.countDown()
            }
        }
        latch.await()
        failure?.let { throw it }
        return created!!
    }

    @Synchronized
    private fun ensureEngineOnMain(appCtx: Context): FlutterEngine {
        engine?.let { return it }
        L.init(appCtx.filesDir)
        Notifs.createChannels(appCtx)

        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            loader.startInitialization(appCtx)
            loader.ensureInitializationComplete(appCtx, null)
        }

        val eng = FlutterEngine(appCtx, null, true)
        runCatching { GeneratedPluginRegistrant.registerWith(eng) }
        registerChannels(appCtx, eng)

        if (!eng.dartExecutor.isExecutingDart) {
            eng.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault(),
            )
        }
        FlutterEngineCache.getInstance().put(ENGINE_ID, eng)
        engine = eng
        L.i("共享 FlutterEngine 已初始化并启动 Dart 入口")
        return eng
    }

    /** 发送原生事件到 EventChannel("synchub/events")；Dart 尚未监听时暂存至 64 条环形缓冲队列。 */
    fun emitEvent(event: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            deliverOrBufferMain(event)
        } else {
            mainHandler.post { deliverOrBufferMain(event) }
        }
    }

    private fun deliverOrBufferMain(event: Map<String, Any?>) {
        val sink = eventSink
        if (sink != null) {
            try {
                sink.success(event)
                return
            } catch (t: Throwable) {
                L.w("EventChannel 发送异常，转入环形缓冲队列", t)
                eventSink = null
            }
        }
        if (pendingEvents.size >= MAX_EVENT_BUFFER) {
            pendingEvents.removeFirst()
        }
        pendingEvents.addLast(event)
    }

    @Synchronized
    fun markSelfWrittenText(text: String) {
        val h = Hashing.textHash(text)
        lastSelfWrittenTextHash = h
        lastEmittedTextHash = h
    }

    /** 返回 true 表示该剪贴板文本是我们刚写入的回声或重复回调，无需再次推送给 Dart。 */
    @Synchronized
    fun shouldSuppressLocalText(text: String): Boolean {
        val h = Hashing.textHash(text)
        if (h == lastSelfWrittenTextHash) {
            return true
        }
        if (h == lastEmittedTextHash) {
            return true
        }
        lastSelfWrittenTextHash = null
        lastEmittedTextHash = h
        lastEmittedImageHash = null
        return false
    }

    @Synchronized
    fun shouldSuppressLocalImage(bytes: ByteArray): Boolean {
        val h = Hashing.sha256Hex(bytes)
        if (h == lastEmittedImageHash) {
            return true
        }
        lastEmittedImageHash = h
        lastEmittedTextHash = null
        lastSelfWrittenTextHash = null
        return false
    }

    private fun registerChannels(appCtx: Context, eng: FlutterEngine) {
        val messenger = eng.dartExecutor.binaryMessenger

        // 1) MethodChannel("synchub/secure")
        MethodChannel(messenger, "synchub/secure").setMethodCallHandler { call, result ->
            handleSecureCall(appCtx, call, result)
        }

        // 2) MethodChannel("synchub/storage") & MethodChannel("synchub/native")
        val nativeHandler = MethodChannel.MethodCallHandler { call, result ->
            handleNativeCall(appCtx, call, result)
        }
        MethodChannel(messenger, "synchub/storage").setMethodCallHandler(nativeHandler)
        MethodChannel(messenger, "synchub/native").setMethodCallHandler(nativeHandler)

        // 3) EventChannel("synchub/events")
        EventChannel(messenger, "synchub/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
                if (events != null) {
                    while (pendingEvents.isNotEmpty()) {
                        events.success(pendingEvents.removeFirst())
                    }
                }
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    private fun handleSecureCall(appCtx: Context, call: MethodCall, result: MethodChannel.Result) {
        val key = call.argument<String>("key")
        if (key.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "Missing 'key'", null)
            return
        }
        scope.launch {
            try {
                val res: Any? = when (call.method) {
                    "read" -> SecureStore.read(appCtx, key)
                    "write" -> {
                        val value = call.argument<String>("value")
                        val ok = SecureStore.write(appCtx, key, value)
                        if (ok && value != null) {
                            NativePrefs.get(appCtx).configuredFlag = true
                        }
                        ok
                    }
                    "delete" -> SecureStore.delete(appCtx, key)
                    else -> {
                        withContext(Dispatchers.Main) { result.notImplemented() }
                        return@launch
                    }
                }
                withContext(Dispatchers.Main) { result.success(res) }
            } catch (t: Throwable) {
                L.w("synchub/secure ${call.method} 失败", t)
                withContext(Dispatchers.Main) {
                    result.error("SECURE_ERROR", t.message ?: t.toString(), null)
                }
            }
        }
    }

    private fun handleNativeCall(appCtx: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasAllFilesAccess" -> result.success(hasAllFilesAccess(appCtx))
            "requestAllFilesAccess" -> {
                requestAllFilesAccess(appCtx)
                result.success(true)
            }
            "hasNotificationPermission" -> result.success(hasNotificationPermission(appCtx))
            "requestNotificationPermission" -> requestNotificationPermission(appCtx, result)
            "isIgnoringBatteryOptimizations" -> result.success(isIgnoringBatteryOptimizations(appCtx))
            "requestIgnoreBatteryOptimizations" -> {
                requestIgnoreBatteryOptimizations(appCtx)
                result.success(true)
            }
            "openAppSettings" -> {
                openAppSettings(appCtx)
                result.success(true)
            }
            "getCapabilities" -> scope.launch {
                val caps = buildCapabilities(appCtx)
                withContext(Dispatchers.Main) { result.success(caps) }
            }
            "requestRoot" -> scope.launch {
                val ok = RootShell.requestRoot()
                if (ok) {
                    NativePrefs.get(appCtx).rootGrantedOnce = true
                    SyncService.instance?.requestReload()
                }
                withContext(Dispatchers.Main) { result.success(ok) }
            }
            "runRootSetup" -> {
                val hideToast = call.argument<Boolean>("hideClipboardToast") ?: true
                scope.launch {
                    val res = executeRootSetup(appCtx, hideToast)
                    withContext(Dispatchers.Main) { result.success(res) }
                }
            }
            "removeOldRootScript" -> scope.launch {
                val prefs = NativePrefs.get(appCtx)
                val res = if (!RootShell.isRootGranted()) {
                    mapOf("ok" to false, "detail" to "需要 Root 授权", "lastId" to null)
                } else {
                    prefs.rootGrantedOnce = true
                    val old = RootSetup.detectOldScript(prefs)
                    val step = RootSetup.removeOldScript(prefs, old)
                    mapOf(
                        "ok" to step.ok,
                        "name" to step.name,
                        "detail" to step.detail,
                        "lastId" to (old.lastId ?: prefs.migratedLastHubId.takeIf { it > 0L }),
                    )
                }
                withContext(Dispatchers.Main) { result.success(res) }
            }
            "configureService" -> {
                configureService(appCtx, call)
                result.success(true)
            }
            "startService" -> {
                val prefs = NativePrefs.get(appCtx)
                prefs.configuredFlag = true
                prefs.serviceEnabled = true
                val reason = call.argument<String>("reason") ?: "Dart startService"
                SyncService.start(appCtx, reason = reason)
                Watchdog.schedule(appCtx)
                result.success(true)
            }
            "stopService" -> {
                SyncService.stop(appCtx)
                result.success(true)
            }
            "getClipboardChangeCount" -> result.success(clipboardChangeCount)
            "acquireWakeLock" -> {
                val timeout = (call.argument<Number>("timeoutMs"))?.toLong() ?: (10 * 60 * 1000L)
                result.success(acquireWakeLock(appCtx, timeout))
            }
            "releaseWakeLock" -> result.success(releaseWakeLock())
            "isWakeLockHeld" -> result.success(isWakeLockHeld())
            "writeClipboardText" -> {
                val text = call.argument<String>("text") ?: (call.arguments as? String)
                if (text == null) {
                    result.success(false)
                } else {
                    val ok = writeClipboardTextOnMain(appCtx, text)
                    result.success(ok)
                }
            }
            "writeClipboardImage" -> {
                val bytes = call.argument<ByteArray>("bytes")
                val fileName = call.argument<String>("fileName") ?: "clipboard.png"
                if (bytes == null || bytes.isEmpty()) {
                    result.success(false)
                } else {
                    scope.launch {
                        val ok = writeClipboardImageAsync(appCtx, bytes, fileName)
                        withContext(Dispatchers.Main) { result.success(ok) }
                    }
                }
            }
            "readClipboardSnapshot" -> scope.launch {
                val snap = readClipboardSnapshotAsync(appCtx)
                withContext(Dispatchers.Main) { result.success(snap) }
            }
            "onFilesReceived" -> {
                val paths = (call.argument<List<*>>("paths"))
                    ?.mapNotNull { it?.toString() }
                    ?.filter { it.isNotBlank() }
                    .orEmpty()
                val title = call.argument<String>("title").orEmpty()
                val from = call.argument<String>("from").orEmpty()
                val normalized = paths.map { FileOpener.normalize(it).absolutePath }
                if (normalized.isNotEmpty()) {
                    runCatching {
                        MediaScannerConnection.scanFile(appCtx, normalized.toTypedArray(), null, null)
                    }
                }
                Notifs.filesReceived(appCtx, normalized, title, from)
                result.success(true)
            }
            "openFile" -> {
                val path = call.argument<String>("path") ?: (call.arguments as? String)
                if (path.isNullOrBlank()) {
                    result.success(false)
                } else {
                    val f = FileOpener.normalize(path)
                    val ok = if (f.isDirectory) {
                        FileOpener.openFolderInSystem(MainActivity.current ?: appCtx, f)
                    } else {
                        FileOpener.open(MainActivity.current ?: appCtx, f) == FileOpener.Result.OPENED
                    }
                    result.success(ok)
                }
            }
            "getLogs" -> result.success(L.lines())
            else -> result.notImplemented()
        }
    }

    fun hasAllFilesAccess(ctx: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(
                ctx,
                Manifest.permission.WRITE_EXTERNAL_STORAGE,
            ) == PackageManager.PERMISSION_GRANTED
        }

    private fun requestAllFilesAccess(appCtx: Context) {
        val host = MainActivity.current ?: appCtx
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            if (!Environment.isExternalStorageManager()) {
                val pkgIntent = Intent(
                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:${appCtx.packageName}"),
                ).apply {
                    if (host !is android.app.Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                try {
                    host.startActivity(pkgIntent)
                } catch (_: Exception) {
                    val fallback = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION).apply {
                        if (host !is android.app.Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    runCatching { host.startActivity(fallback) }
                }
            }
        } else {
            val act = MainActivity.current
            if (act != null) {
                act.requestLegacyStoragePermission()
            } else {
                openAppSettings(appCtx)
            }
        }
    }

    fun hasNotificationPermission(ctx: Context): Boolean {
        val enabled = NotificationManagerCompat.from(ctx).areNotificationsEnabled()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            enabled && ContextCompat.checkSelfPermission(
                ctx,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            enabled
        }
    }

    private fun requestNotificationPermission(appCtx: Context, result: MethodChannel.Result) {
        if (hasNotificationPermission(appCtx)) {
            result.success(true)
            return
        }
        val act = MainActivity.current
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && act != null) {
            act.requestNotificationPermission { granted ->
                result.success(granted)
            }
            return
        }
        openNotificationSettings(appCtx)
        result.success(false)
    }

    fun openNotificationSettings(ctx: Context) {
        val host = MainActivity.current ?: ctx
        val i = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, ctx.packageName)
            .apply {
                if (host !is android.app.Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        runCatching { host.startActivity(i) }.onFailure { openAppSettings(ctx) }
    }

    fun isIgnoringBatteryOptimizations(ctx: Context): Boolean =
        ctx.getSystemService(PowerManager::class.java)
            .isIgnoringBatteryOptimizations(ctx.packageName)

    @SuppressLint("BatteryLife")
    private fun requestIgnoreBatteryOptimizations(appCtx: Context) {
        if (isIgnoringBatteryOptimizations(appCtx)) return
        val host = MainActivity.current ?: appCtx
        val direct = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:${appCtx.packageName}"),
        ).apply {
            if (host !is android.app.Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        runCatching { host.startActivity(direct) }.onFailure {
            val list = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                if (host !is android.app.Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            runCatching { host.startActivity(list) }
        }
    }

    private fun openAppSettings(appCtx: Context) {
        val host = MainActivity.current ?: appCtx
        val i = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:${appCtx.packageName}"),
        ).apply {
            if (host !is android.app.Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        runCatching { host.startActivity(i) }
    }

    private fun buildCapabilities(appCtx: Context): Map<String, Any?> {
        val prefs = NativePrefs.get(appCtx)
        val lsposedActive = ModuleStatus.isActive()
        val suPresent = RootShell.suExists()
        val probedRoot = RootShell.cachedRoot() == true || RootShell.probeRoot(timeoutSec = 5)
        if (probedRoot && !prefs.rootGrantedOnce) {
            prefs.rootGrantedOnce = true
            SyncService.instance?.requestReload()
        }
        val rootGranted: Boolean? = if (probedRoot) true else (if (suPresent || prefs.rootGrantedOnce) false else null)
        val hookResult = if (lsposedActive && rootGranted == true) {
            HookCheck.check()
        } else if (lsposedActive) {
            val verified = Status.flow.value.systemHookVerified
            when (verified) {
                true -> HookCheck.Result(HookCheck.State.ACTIVE, "后台剪贴板回调校验通过")
                false -> HookCheck.Result(
                    HookCheck.State.NO_MARKER,
                    "应用层已激活，但系统框架钩子尚未生效（请确认勾选“系统框架”并重启手机，或开启 Root 授权免重启兜底）",
                )
                null -> HookCheck.Result(
                    HookCheck.State.UNKNOWN,
                    "应用层已激活；若刚启用模块请重启手机使系统框架钩子生效",
                )
            }
        } else {
            HookCheck.Result(HookCheck.State.UNKNOWN, if (rootGranted == true) "lsposed inactive" else "no root")
        }
        val oldScript = if (rootGranted == true) {
            runCatching { RootSetup.detectOldScript(prefs) }.getOrNull()
        } else {
            null
        }
        val st = Status.flow.value
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "release" to Build.VERSION.RELEASE,
            "manufacturer" to Build.MANUFACTURER,
            "brand" to Build.BRAND,
            "model" to Build.MODEL,
            "isOplus" to Rom.isOplus,
            "clipHint" to if (Rom.isOplus) Rom.CLIP_HINT else null,
            "lsposedActive" to lsposedActive,
            "lsposedVersion" to ModuleStatus.frameworkVersion(),
            "systemHookState" to hookResult.state.name,
            "systemHookLabel" to hookResult.state.label,
            "systemHookDetail" to hookResult.detail,
            "systemHookVerified" to st.systemHookVerified,
            "suPresent" to suPresent,
            "rootGranted" to (rootGranted == true),
            "rootKnown" to (rootGranted != null),
            "rootHelperAlive" to st.rootHelperAlive,
            "clipMode" to st.clipMode.name.lowercase(Locale.ROOT),
            "clipModeLabel" to st.clipMode.label,
            "serviceRunning" to (SyncService.instance != null),
            "serviceEnabled" to prefs.serviceEnabled,
            "startOnBoot" to prefs.startOnBoot,
            "clipPush" to prefs.clipPush,
            "clipPull" to prefs.clipPull,
            "clipImages" to prefs.clipImages,
            "useRootClipboard" to prefs.useRootClipboard,
            "hasAllFilesAccess" to hasAllFilesAccess(appCtx),
            "hasNotificationPermission" to hasNotificationPermission(appCtx),
            "isIgnoringBatteryOptimizations" to isIgnoringBatteryOptimizations(appCtx),
            "canInstallApks" to FileOpener.canInstallApks(appCtx),
            "oldRootScriptPresent" to (oldScript?.present ?: false),
            "oldRootScriptRunning" to (oldScript?.running ?: false),
            "oldRootScriptFiles" to (oldScript?.files ?: emptyList<String>()),
            "oldRootScriptLastId" to oldScript?.lastId,
            "migratedLastHubId" to prefs.migratedLastHubId.takeIf { it > 0L },
        )
    }

    private fun executeRootSetup(appCtx: Context, hideClipboardToast: Boolean): Map<String, Any?> {
        val prefs = NativePrefs.get(appCtx)
        val granted = RootShell.requestRoot()
        if (!granted) {
            return mapOf(
                "ok" to false,
                "rootGranted" to false,
                "steps" to emptyList<Map<String, Any?>>(),
                "oldScriptPresent" to false,
                "oldScriptRunning" to false,
                "oldScriptFiles" to emptyList<String>(),
                "oldScriptLastId" to null,
            )
        }
        prefs.rootGrantedOnce = true
        val effectiveHideToast = hideClipboardToast && !ModuleStatus.isActive()
        val steps = RootSetup.run(appCtx, effectiveHideToast)
        prefs.rootSetupDone = true
        val old = RootSetup.detectOldScript(prefs)
        SyncService.instance?.requestReload()
        return mapOf(
            "ok" to steps.all { it.ok },
            "rootGranted" to true,
            "steps" to steps.map {
                mapOf("name" to it.name, "ok" to it.ok, "detail" to it.detail)
            },
            "oldScriptPresent" to old.present,
            "oldScriptRunning" to old.running,
            "oldScriptFiles" to old.files,
            "oldScriptLastId" to old.lastId,
        )
    }

    private fun configureService(appCtx: Context, call: MethodCall) {
        val prefs = NativePrefs.get(appCtx)
        val args = call.arguments as? Map<*, *>
        if (args != null) {
            (args["configured"] as? Boolean)?.let { prefs.configuredFlag = it }
            (args["startOnBoot"] as? Boolean)?.let { prefs.startOnBoot = it }
            (args["clipPush"] as? Boolean)?.let { prefs.clipPush = it }
            (args["clipPull"] as? Boolean)?.let { prefs.clipPull = it }
            (args["clipImages"] as? Boolean)?.let { prefs.clipImages = it }
            (args["useRootClipboard"] as? Boolean)?.let { prefs.useRootClipboard = it }
            (args["autoReceive"] as? Boolean)?.let { prefs.autoReceive = it }
            (args["pollIntervalSec"] as? Number)?.let { prefs.pollIntervalSec = it.toInt() }
            (args["saveSubdir"] as? String)?.let { prefs.saveSubdir = it }
            (args["recvDir"] as? String)?.let { prefs.recvDir = it }
            val enabled = (args["serviceEnabled"] as? Boolean) ?: (args["enabled"] as? Boolean)
            if (enabled != null) {
                prefs.serviceEnabled = enabled
                if (enabled) {
                    prefs.configuredFlag = true
                    if (SyncService.instance == null) {
                        SyncService.start(appCtx, reason = "configureService")
                    } else {
                        SyncService.instance?.requestReload()
                    }
                    Watchdog.schedule(appCtx)
                    return
                } else {
                    SyncService.stop(appCtx)
                    return
                }
            }
        }
        SyncService.instance?.requestReload()
    }

    private fun remoteClip(clip: ClipData): ClipData {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            clip.description.extras = PersistableBundle().apply {
                putBoolean(ClipDescription.EXTRA_IS_REMOTE_DEVICE, true)
            }
        }
        return clip
    }

    private fun writeClipboardTextOnMain(appCtx: Context, text: String): Boolean {
        return try {
            val cm = appCtx.getSystemService(ClipboardManager::class.java)
            val prevHash = runCatching {
                cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()
            }.getOrNull()?.let(Hashing::textHash)
            val targetHash = Hashing.textHash(text)
            markSelfWrittenText(text)

            // 后台状态下若 Root 剪贴板守护在线，优先通过 com.android.shell (uid 2000) 同步写入，绕过 ColorOS/RealmeUI 后台拦截
            val wroteViaRootBridge = if (!SyncService.appVisible) {
                SyncService.instance?.writeClipboardViaRoot(text) == true
            } else {
                false
            }
            runCatching {
                cm.setPrimaryClip(remoteClip(ClipData.newPlainText("SyncHub", text)))
            }.onFailure { err ->
                if (!wroteViaRootBridge) throw err
            }
            verifyClipboardWriteAsync(appCtx, text, targetHash, prevHash, wroteViaRootBridge)
            true
        } catch (t: Throwable) {
            // 若普通 API 抛异常但拥有 Root，则尝试单次 Root 补偿写入
            if (RootClipboardBridge.writeOnceViaRoot(appCtx, text)) {
                L.i("普通剪贴板写入受限，已通过单次 Root 通道成功写入 (${text.length} 字)")
                return true
            }
            L.w("写入剪贴板文本失败", t)
            if (!writeWarned) {
                writeWarned = true
                Notifs.clipBlocked(appCtx, Rom.isOplus)
            }
            false
        }
    }

    private fun verifyClipboardWriteAsync(
        appCtx: Context,
        text: String,
        targetHash: String,
        prevHash: String?,
        wroteViaRootBridge: Boolean,
    ) {
        scope.launch {
            delay(800)
            if (wroteViaRootBridge) {
                if (writeWarned) {
                    writeWarned = false
                    Notifs.cancelClipBlocked(appCtx)
                }
                return@launch
            }
            val cm = appCtx.getSystemService(ClipboardManager::class.java)
            val readBackHash = withContext(Dispatchers.Main) {
                runCatching {
                    cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()
                }.getOrNull()?.let(Hashing::textHash)
            }
            val rootHash = SyncService.instance?.latestRootHash()
            if (readBackHash == targetHash || rootHash == targetHash) {
                if (writeWarned) {
                    writeWarned = false
                    Notifs.cancelClipBlocked(appCtx)
                }
            } else if (!SyncService.appVisible) {
                // 系统静默丢弃了后台 setPrimaryClip（常见于 ColorOS/RealmeUI），自动尝试 Root 补偿写入
                if (SyncService.instance?.writeClipboardViaRoot(text) == true ||
                    RootClipboardBridge.writeOnceViaRoot(appCtx, text)
                ) {
                    L.i("检测到后台剪贴板写入被系统拦截，已自动通过 Root 通道补偿写入 (${text.length} 字)")
                    if (writeWarned) {
                        writeWarned = false
                        Notifs.cancelClipBlocked(appCtx)
                    }
                    return@launch
                }
                if (prevHash != null && readBackHash == prevHash) {
                    L.w("剪贴板后台写入疑似被系统拦截（仍为旧内容）")
                    if (!writeWarned) {
                        writeWarned = true
                        Notifs.clipBlocked(appCtx, Rom.isOplus)
                    }
                }
            }
        }
    }

    private suspend fun writeClipboardImageAsync(appCtx: Context, bytes: ByteArray, rawFileName: String): Boolean {
        return try {
            val safeName = UriStager.sanitizeFileName(rawFileName).ifEmpty { "clipboard.png" }
            val dir = File(appCtx.cacheDir, "clip").apply { mkdirs() }
            dir.listFiles()?.forEach { if (it.name != safeName) runCatching { it.delete() } }
            val f = File(dir, safeName).apply { writeBytes(bytes) }
            val uri = FileProvider.getUriForFile(appCtx, "${appCtx.packageName}.files", f)
            withContext(Dispatchers.Main) {
                val cm = appCtx.getSystemService(ClipboardManager::class.java)
                cm.setPrimaryClip(remoteClip(ClipData.newUri(appCtx.contentResolver, "SyncHub", uri)))
            }
            true
        } catch (t: Throwable) {
            L.w("写入剪贴板图片失败", t)
            false
        }
    }

    private suspend fun readClipboardSnapshotAsync(appCtx: Context): Map<String, Any?>? {
        val clip = withContext(Dispatchers.Main) {
            runCatching { appCtx.getSystemService(ClipboardManager::class.java).primaryClip }.getOrNull()
        }
        if (clip != null && clip.itemCount > 0) {
            val item = clip.getItemAt(0)
            val desc = clip.description
            val uri = item.uri
            val mime = uri?.let { runCatching { appCtx.contentResolver.getType(it) }.getOrNull() }
                ?: (0 until desc.mimeTypeCount).map { desc.getMimeType(it) }.firstOrNull { it.startsWith("image/") }

            if (uri != null && mime != null && mime.startsWith("image/")) {
                val bytes = runCatching {
                    appCtx.contentResolver.openInputStream(uri)?.use { s ->
                        val buf = s.readBytes()
                        if (buf.size > MAX_CLIP_IMAGE_BYTES) null else buf
                    }
                }.getOrNull()
                if (bytes != null && bytes.isNotEmpty()) {
                    val fileName = queryUriDisplayName(appCtx, uri, mime)
                    return mapOf(
                        "kind" to "image",
                        "bytes" to bytes,
                        "fileName" to fileName,
                        "mimeType" to mime,
                    )
                }
            }

            val text = withContext(Dispatchers.Main) {
                item.text?.toString()
                    ?: item.htmlText
                    ?: runCatching { item.coerceToText(appCtx)?.toString() }.getOrNull()
            }
            if (!text.isNullOrEmpty()) {
                return mapOf(
                    "kind" to "text",
                    "text" to text,
                )
            }
        }

        // 若当前在后台无 LSPosed，但 Root 剪贴板进程已捕获最新文本，则用其兜底
        val rootText = SyncService.instance?.latestRootText()
        if (!rootText.isNullOrEmpty()) {
            return mapOf(
                "kind" to "text",
                "text" to rootText,
            )
        }
        return null
    }

    private fun queryUriDisplayName(ctx: Context, uri: Uri, mime: String): String {
        var name: String? = null
        runCatching {
            ctx.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst() && !c.isNull(0)) name = c.getString(0)
            }
        }
        val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: "png"
        val fallback = newClipboardImageName(ext)
        val safe = UriStager.sanitizeFileName(name.orEmpty())
        return when {
            safe.isEmpty() -> fallback
            !safe.contains('.') -> "$safe.$ext"
            else -> safe
        }
    }
}
