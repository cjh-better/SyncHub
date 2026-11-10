package xyz.synchub.android.share

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import xyz.synchub.android.sync.TransferService
import xyz.synchub.android.util.Prefs

/** 文本选择浮动菜单「发送到 SyncHub」（ACTION_PROCESS_TEXT）。 */
class ProcessTextActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
        when {
            !Prefs.get(this).configured -> Toast.makeText(this, "请先打开 SyncHub 填写服务器账号", Toast.LENGTH_LONG).show()
            text.isNullOrBlank() -> Toast.makeText(this, "没有选中文本", Toast.LENGTH_SHORT).show()
            else -> TransferService.sendText(this, text)
        }
        finish()
    }
}
