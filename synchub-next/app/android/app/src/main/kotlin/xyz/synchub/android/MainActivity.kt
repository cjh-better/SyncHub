package xyz.synchub.android

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import androidx.core.app.ActivityCompat
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import xyz.synchub.android.sync.SyncService
import xyz.synchub.android.util.ClipMode
import xyz.synchub.android.util.NativePrefs
import xyz.synchub.android.util.Status

class MainActivity : FlutterActivity() {
    private var notifCallback: ((Boolean) -> Unit)? = null
    private var notifRequestedAt = 0L

    override fun provideFlutterEngine(context: Context): FlutterEngine =
        SyncHubEngineHost.ensureEngine(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        current = this
        super.onCreate(savedInstanceState)
        runCatching {
            WindowCompat.getInsetsController(window, window.decorView).apply {
                isAppearanceLightStatusBars = true
                isAppearanceLightNavigationBars = true
            }
        }
    }

    override fun onResume() {
        super.onResume()
        current = this
        SyncService.appVisible = true
        val p = NativePrefs.get(this)
        if (p.isConfigured && p.serviceEnabled && SyncService.instance == null) {
            SyncService.start(this, reason = "打开应用恢复服务")
        }
    }

    override fun onPause() {
        SyncService.appVisible = false
        super.onPause()
    }

    override fun onDestroy() {
        if (current === this) current = null
        notifCallback?.invoke(SyncHubEngineHost.hasNotificationPermission(applicationContext))
        notifCallback = null
        super.onDestroy()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            SyncService.instance?.onForegroundFocus()
        }
    }

    fun requestNotificationPermission(onResult: (Boolean) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            SyncHubEngineHost.openNotificationSettings(this)
            onResult(SyncHubEngineHost.hasNotificationPermission(this))
            return
        }
        notifCallback?.invoke(SyncHubEngineHost.hasNotificationPermission(this))
        notifCallback = onResult
        notifRequestedAt = SystemClock.elapsedRealtime()
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            RC_POST_NOTIFICATIONS,
        )
    }

    fun requestLegacyStoragePermission() {
        ActivityCompat.requestPermissions(
            this,
            arrayOf(
                Manifest.permission.WRITE_EXTERNAL_STORAGE,
                Manifest.permission.READ_EXTERNAL_STORAGE,
            ),
            RC_LEGACY_STORAGE,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == RC_POST_NOTIFICATIONS) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED &&
                SyncHubEngineHost.hasNotificationPermission(this)
            val elapsed = SystemClock.elapsedRealtime() - notifRequestedAt
            if (!granted &&
                elapsed < 250L &&
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                !ActivityCompat.shouldShowRequestPermissionRationale(this, Manifest.permission.POST_NOTIFICATIONS)
            ) {
                SyncHubEngineHost.openNotificationSettings(this)
            }
            val cb = notifCallback
            notifCallback = null
            cb?.invoke(granted)
        }
    }

    companion object {
        private const val RC_POST_NOTIFICATIONS = 5001
        private const val RC_LEGACY_STORAGE = 5002

        @Volatile var current: MainActivity? = null
    }
}
