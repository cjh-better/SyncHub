package xyz.synchub.android.ui

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import xyz.synchub.android.sync.SyncService
import xyz.synchub.android.util.ClipMode
import xyz.synchub.android.util.Prefs
import xyz.synchub.android.util.Status

enum class Screen { Onboarding, Home, Settings, Logs, Received }

class MainActivity : ComponentActivity() {
    private var screen by mutableStateOf(Screen.Home)

    val notifPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val prefs = Prefs.get(this)
        screen = if (prefs.onboarded && prefs.configured) Screen.Home else Screen.Onboarding
        setContent {
            SyncHubTheme {
                when (screen) {
                    Screen.Onboarding -> OnboardingScreen(this, onDone = { screen = Screen.Home })
                    Screen.Home -> HomeScreen(this, onSettings = { screen = Screen.Settings }, onReceived = { screen = Screen.Received })
                    Screen.Received -> ReceivedScreen(this, onBack = { screen = Screen.Home })
                    Screen.Settings -> SettingsScreen(this, onBack = { screen = Screen.Home },
                        onLogs = { screen = Screen.Logs }, onRerunSetup = { screen = Screen.Onboarding })
                    Screen.Logs -> LogsScreen(onBack = { screen = Screen.Settings })
                }
            }
        }
    }

    @Deprecated("Deprecated in Java")
    @SuppressLint("MissingSuperCall")
    override fun onBackPressed() {
        when (screen) {
            Screen.Settings -> screen = Screen.Home
            Screen.Logs -> screen = Screen.Settings
            Screen.Received -> screen = Screen.Home
            else -> @Suppress("DEPRECATION") super.onBackPressed()
        }
    }

    override fun onPause() {
        SyncService.appVisible = false
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        SyncService.appVisible = true
        // 服务被系统 / “正在运行的应用”面板停掉但进程还在时，打开应用即恢复
        val p = Prefs.get(this)
        if (p.configured && p.serviceEnabled && SyncService.instance == null)
            SyncService.start(this, reason = "打开应用时发现服务未运行")
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // “仅前台”模式：应用获得焦点时读一次剪贴板并推送
        if (hasFocus && Status.flow.value.clipMode == ClipMode.FOREGROUND) SyncService.instance?.onForegroundFocus()
    }

    fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33) notifPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    fun isIgnoringBattery(): Boolean =
        getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)

    @SuppressLint("BatteryLife")
    fun requestIgnoreBattery() {
        runCatching {
            startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
        }.onFailure { runCatching { startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) } }
    }

    fun requestAllFilesAccess() {
        if (Build.VERSION.SDK_INT >= 30) runCatching {
            startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName")))
        }
    }
}
