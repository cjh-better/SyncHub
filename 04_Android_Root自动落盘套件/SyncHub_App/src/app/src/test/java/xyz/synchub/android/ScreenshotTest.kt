package xyz.synchub.android

import android.graphics.Bitmap
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import xyz.synchub.android.net.HubItem
import xyz.synchub.android.net.hubOrder
import xyz.synchub.android.ui.HomeContent
import xyz.synchub.android.ui.MainActivity
import xyz.synchub.android.ui.SyncHubTheme
import xyz.synchub.android.util.ClipMode
import xyz.synchub.android.util.RuntimeStatus
import java.io.File

/** Robolectric 原生图形渲染截图（仅用于检查界面风格，非真机）。输出到 app/build/screenshots/。 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w393dp-h852dp-xxhdpi")
class ScreenshotTest {
    @get:Rule val compose = createAndroidComposeRule<androidx.activity.ComponentActivity>()

    private fun save(name: String) {
        compose.waitForIdle()
        shot(compose.activity.window.decorView, name)
    }

    @Test fun home() {
        val items = listOf(
            HubItem(9, 1, "", "2026Q4_项目周报.pdf", 2_400_000, "", "2026-11-09 23:41:10", false, true, null, "Windows", "文档", true, "/x"),
            HubItem(8, 0, "https://github.com/Jeric-X/SyncClipboard 开源剪贴板同步项目地址", "", 60, "", "2026-11-09 23:30:02", false, false, 3600, "Mac", "文本", false, null),
            HubItem(7, 2, "", "截图_2026-11-08.png", 380_000, "", "2026-11-09 21:02:44", true, false, null, "Android", "图片", true, "/y"),
            HubItem(6, 1, "", "素材合集.zip", 160_000_000, "", "2026-11-09 18:12:00", false, false, 9000, "Mac", "压缩包", true, "/z"),
        ).hubOrder()
        val st = RuntimeStatus(serviceRunning = true, connected = true, clipMode = ClipMode.ROOT, rootHelperAlive = true,
            lastPush = "会议纪要：周三下午 3 点评审 UI 改版方案", lastPull = "https://020814.xyz/hub/", lastReceived = "2026Q4_项目周报.pdf")
        compose.setContent {
            SyncHubTheme {
                HomeContent(st, items, null, false, true, false, "已授权", true, "https://020814.xyz", true,
                    "/storage/emulated/0/Download/跨端传输", {}, {}, {}, {},
                    storage = xyz.synchub.android.net.HubStorage(63_290_085_376, 11_433_066_496, 48_619_253_760, 262_000_000))
            }
        }
        save("home")
    }
}

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w393dp-h852dp-xxhdpi")
class OnboardingScreenshotTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun onboarding() {
        compose.waitForIdle()
        shot(compose.activity.window.decorView, "onboarding")
    }
}

internal fun shot(v: android.view.View, name: String) {
    val bmp = Bitmap.createBitmap(v.width, v.height, Bitmap.Config.ARGB_8888)
    v.draw(android.graphics.Canvas(bmp))
    val dir = File("build/screenshots").apply { mkdirs() }
    File(dir, "$name.png").outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
}
