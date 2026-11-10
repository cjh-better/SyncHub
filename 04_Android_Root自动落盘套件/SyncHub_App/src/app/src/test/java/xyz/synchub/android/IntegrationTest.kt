package xyz.synchub.android

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runners.MethodSorters
import xyz.synchub.android.net.ApiException
import xyz.synchub.android.net.Hashing
import xyz.synchub.android.net.Http
import xyz.synchub.android.net.HubClient
import xyz.synchub.android.net.ServerConfig
import xyz.synchub.android.net.SyncClipboardClient
import xyz.synchub.android.sync.AutoReceiver
import xyz.synchub.android.sync.ClipSyncEngine
import xyz.synchub.android.sync.DirectFileSink
import xyz.synchub.android.sync.MemoryStateStore
import xyz.synchub.android.sync.RemoteChange
import java.io.ByteArrayOutputStream
import java.nio.file.Files
import kotlin.random.Random

/**
 * 针对本机测试环境（testenv/start_local.sh：SyncClipboard 官方服务器 v3.3.3 + synchub_server.py + 路由代理）。
 * 未设置 SYNCHUB_IT_URL 时跳过。绝不指向生产服务器。
 */
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class IntegrationTest {
    private lateinit var cfg: ServerConfig

    @Before fun setup() {
        val url = System.getenv("SYNCHUB_IT_URL")
        assumeTrue("SYNCHUB_IT_URL 未设置，跳过集成测试", !url.isNullOrEmpty())
        assumeTrue("禁止对生产服务器运行", !url!!.contains("020814"))
        cfg = ServerConfig(url, System.getenv("SYNCHUB_IT_USER") ?: "", System.getenv("SYNCHUB_IT_PASS") ?: "")
    }

    private fun uniq(prefix: String) = "$prefix-${System.nanoTime()}-${Random.nextInt(1000)}"

    @Test fun a_pushShortTextVisibleInHub() {
        val sc = SyncClipboardClient(cfg)
        val text = uniq("手机复制的文字 📋")
        val hash = sc.pushText(text)
        val p = sc.getProfile()
        assertEquals("Text", p.type); assertEquals(text, p.text); assertEquals(hash, p.hash.uppercase())
        // SyncClipboard 写入 history.db → SyncHub 列表可见
        val items = HubClient(cfg).listItems(20)
        assertTrue("hub 中应出现该文本", items.any { it.isText && it.text == text })
    }

    @Test fun b_longTextUsesTransferFile() {
        val sc = SyncClipboardClient(cfg)
        val text = uniq("L") + "长".repeat(12000)
        sc.pushText(text)
        val p = sc.getProfile()
        assertTrue(p.hasData); assertNotNull(p.dataName)
        assertEquals(text, sc.fetchFullText(p))
        assertEquals(Hashing.textHash(text), p.hash.uppercase())
    }

    @Test fun c_imageRoundTrip() {
        val sc = SyncClipboardClient(cfg)
        val png = javaClass.classLoader!!.getResourceAsStream("sample.png")?.readBytes() ?: Random.nextBytes(5000)
        val name = uniq("IMG") + ".png"
        val hash = sc.pushData("Image", name, png)
        val p = sc.getProfile()
        assertEquals("Image", p.type); assertEquals(name, p.dataName); assertEquals(hash, p.hash.uppercase())
        assertTrue(png.contentEquals(sc.getFile(name)))
    }

    @Test fun d_engineNoLoopAndCrossDevice() {
        val phone = ClipSyncEngine(SyncClipboardClient(cfg), MemoryStateStore())
        val pc = ClipSyncEngine(SyncClipboardClient(cfg), MemoryStateStore())
        assertNull(phone.pollRemote()); assertNull(pc.pollRemote())      // 首次只记录基线
        val text = uniq("from phone")
        assertTrue(phone.onLocalText(text))
        assertFalse("同一内容不应重复上传", phone.onLocalText(text))
        assertNull("自己推送的内容不应再写回", phone.pollRemote())
        val ch = pc.pollRemote()
        assertTrue(ch is RemoteChange.Text && ch.text == text)
        assertFalse("收到的内容写入本地剪贴板后再触发变化，不应回传", pc.onLocalText(text))
        assertNull(pc.pollRemote())
    }

    @Test fun d2_repeatOlderContentStillSyncs() {
        val phone = ClipSyncEngine(SyncClipboardClient(cfg), MemoryStateStore())
        val pc = ClipSyncEngine(SyncClipboardClient(cfg), MemoryStateStore())
        phone.pollRemote(); pc.pollRemote()
        val a = uniq("A"); val b = uniq("B")
        // 电脑 A → B → A：手机三次都应收到
        assertTrue(pc.onLocalText(a)); assertTrue((phone.pollRemote() as RemoteChange.Text).text == a)
        assertFalse("写入本地后回调不应回传", phone.onLocalText(a))
        assertTrue(pc.onLocalText(b)); assertTrue((phone.pollRemote() as RemoteChange.Text).text == b)
        assertFalse(phone.onLocalText(b))
        assertTrue("再次复制旧内容 A 应重新推送", pc.onLocalText(a))
        assertTrue("手机应再次收到 A", (phone.pollRemote() as RemoteChange.Text).text == a)
        assertFalse(phone.onLocalText(a))
        // 手机本地 B → A（之前出现过）也应推送
        assertTrue(phone.onLocalText(b)); assertTrue(phone.onLocalText(a))
        assertNull(phone.pollRemote())
    }

    @Test fun e_desktopStylePutIsPulled() {
        val phone = ClipSyncEngine(SyncClipboardClient(cfg), MemoryStateStore())
        phone.pollRemote()
        // 模拟 Windows/macOS 官方客户端的推送（原始 HTTP）
        val text = uniq("from windows")
        val body = """{"type":"Text","hash":"${Hashing.textHash(text)}","text":"$text","hasData":false}"""
        Http.client.newCall(cfg.req("/SyncClipboard.json").put(body.toRequestBody("application/json".toMediaType())).build())
            .execute().use { assertTrue(it.isSuccessful) }
        val ch = phone.pollRemote()
        assertTrue(ch is RemoteChange.Text && ch.text == text)
    }

    @Test fun f_uploadAndAutoReceive() {
        val hub = HubClient(cfg)
        val state = MemoryStateStore()
        val dir = Files.createTempDirectory("recv").toFile()
        val recv = AutoReceiver(hub, state, { DirectFileSink(dir) }, device = "android")
        assertTrue(recv.pollOnce().isEmpty())                  // 基线
        assertTrue(state.lastHubId > 0)

        val data = Random.nextBytes(3 * 1024 * 1024 + 17)
        val name = uniq("report") + ".pdf"
        var lastProgress = 0L
        val item = hub.upload(name, data.size.toLong(), "Windows", { data.inputStream() }) { s, _ -> lastProgress = s }
        assertEquals(data.size.toLong(), lastProgress)
        assertEquals(name, item.filename); assertEquals(data.size.toLong(), item.size)
        // 手机自己发出的文件不应被自动接收
        hub.upload(uniq("mine") + ".txt", 3, "Android", { "abc".byteInputStream() })

        val got = recv.pollOnce()
        assertEquals(1, got.size)
        assertTrue(data.contentEquals(dir.resolve(name).readBytes()))
        assertTrue(recv.pollOnce().isEmpty())                  // 不重复下载

        // 同名不同内容 → 另存为 "name (1).pdf"
        hub.upload(name, 5, "Mac", { "12345".byteInputStream() })
        val got2 = recv.pollOnce()
        assertEquals(1, got2.size)
        assertTrue(got2[0].path.endsWith(name.removeSuffix(".pdf") + " (1).pdf"))
    }

    @Test fun g_hubTextUpdateDeleteDownload() {
        val hub = HubClient(cfg)
        val t = hub.postText(uniq("hub text"), "Android", syncClipboard = false)
        assertTrue(t.isText)
        val u = hub.update(t.id, starred = true)
        assertTrue(u.starred)
        hub.update(t.id, starred = false)
        hub.delete(t.id)
        assertFalse(hub.listItems(100).any { it.id == t.id })

        val odd = uniq("100% 完成 a%20b+c&d=#") + ".txt"
        assertEquals("文件名中的 % + & # 应原样保留", odd, hub.upload(odd, 1, "Web", { "x".byteInputStream() }).filename)

        val f = hub.upload(uniq("dl") + ".bin", 4, "Web", { byteArrayOf(1, 2, 3, 4).inputStream() })
        val out = ByteArrayOutputStream()
        assertEquals(4L, hub.download(f, out))
        assertTrue(byteArrayOf(1, 2, 3, 4).contentEquals(out.toByteArray()))
    }

    @Test fun h_wrongPasswordRejected() {
        val bad = SyncClipboardClient(cfg.copy(password = "wrong"))
        try { bad.getProfile(); throw AssertionError("应返回 401") } catch (e: ApiException) { assertEquals(401, e.code) }
    }
}
