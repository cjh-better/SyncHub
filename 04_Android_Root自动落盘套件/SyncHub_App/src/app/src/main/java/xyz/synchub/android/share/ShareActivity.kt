package xyz.synchub.android.share

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import xyz.synchub.android.sync.TransferService
import xyz.synchub.android.util.Prefs

/** 系统分享菜单「发送到 SyncHub」：文本、单个 / 多个文件或图片（无界面，交给 TransferService）。 */
class ShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!Prefs.get(this).configured) {
            Toast.makeText(this, "请先打开 SyncHub 填写服务器账号", Toast.LENGTH_LONG).show()
            finish(); return
        }
        val uris = ArrayList<Uri>()
        when (intent.action) {
            Intent.ACTION_SEND -> stream(intent)?.let(uris::add)
            Intent.ACTION_SEND_MULTIPLE -> streams(intent)?.let(uris::addAll)
        }
        if (uris.isEmpty()) {
            intent.clipData?.let { cd -> for (i in 0 until cd.itemCount) cd.getItemAt(i).uri?.let(uris::add) }
        }
        if (uris.isNotEmpty()) {
            TransferService.upload(this, uris)
            Toast.makeText(this, "开始发送 ${uris.size} 个文件", Toast.LENGTH_SHORT).show()
        } else {
            val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                ?: intent.getStringExtra(Intent.EXTRA_SUBJECT)
            if (!text.isNullOrBlank()) TransferService.sendText(this, text)
            else Toast.makeText(this, "没有可发送的内容", Toast.LENGTH_SHORT).show()
        }
        finish()
    }

    @Suppress("DEPRECATION")
    private fun stream(i: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else i.getParcelableExtra(Intent.EXTRA_STREAM)

    @Suppress("DEPRECATION")
    private fun streams(i: Intent): List<Uri>? =
        if (Build.VERSION.SDK_INT >= 33) i.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else i.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
}
