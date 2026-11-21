package xyz.synchub.android.share

import android.app.Activity
import android.content.ClipboardManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import xyz.synchub.android.SyncHubEngineHost
import java.util.concurrent.Executors

/**
 * 快捷设置磁贴「发送剪贴板」启动的透明 Activity：
 * Android 10+ 仅允许获得窗口焦点的前台应用读取剪贴板，因此在 `onWindowFocusChanged(true)` 后读取，
 * 暂存文件/图片 URI 或读取文本，推送 `share_files` / `share_text`（`source = "tile"`）后立即关闭。
 */
class ClipSendActivity : Activity() {
    private var done = false
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransitionCompat()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || done) return
        done = true

        val appCtx = applicationContext
        SyncHubEngineHost.ensureEngine(appCtx)

        val clip = runCatching { getSystemService(ClipboardManager::class.java).primaryClip }.getOrNull()
        val item = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)
        if (item == null) {
            Toast.makeText(appCtx, "剪贴板为空", Toast.LENGTH_SHORT).show()
            finishQuietly()
            return
        }

        val uri = item.uri
        if (uri != null && item.text == null) {
            stageExecutor.execute {
                val staged = UriStager.stageAll(appCtx, listOf(uri))
                mainHandler.post {
                    if (staged.isEmpty()) {
                        Toast.makeText(appCtx, "无法读取剪贴板文件", Toast.LENGTH_SHORT).show()
                    } else {
                        SyncHubEngineHost.emitEvent(
                            mapOf(
                                "type" to "share_files",
                                "paths" to staged,
                                "source" to "tile",
                            ),
                        )
                        Toast.makeText(appCtx, "已通过 SyncHub 发送", Toast.LENGTH_SHORT).show()
                    }
                    finishQuietly()
                }
            }
            return
        }

        val text = runCatching { item.coerceToText(this)?.toString() }.getOrNull()
        if (text.isNullOrBlank()) {
            Toast.makeText(appCtx, "剪贴板为空", Toast.LENGTH_SHORT).show()
        } else {
            SyncHubEngineHost.emitEvent(
                mapOf(
                    "type" to "share_text",
                    "text" to text,
                    "source" to "tile",
                ),
            )
            Toast.makeText(appCtx, "已通过 SyncHub 发送", Toast.LENGTH_SHORT).show()
        }
        finishQuietly()
    }

    private fun finishQuietly() {
        finish()
        overridePendingTransitionCompat()
    }

    @Suppress("DEPRECATION")
    private fun overridePendingTransitionCompat() = overridePendingTransition(0, 0)

    companion object {
        private val stageExecutor = Executors.newSingleThreadExecutor()
    }
}
