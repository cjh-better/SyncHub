package xyz.synchub.android.share

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import xyz.synchub.android.MainActivity
import xyz.synchub.android.SyncHubEngineHost
import java.util.concurrent.Executors

/**
 * 系统分享菜单入口（`ACTION_SEND` / `ACTION_SEND_MULTIPLE`）：
 * 将 `content://` URI 暂存到 `cacheDir/share/<ts>_<idx>/<displayName>`，
 * 向共享 [SyncHubEngineHost] 推送 `share_files` 或 `share_text` 事件，
 * 并拉起 [MainActivity]（`SINGLE_TOP | NEW_TASK`）供用户选择目标设备或由 Dart 自动发送。
 */
class ShareActivity : Activity() {
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransitionCompat()
        SyncHubEngineHost.ensureEngine(applicationContext)

        val uris = extractUris(intent)
        if (uris.isNotEmpty()) {
            val appCtx = applicationContext
            stageExecutor.execute {
                val staged = UriStager.stageAll(appCtx, uris)
                mainHandler.post {
                    if (staged.isEmpty()) {
                        Toast.makeText(appCtx, "无法读取分享的文件", Toast.LENGTH_SHORT).show()
                    } else {
                        SyncHubEngineHost.emitEvent(
                            mapOf(
                                "type" to "share_files",
                                "paths" to staged,
                                "source" to "share",
                            ),
                        )
                        launchMainUi()
                    }
                    finish()
                    overridePendingTransitionCompat()
                }
            }
            return
        }

        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            ?: intent.getStringExtra(Intent.EXTRA_SUBJECT)
        if (!text.isNullOrBlank()) {
            SyncHubEngineHost.emitEvent(
                mapOf(
                    "type" to "share_text",
                    "text" to text,
                    "source" to "share",
                ),
            )
            launchMainUi()
        } else {
            Toast.makeText(applicationContext, "没有可发送的内容", Toast.LENGTH_SHORT).show()
        }
        finish()
        overridePendingTransitionCompat()
    }

    private fun launchMainUi() {
        startActivity(
            Intent(this, MainActivity::class.java).addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP,
            ),
        )
    }

    private fun extractUris(i: Intent): List<Uri> {
        val uris = ArrayList<Uri>()
        when (i.action) {
            Intent.ACTION_SEND -> stream(i)?.let(uris::add)
            Intent.ACTION_SEND_MULTIPLE -> streams(i)?.let(uris::addAll)
        }
        if (uris.isEmpty()) {
            i.clipData?.let { cd ->
                for (idx in 0 until cd.itemCount) {
                    cd.getItemAt(idx).uri?.let(uris::add)
                }
            }
        }
        return uris
    }

    @Suppress("DEPRECATION")
    private fun stream(i: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            i.getParcelableExtra(Intent.EXTRA_STREAM)
        }

    @Suppress("DEPRECATION")
    private fun streams(i: Intent): List<Uri>? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            i.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            i.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
        }

    @Suppress("DEPRECATION")
    private fun overridePendingTransitionCompat() = overridePendingTransition(0, 0)

    companion object {
        private val stageExecutor = Executors.newSingleThreadExecutor()
    }
}
