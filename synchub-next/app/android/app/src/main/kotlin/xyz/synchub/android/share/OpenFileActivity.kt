package xyz.synchub.android.share

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import xyz.synchub.android.MainActivity
import xyz.synchub.android.util.FileOpener
import java.io.File

/**
 * 接收文件通知点击入口：
 * 由 `PendingIntent.getActivity` 直接拉起（避免 Android 12+ 通知跳板限制），
 * 通过 `FileProvider`（`${applicationId}.files`）打开接收到的文件，并妥善引导 `.apk` 未知来源安装授权。
 */
class OpenFileActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransitionCompat()
        handle(intent)
        finish()
        overridePendingTransitionCompat()
    }

    private fun handle(i: Intent) {
        val rawPath = i.getStringExtra(EXTRA_PATH)
        val name = i.getStringExtra(EXTRA_NAME) ?: rawPath?.let { File(it).name }.orEmpty()
        val size = i.getLongExtra(EXTRA_SIZE, 0L)

        if (!rawPath.isNullOrBlank()) {
            val target = FileOpener.normalize(rawPath)
            if (target.isFile) {
                FileOpener.open(this, target)
                return
            }
            if (target.isDirectory) {
                if (!FileOpener.openFolderInSystem(this, target)) {
                    openMainApp()
                }
                return
            }
        }

        val fallback = FileOpener.findLocal(FileOpener.receiveDir(this), name, size)
        if (fallback != null) {
            FileOpener.open(this, fallback)
            return
        }

        Toast.makeText(
            applicationContext,
            if (name.isNotBlank()) "文件不存在：$name" else "文件不存在",
            Toast.LENGTH_SHORT,
        ).show()
    }

    private fun openMainApp() {
        startActivity(
            Intent(this, MainActivity::class.java).addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP,
            ),
        )
    }

    @Suppress("DEPRECATION")
    private fun overridePendingTransitionCompat() = overridePendingTransition(0, 0)

    companion object {
        const val EXTRA_PATH = "path"
        const val EXTRA_NAME = "name"
        const val EXTRA_SIZE = "size"

        fun forPath(ctx: Context, path: String, name: String? = null): Intent =
            Intent(ctx, OpenFileActivity::class.java)
                .putExtra(EXTRA_PATH, path)
                .putExtra(EXTRA_NAME, name ?: File(path).name)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
}
