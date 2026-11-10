package xyz.synchub.android.util

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import xyz.synchub.android.net.ServerConfig
import xyz.synchub.android.sync.SyncStateStore

/**
 * 普通设置放在 settings.xml；账号密码放在 EncryptedSharedPreferences（AES256-GCM，密钥在 Android Keystore）。
 * 不在代码里硬编码任何账号。
 */
class Prefs private constructor(ctx: Context) : SyncStateStore {
    private val p: SharedPreferences = ctx.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private val secure: SharedPreferences? = openSecure(ctx)

    val secureAvailable get() = secure != null

    var serverUrl: String
        get() = p.getString("server_url", DEFAULT_SERVER) ?: DEFAULT_SERVER
        set(v) = p.edit().putString("server_url", v.trim().trimEnd('/')).apply()
    var username: String
        get() = secure?.getString("username", "") ?: ""
        set(v) { secure?.edit()?.putString("username", v)?.apply() }
    var password: String
        get() = secure?.getString("password", "") ?: ""
        set(v) { secure?.edit()?.putString("password", v)?.apply() }

    var deviceName: String
        get() = p.getString("device_name", "Android") ?: "Android"
        set(v) = p.edit().putString("device_name", v.ifBlank { "Android" }).apply()

    var pollIntervalSec: Int
        get() = p.getInt("poll_interval", 3)
        set(v) = p.edit().putInt("poll_interval", v.coerceIn(1, 60)).apply()
    var clipPush by bool("clip_push", true)
    var clipPull by bool("clip_pull", true)
    var clipImages by bool("clip_images", true)
    var autoReceive by bool("auto_receive", true)
    var startOnBoot by bool("start_on_boot", true)
    var serviceEnabled by bool("service_enabled", false)
    var useRootClipboard by bool("use_root_clipboard", true)
    var onboarded by bool("onboarded", false)
    var rootSetupDone by bool("root_setup_done", false)
    var saveSubdir: String
        get() = p.getString("save_subdir", "跨端传输") ?: "跨端传输"
        set(v) = p.edit().putString("save_subdir", v.trim().trim('/')).apply()

    override var lastRemoteKey: String?
        get() = p.getString("last_remote_key", null)
        set(v) = p.edit().putString("last_remote_key", v).apply()
    override var lastHubId: Long
        get() = p.getLong("last_hub_id", 0)
        set(v) = p.edit().putLong("last_hub_id", v).apply()

    fun server() = ServerConfig(serverUrl, username, password)
    val configured get() = serverUrl.isNotBlank() && username.isNotBlank()

    private fun bool(key: String, def: Boolean) = object : kotlin.properties.ReadWriteProperty<Any?, Boolean> {
        override fun getValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>) = p.getBoolean(key, def)
        override fun setValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>, value: Boolean) {
            p.edit().putBoolean(key, value).apply()
        }
    }

    companion object {
        const val DEFAULT_SERVER = "https://020814.xyz"
        @Volatile private var inst: Prefs? = null
        fun get(ctx: Context): Prefs = inst ?: synchronized(this) {
            inst ?: Prefs(ctx.applicationContext).also { inst = it }
        }

        private fun openSecure(ctx: Context): SharedPreferences? {
            fun create(): SharedPreferences {
                val key = MasterKey.Builder(ctx).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
                return EncryptedSharedPreferences.create(
                    ctx, "secure_account", key,
                    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
                )
            }
            return try { create() } catch (e: Exception) {
                Log.w("SyncHub", "EncryptedSharedPreferences 打开失败，重建", e)
                try {
                    ctx.deleteSharedPreferences("secure_account"); create()
                } catch (e2: Exception) { Log.e("SyncHub", "安全存储不可用", e2); null }
            }
        }
    }
}
