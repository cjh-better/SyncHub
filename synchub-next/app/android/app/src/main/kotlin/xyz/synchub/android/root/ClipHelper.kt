package xyz.synchub.android.root

import android.content.ClipData
import android.content.ClipDescription
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.PersistableBundle
import android.system.Os
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import java.util.Base64
import kotlin.system.exitProcess

/**
 * Root 兼容模式的剪贴板读写守护进程（不需要 LSPosed）。
 *
 * 由应用通过 `su` 启动：
 *   1) 常驻模式：CLASSPATH=<本 APK> app_process /system/bin xyz.synchub.android.root.ClipHelper <userId>
 *   2) 单次写入：CLASSPATH=<本 APK> app_process /system/bin xyz.synchub.android.root.ClipHelper --set <userId> <base64>
 *
 * 启动后降权为 shell (uid 2000)，以 com.android.shell 身份访问 IClipboard。
 * Android 10–16（含 ColorOS / Realme UI / HyperOS / OneUI）中，com.android.shell 持有
 * READ_CLIPBOARD_IN_BACKGROUND 并在后台 setPrimaryClip 不受前台焦点拦截。
 *
 * 输出协议（stdout，一行一条）：
 *   READY <sdk> <mode>      mode = listener / poll
 *   BASE <base64>           启动时的当前剪贴板（作为基线，不推送）
 *   CLIP <base64>           剪贴板文本变化
 *   WROTE <len>             通过 stdin `SET <base64>` 成功写入系统剪贴板
 *   ERR <msg>
 * stdin 关闭（父进程退出）时自动退出，零孤儿进程残留。
 */
object ClipHelper {
    private const val SHELL_PKG = "com.android.shell"
    private const val LISTENER_DESC = "android.content.IOnPrimaryClipChangedListener"

