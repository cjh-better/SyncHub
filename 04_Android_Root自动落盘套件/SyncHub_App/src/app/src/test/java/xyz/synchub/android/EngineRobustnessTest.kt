package xyz.synchub.android

import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import xyz.synchub.android.net.ClipProfile
import xyz.synchub.android.net.Hashing
import xyz.synchub.android.net.ServerConfig
import xyz.synchub.android.net.SyncClipboardClient
import xyz.synchub.android.root.HookCheck
import xyz.synchub.android.sync.ClipSyncEngine
import xyz.synchub.android.sync.MemoryStateStore
import xyz.synchub.android.sync.RemoteChange

/** 模拟生产服务器（SyncClipboard.json 带 dataName:"" / syncedAt 7 位小数）的剪贴板引擎测试，不连接任何真实服务器。 */
class EngineRobustnessTest {
    private lateinit var server: MockWebServer
    @Volatile private var profile = prodJson("init")
    @Volatile private var failFiles = 0
    private val files = HashMap<String, ByteArray>()
    private val puts = ArrayList<String>()
    private val logs = ArrayList<String>()

    private fun prodJson(text: String, hasData: Boolean = false, dataName: String = "", type: String = "Text") =
        """{"type":"$type","hash":"${Hashing.textHash(text).lowercase()}","text":${org.json.JSONObject.quote(text)},"hasData":$hasData,""" +
            """"dataName":"$dataName","size":${text.length},"syncedAt":"2026-11-10T01:02:37.3028943+00:00"}"""

    @Before fun up() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.path!!
                return when {
                    request.method == "GET" && path == "/SyncClipboard.json" -> MockResponse().setBody(profile)
                    request.method == "PUT" && path == "/SyncClipboard.json" -> {
                        val body = request.body.readUtf8(); synchronized(puts) { puts += body }
                        profile = body; MockResponse()
                    }
                    path.startsWith("/file/") && request.method == "GET" -> {
                        if (failFiles > 0) { failFiles--; MockResponse().setResponseCode(502) }
                        else files[path.removePrefix("/file/")]?.let { MockResponse().setBody(okio.Buffer().write(it)) }
                            ?: MockResponse().setResponseCode(404)
                    }
                    path.startsWith("/file/") && request.method == "PUT" -> { files[path.removePrefix("/file/")] = request.body.readByteArray(); MockResponse() }
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }
        server.start()
    }

    @After fun down() { server.shutdown() }

    private fun engine(store: MemoryStateStore = MemoryStateStore()) =
        ClipSyncEngine(SyncClipboardClient(ServerConfig(server.url("/").toString(), "u", "p")), store, log = { synchronized(logs) { logs += it } })

    @Test fun parsesProductionProfile() {
        val p = ClipProfile.parse(prodJson("你好 world"))
        assertEquals("Text", p.type); assertEquals("你好 world", p.text); assertFalse(p.hasData)
        assertEquals("", p.dataName)   // 空字符串不是 null，但 Text + hasData=false 时直接用 text
        assertEquals(Hashing.textHash("你好 world"), ClipSyncEngine.keyOf(p))
    }

    @Test fun bothDirectionsWithEmptyDataName() {
        val phone = engine()
        assertNull("首次只记录起点", phone.pollRemote())
        profile = prodJson("PC 复制的 A")
        assertEquals("PC 复制的 A", (phone.pollRemote() as RemoteChange.Text).text)
        assertFalse("写回本地剪贴板触发的回调不应回传", phone.onLocalText("PC 复制的 A"))
        assertTrue(phone.onLocalText("手机复制的 B"))
        assertTrue(puts.last().contains("手机复制的 B"))
        assertNull("自己推送的内容不应再拉回", phone.pollRemote())
        profile = prodJson("PC 复制的 A")
        assertEquals("A→B→A：旧内容再次出现也要同步", "PC 复制的 A", (phone.pollRemote() as RemoteChange.Text).text)
        assertTrue(phone.onLocalText("手机复制的 B"))
        assertTrue(logs.any { it.contains("跳过") })
        assertTrue("日志里不能出现正文", logs.none { it.contains("PC 复制的") || it.contains("手机复制的") })
    }

    @Test fun downloadFailureIsRetriedNotLost() {
        val store = MemoryStateStore()
        val phone = engine(store)
        phone.pollRemote()
        val long = "长".repeat(12000)
        files["Text_x.txt"] = long.toByteArray()
        profile = """{"type":"Text","hash":"${Hashing.textHash(long)}","text":"截断","hasData":true,"dataName":"Text_x.txt","size":12000}"""
        failFiles = 1
        try { phone.pollRemote(); throw AssertionError("应抛出") } catch (e: Exception) { }
        assertEquals("下载失败后应在下次轮询重试", long, (phone.pollRemote() as RemoteChange.Text).text)
        // 连续 3 次失败后放弃，不会永远卡在这一条
        val bad = "坏条目"
        profile = """{"type":"Text","hash":"${Hashing.textHash(bad + "x")}","text":"","hasData":true,"dataName":"missing.txt","size":1}"""
        repeat(3) { runCatching { phone.pollRemote() } }
        assertNull(phone.pollRemote())
        assertTrue(logs.any { it.contains("连续 3 次下载失败") })
    }

    @Test fun releaseAfterFailedClipboardWrite() {
        val phone = engine()
        phone.pollRemote()
        profile = prodJson("X")
        val ch = phone.pollRemote() as RemoteChange.Text
        phone.release(ch.hash)   // setPrimaryClip 失败
        assertTrue("写入失败后，用户本地复制同样内容仍应推送", phone.onLocalText("X"))
    }

    @Test fun upgradeStateFromOldVersionDoesNotBlock() {
        // 1.0.0/1.0.1 持久化的 lastRemoteKey（大写 hash）与服务器的小写 hash 对得上，不会重复写入
        val store = MemoryStateStore(lastRemoteKey = Hashing.textHash("init"))
        val phone = engine(store)
        assertNull(phone.pollRemote())
        profile = prodJson("new")
        assertEquals("new", (phone.pollRemote() as RemoteChange.Text).text)
    }

    @Test fun hookCheckParse() {
        assertEquals(HookCheck.State.ACTIVE, HookCheck.parse("abc\n---\nabc\n2\n2\n").state)
        assertEquals(HookCheck.State.NO_MARKER, HookCheck.parse("abc\n---\n").state)
        assertEquals(HookCheck.State.NO_MARKER, HookCheck.parse("abc\n---\nold\n2\n2\n").state)
        assertEquals(HookCheck.State.NO_HOOK, HookCheck.parse("abc\n---\nabc\n0\n2\n").state)
    }
}
