package xyz.synchub.android.share

import android.app.Activity
import android.content.ClipboardManager
import android.os.Bundle
import android.widget.Toast
import xyz.synchub.android.sync.TransferService
import xyz.synchub.android.util.Prefs

/**
 * 快捷设置磁贴「发送剪贴板」启动的透明 Activity：
 * Android 10+ 只有获得焦点的应用才能读剪贴板，所以等窗口获得焦点后再读取，然后立即关闭。
 * 文本 → 发送文本；图片 / 文件 URI → 作为文件上传到 SyncHub。
 */
class ClipSendActivity : Activity() {
    private var done = false

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || done) return
        done = true
        if (!Prefs.get(this).configured) {
            Toast.makeText(this, "请先打开 SyncHub 填写服务器账号", Toast.LENGTH_LONG).show(); finish(); return
        }
        val clip = getSystemService(ClipboardManager::class.java).primaryClip
        val item = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)
        when {
            item == null -> Toast.makeText(this, "剪贴板为空", Toast.LENGTH_SHORT).show()
            item.uri != null && item.text == null -> TransferService.upload(this, listOf(item.uri))
            else -> {
                val t = item.coerceToText(this)?.toString()
                if (t.isNullOrBlank()) Toast.makeText(this, "剪贴板为空", Toast.LENGTH_SHORT).show()
                else TransferService.sendText(this, t)
            }
        }
        finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransitionCompat()
    }

    @Suppress("DEPRECATION")
    private fun overridePendingTransitionCompat() = overridePendingTransition(0, 0)
}