    @JvmStatic
    @Suppress("DEPRECATION")
    fun main(args: Array<String>) {
        dropToShellUid()

        // 单次后台写入模式：ClipHelper --set <userId> <base64>
        if (args.getOrNull(0) == "--set") {
            val userId = args.getOrNull(1)?.toIntOrNull() ?: 0
            val b64Text = args.getOrNull(2).orEmpty()
            try {
                val text = String(Base64.getDecoder().decode(b64Text), Charsets.UTF_8)
                val (clipSvc, _, setM) = bindClipboard()
                writeClip(clipSvc, setM, userId, text)
                out("OK ${text.length}")
                exitProcess(0)
            } catch (t: Throwable) {
                out("ERR set: ${t.cause ?: t}")
                exitProcess(1)
            }
        }

        val userId = args.getOrNull(0)?.toIntOrNull() ?: 0

        try {
            Looper.prepareMainLooper()
            val handler = Handler(Looper.getMainLooper())
            val (clip, getM, setM) = bindClipboard()

            fun read(): String? = try {
                val cd = getM.invoke(clip, *buildArgs(getM, userId, null, null)) as ClipData?
                if (cd == null || cd.itemCount == 0) {
                    null
                } else {
                    val it = cd.getItemAt(0)
                    it.text?.toString() ?: it.htmlText
                }
            } catch (t: Throwable) {
                out("ERR read: ${t.cause ?: t}")
                null
            }

            var last: String? = read()
            out("BASE " + b64(last ?: ""))

            // 父进程 stdin 通道：支持实时 `SET <base64>` 后台写剪贴板；父进程退出 (EOF) -> 自动退出
            Thread({
                try {
                    System.`in`.bufferedReader(Charsets.UTF_8).forEachLine { raw ->
                        val line = raw.trim()
                        if (line.startsWith("SET ")) {
                            val payload = line.substring(4).trim()
                            val text = runCatching {
                                String(Base64.getDecoder().decode(payload), Charsets.UTF_8)
                            }.getOrNull()
                            if (text != null) {
                                handler.post {
                                    try {
                                        last = text
                                        writeClip(clip, setM, userId, text)
                                        out("WROTE ${text.length}")
                                    } catch (t: Throwable) {
                                        out("ERR set: ${t.cause ?: t}")
                                    }
                                }
                            }
                        }
                    }
                } catch (_: Throwable) {
                }
                exitProcess(0)
            }, "clip-helper-stdin").apply {
                isDaemon = true
                start()
            }

            val emit = Runnable {
                val now = read()
                if (now != null && now != last) {
                    last = now
                    out("CLIP " + b64(now))
                }
            }
            var nullReports = 0
            val emitCb = Runnable {
                val now = read()
                if (now == null) {
                    if (nullReports++ < 5) {
                        out("ERR read-null after change (clipboard access denied or non-text clip)")
                    }
                } else if (now != last) {
                    last = now
                    out("CLIP " + b64(now))
                }
            }

            var mode = "poll"
            try {
                val listenerCls = Class.forName(LISTENER_DESC)
                val cb = object : Binder() {
                    override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
                        if (code == IBinder.FIRST_CALL_TRANSACTION) {
                            handler.post(emitCb)
                            return true
                        }
                        return super.onTransact(code, data, reply, flags)
                    }
                }
                cb.attachInterface(null, LISTENER_DESC)
                val proxy = Proxy.newProxyInstance(
                    ClipHelper::class.java.classLoader,
                    arrayOf(listenerCls),
                ) { _, m, _ ->
                    when (m.name) {
                        "asBinder" -> cb
                        "hashCode" -> cb.hashCode()
                        "equals" -> false
                        "toString" -> "SyncHubClipListener"
                        else -> null
                    }
                }
                val addM = pick(clip.javaClass, "addPrimaryClipChangedListener")
                    ?: throw IllegalStateException("addPrimaryClipChangedListener not found")
                addM.invoke(clip, *buildArgs(addM, userId, null, proxy))
                mode = "listener"
            } catch (t: Throwable) {
                out("ERR listener: ${t.cause ?: t}; fallback to polling")
            }

            // 兜底：即便监听成功也每 5 秒校验一次（部分 ROM 回调不可靠）；监听失败时 1 秒轮询
            val period = if (mode == "listener") 5000L else 1000L
            handler.postDelayed(object : Runnable {
                override fun run() {
                    emit.run()
                    handler.postDelayed(this, period)
                }
            }, period)

            out("READY ${Build.VERSION.SDK_INT} $mode")
            Looper.loop()
        } catch (t: Throwable) {
            out("ERR fatal: $t")
            exitProcess(2)
        }
    }

    private fun dropToShellUid() {
        try {
            if (Os.getuid() == 0) {
                Os.setgid(2000)
                Os.setuid(2000)
            }
        } catch (t: Throwable) {
            out("ERR setuid: $t")
        }
    }

    private fun bindClipboard(): Triple<Any, Method, Method?> {
        val binder = Class.forName("android.os.ServiceManager")
            .getMethod("getService", String::class.java)
            .invoke(null, "clipboard") as IBinder
        val clip = Class.forName("android.content.IClipboard\$Stub")
            .getMethod("asInterface", IBinder::class.java)
            .invoke(null, binder)!!
        val getM = pick(clip.javaClass, "getPrimaryClip")
            ?: throw IllegalStateException("IClipboard.getPrimaryClip not found")
        val setM = pick(clip.javaClass, "setPrimaryClip")
        return Triple(clip, getM, setM)
    }

    private fun writeClip(clip: Any, setM: Method?, userId: Int, text: String) {
        val m = setM ?: throw IllegalStateException("IClipboard.setPrimaryClip not found")
        val cd = ClipData.newPlainText("SyncHub", text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            cd.description.extras = PersistableBundle().apply {
                putBoolean(ClipDescription.EXTRA_IS_REMOTE_DEVICE, true)
            }
        }
        m.invoke(clip, *buildArgs(m, userId, cd, null))
    }

    /** 选择参数最多的同名方法（新版本签名在旧签名基础上追加 attributionTag / deviceId）。 */
    private fun pick(cls: Class<*>, name: String): Method? =
        cls.methods.filter { it.name == name }.maxByOrNull { it.parameterTypes.size }

    private fun buildArgs(m: Method, userId: Int, clipData: ClipData?, listener: Any?): Array<Any?> {
        var strings = 0
        var ints = 0
        return m.parameterTypes.map { t ->
            when {
                t == ClipData::class.java || t.isAssignableFrom(ClipData::class.java) -> clipData
                t == String::class.java -> if (strings++ == 0) SHELL_PKG else null
                t == Int::class.javaPrimitiveType -> if (ints++ == 0) userId else 0
                t == Boolean::class.javaPrimitiveType -> false
                t == Long::class.javaPrimitiveType -> 0L
                else -> listener
            }
        }.toTypedArray()
    }

    private fun b64(s: String): String = Base64.getEncoder().encodeToString(s.toByteArray(Charsets.UTF_8))

    @Synchronized
    private fun out(line: String) {
        println(line)
        System.out.flush()
    }
}
