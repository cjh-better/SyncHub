package xyz.synchub.android.util

import android.content.Context
import android.content.SharedPreferences
import java.io.File
import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

/**
 * 原生服务运行策略配置（不存放敏感凭据；敏感凭据由 SecureStore 使用 Android Keystore 加密保存）。
 */
class NativePrefs private constructor(private val appCtx: Context) {
    private val p: SharedPreferences = appCtx.getSharedPreferences("synchub_native", Context.MODE_PRIVATE)

    var configuredFlag by bool("configured", false)
    var serviceEnabled by bool("service_enabled", true)
    var startOnBoot by bool("start_on_boot", true)
    var clipPush by bool("clip_push", true)
    var clipPull by bool("clip_pull", true)
    var clipImages by bool("clip_images", true)
    var useRootClipboard by bool("use_root_clipboard", true)
    var autoReceive by bool("auto_receive", true)
    var rootGrantedOnce by bool("root_granted_once", false)
    var rootSetupDone by bool("root_setup_done", false)

    var pollIntervalSec: Int
        get() = p.getInt("poll_interval_sec", 3)
        set(v) = p.edit().putInt("poll_interval_sec", v.coerceIn(1, 60)).apply()

    var saveSubdir: String
        get() = p.getString("save_subdir", "跨端传输") ?: "跨端传输"
        set(v) = p.edit().putString("save_subdir", v.trim().trim('/')).apply()

    var recvDir: String
        get() = p.getString("recv_dir", "") ?: ""
        set(v) = p.edit().putString("recv_dir", v.trim()).apply()

    var migratedLastHubId: Long
        get() = p.getLong("migrated_last_hub_id", 0L)
        set(v) = p.edit().putLong("migrated_last_hub_id", v).apply()

    /**
     * 判断设备是否已完成登录/配对：
     * 既检查 Dart 层通过 configureService/startService 写入的标记，也检查 Flutter 应用支持目录下的 config.json
     * 或 SecureStore 中是否已写入凭据，确保开机广播与看门狗在任何状态下都能准确判断。
     */
    val isConfigured: Boolean
        get() = configuredFlag ||
            File(appCtx.filesDir, "config.json").exists() ||
            SecureStore.hasAnyKey(appCtx)

    private fun bool(key: String, def: Boolean) = object : ReadWriteProperty<Any?, Boolean> {
        override fun getValue(thisRef: Any?, property: KProperty<*>): Boolean = p.getBoolean(key, def)
        override fun setValue(thisRef: Any?, property: KProperty<*>, value: Boolean) {
            p.edit().putBoolean(key, value).apply()
        }
    }

    companion object {
        @Volatile private var inst: NativePrefs? = null

        fun get(ctx: Context): NativePrefs = inst ?: synchronized(this) {
            inst ?: NativePrefs(ctx.applicationContext).also { inst = it }
        }
    }
}
