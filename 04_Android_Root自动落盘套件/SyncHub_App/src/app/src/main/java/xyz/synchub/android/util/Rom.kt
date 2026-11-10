package xyz.synchub.android.util

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import java.util.Locale

object Rom {
    /** ColorOS / realme UI / OxygenOS：有单独的“剪贴板”应用权限，默认“仅在使用中允许”会拦截后台读写。 */
    val isOplus: Boolean by lazy {
        val s = setOf("oppo", "realme", "oneplus")
        Build.MANUFACTURER.lowercase(Locale.ROOT) in s || Build.BRAND.lowercase(Locale.ROOT) in s
    }

    const val CLIP_HINT = "realme / OPPO / OnePlus 手机：请到 设置 → 应用 → SyncHub → 权限 → 剪贴板，改为“始终允许”。" +
        "保持“仅在使用中允许”时，后台既读不到手机剪贴板，也写不进电脑发来的内容。"

    fun openAppDetails(ctx: Context) {
        runCatching {
            ctx.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + ctx.packageName))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }
}
