package xyz.synchub.android.share

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import xyz.synchub.android.SyncHubEngineHost

/**
 * 文本选择浮动菜单「发送到 SyncHub」（`ACTION_PROCESS_TEXT`）：
 * 无头唤起共享 [SyncHubEngineHost] 并推送 `share_text`（`source = "process_text"`），不打断用户当前应用。
 */
class ProcessTextActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransitionCompat()
        val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
        if (text.isNullOrBlank()) {
            Toast.makeText(applicationContext, "没有选中文本", Toast.LENGTH_SHORT).show()
        } else {
            SyncHubEngineHost.ensureEngine(applicationContext)
            SyncHubEngineHost.emitEvent(
                mapOf(
                    "type" to "share_text",
                    "text" to text,
                    "source" to "process_text",
                ),
            )
            Toast.makeText(applicationContext, "已通过 SyncHub 发送", Toast.LENGTH_SHORT).show()
        }
        finish()
        overridePendingTransitionCompat()
    }

    @Suppress("DEPRECATION")
    private fun overridePendingTransitionCompat() = overridePendingTransition(0, 0)
}
