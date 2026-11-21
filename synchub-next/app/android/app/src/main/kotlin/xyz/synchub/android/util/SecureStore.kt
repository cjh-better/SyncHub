package xyz.synchub.android.util

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 硬件级 Android Keystore AES-256-GCM 加密存储，供 MethodChannel("synchub/secure") 使用。
 * 密文存储在 SharedPreferences("synchub_secure") 中，格式为 `iv_b64:ct_b64`。
 */
object SecureStore {
    private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
    private const val KEY_ALIAS = "synchub_master_v1"
    private const val PREFS_NAME = "synchub_secure"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val GCM_TAG_BITS = 128

    private fun prefs(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    @Synchronized
    fun hasAnyKey(ctx: Context): Boolean = prefs(ctx).all.isNotEmpty()

    @Synchronized
    private fun getOrCreateKey(forceRecreate: Boolean = false): SecretKey {
        val ks = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
        if (forceRecreate && ks.containsAlias(KEY_ALIAS)) {
            runCatching { ks.deleteEntry(KEY_ALIAS) }
        }
        if (!forceRecreate && ks.containsAlias(KEY_ALIAS)) {
            val entry = ks.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
            if (entry != null) return entry.secretKey
            runCatching { ks.deleteEntry(KEY_ALIAS) }
        }
        val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build()
        kg.init(spec)
        return kg.generateKey()
    }

    @Synchronized
    fun read(ctx: Context, key: String): String? {
        if (key.isEmpty()) return null
        val p = prefs(ctx)
        val raw = p.getString(key, null) ?: return null
        val sep = raw.indexOf(':')
        if (sep <= 0 || sep >= raw.length - 1) return null
        return try {
            val iv = Base64.decode(raw.substring(0, sep), Base64.NO_WRAP)
            val ct = Base64.decode(raw.substring(sep + 1), Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
            String(cipher.doFinal(ct), Charsets.UTF_8)
        } catch (t: Throwable) {
            L.w("SecureStore 读取失败 ($key)，清理失效条目", t)
            p.edit().remove(key).commit()
            null
        }
    }

    @Synchronized
    fun write(ctx: Context, key: String, value: String?): Boolean {
        if (key.isEmpty()) return false
        val p = prefs(ctx)
        if (value == null) {
            return p.edit().remove(key).commit()
        }
        fun attempt(recreateKey: Boolean): Boolean {
            val secretKey = getOrCreateKey(forceRecreate = recreateKey)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, secretKey)
            val iv = cipher.iv
            val ct = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
            val encoded = Base64.encodeToString(iv, Base64.NO_WRAP) + ":" +
                Base64.encodeToString(ct, Base64.NO_WRAP)
            return p.edit().putString(key, encoded).commit()
        }
        return try {
            attempt(recreateKey = false)
        } catch (t: Throwable) {
            L.w("SecureStore 首次加密失败 ($key)，尝试重建密钥", t)
            try {
                p.edit().remove(key).commit()
                attempt(recreateKey = true)
            } catch (t2: Throwable) {
                L.w("SecureStore 写入彻底失败 ($key)", t2)
                false
            }
        }
    }

    @Synchronized
    fun deleteSingleKey(ctx: Context, key: String): Boolean {
        if (key.isEmpty()) return false
        return prefs(ctx).edit().remove(key).commit()
    }

    @Synchronized
    fun delete(ctx: Context, key: String): Boolean = deleteSingleKey(ctx, key)
}
