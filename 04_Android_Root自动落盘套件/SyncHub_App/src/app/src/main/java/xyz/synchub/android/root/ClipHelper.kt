package xyz.synchub.android.root

import android.content.ClipData
import android.os.Binder
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.system.Os
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import java.util.Base64
import kotlin.system.exitProcess

/**
 * Root 兼容模式的剪贴板读取进程（不需要 LSPosed）。
 *
 * 由应用通过 `su` 启动：CLASSPATH=<本 APK> app_process /system/bin xyz.synchub.android.root.ClipHelper <userId>
 * 启动后降权为 shell (uid 2000)，以 com.android.shell 身份访问 IClipboard。
 * Android 10–15 的 ClipboardService.clipboardAccessAllowed 中，持有 READ_CLIPBOARD_IN_BACKGROUND
 * 的调用方（Shell 包）被允许在后台读取剪贴板（AOSP 注释："Shell can access the clipboard for testing purposes"）。
 *
 * 输出协议（stdout，一行一条）：
 *   READY <sdk> <mode>      mode = listener / poll
 *   BASE <base64>           启动时的当前剪贴板（作为基线，不推送）
 *   CLIP <base64>           剪贴板文本变化
 *   ERR <msg>
 * stdin 关闭（父进程退出）时自动退出。
 */
object ClipHelper {
    private const val SHELL_PKG = "com.android.shell"
    private const val LISTENER_DESC = "android.content.IOnPrimaryClipChangedListener"

    @JvmStatic
    fun main(args: Array<String>) {
        val userId = args.getOrNull(0)?.toIntOrNull() ?: 0
        try {
            if (Os.getuid() == 0) {
                Os.setgid(2000); Os.setuid(2000)
            }
        } catch (t: Throwable) {
            out("ERR setuid: $t")
        }
        // 父进程退出 → stdin EOF → 结束自身，避免残留
        Thread {
            try { while (System.`in`.read() >= 0) { } } catch (_: Throwable) { }
            exitProcess(0)
        }.apply { isDaemon = true }.start()

        try {
            Looper.prepareMainLooper()
            val handler = Handler(Looper.getMainLooper())
            val binder = Class.forName("android.os.ServiceManager")
                .getMethod("getService", String::class.java).invoke(null, "clipboard") as IBinder
            val clip = Class.forName("android.content.IClipboard\$Stub")
                .getMethod("asInterface", IBinder::class.java).invoke(null, binder)!!

            val getM = pick(clip.javaClass, "getPrimaryClip")
                ?: throw IllegalStateException("IClipboard.getPrimaryClip not found")

            fun read(): String? = try {
                val cd = getM.invoke(clip, *buildArgs(getM, userId, null)) as ClipData?
                if (cd == null || cd.itemCount == 0) null else {
                    val it = cd.getItemAt(0)
                    it.text?.toString() ?: it.htmlText
                }
            } catch (t: Throwable) {
                out("ERR read: ${t.cause ?: t}"); null
            }

            var last: String? = read()
            out("BASE " + b64(last ?: ""))

            val emit = Runnable {
                val now = read()
                if (now != null && now != last) {
                    last = now
                    out("CLIP " + b64(now))
                }
            }
            // 剪贴板变化回调里读到 null：通常是系统拒绝了 Shell 的后台读取，报告给应用写进日志（最多 5 次）
            var nullReports = 0
            val emitCb = Runnable {
                val now = read()
                if (now == null) {
                    if (nullReports++ < 5) out("ERR read-null after change (clipboard access denied or non-text clip)")
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
                            handler.post(emitCb); return true
                        }
                        return super.onTransact(code, data, reply, flags)
                    }
                }
                cb.attachInterface(null, LISTENER_DESC)
                val proxy = Proxy.newProxyInstance(ClipHelper::class.java.classLoader, arrayOf(listenerCls)) { _, m, _ ->
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
                addM.invoke(clip, *buildArgs(addM, userId, proxy))
                mode = "listener"
            } catch (t: Throwable) {
                out("ERR listener: ${t.cause ?: t}; fallback to polling")
            }
            // 兜底：即便监听成功也每 5 秒校验一次（部分 ROM 回调不可靠）；监听失败时 1 秒轮询
            val period = if (mode == "listener") 5000L else 1000L
            handler.postDelayed(object : Runnable {
                override fun run() { emit.run(); handler.postDelayed(this, period) }
            }, period)

            out("READY ${android.os.Build.VERSION.SDK_INT} $mode")
            Looper.loop()
        } catch (t: Throwable) {
            out("ERR fatal: $t")
            exitProcess(2)
        }
    }

    /** 选择参数最多的同名方法（新版本签名在旧签名基础上追加 attributionTag / deviceId）。 */
    private fun pick(cls: Class<*>, name: String): Method? =
        cls.methods.filter { it.name == name }.maxByOrNull { it.parameterTypes.size }

    /**
     * 通用参数构造：第一个 String = 调用包名，其余 String = null（attributionTag）；
     * 第一个 int = userId，其余 int = 0（deviceId = DEVICE_ID_DEFAULT）；接口参数 = listener。
     */
    private fun buildArgs(m: Method, userId: Int, listener: Any?): Array<Any?> {
        var strings = 0; var ints = 0
        return m.parameterTypes.map { t ->
            when {
                t == String::class.java -> if (strings++ == 0) SHELL_PKG else null
                t == Int::class.javaPrimitiveType -> if (ints++ == 0) userId else 0
                t == Boolean::class.javaPrimitiveType -> false
                t == Long::class.javaPrimitiveType -> 0L
                else -> listener
            }
        }.toTypedArray()
    }

    private fun b64(s: String) = Base64.getEncoder().encodeToString(s.toByteArray(Charsets.UTF_8))

    @Synchronized private fun out(line: String) {
        println(line); System.out.flush()
    }
}
