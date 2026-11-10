package xyz.synchub.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import xyz.synchub.android.net.ClipProfile
import xyz.synchub.android.net.Hashing
import xyz.synchub.android.net.ServerConfig
import xyz.synchub.android.sync.AutoReceiver
import xyz.synchub.android.sync.DirectFileSink
import java.nio.file.Files

class UnitTests {
    @Test fun textHashMatchesOfficialRule() {
        // 官方服务器对 "init" 返回的 hash（本地 v3.3.3 实测）
        assertEquals("BB54068AEA85FAA7E487530083366BE9962390AF822E4C71EF1ACA7033C83E66", Hashing.textHash("init"))
    }

    @Test fun fileProfileHashRule() {
        val content = Hashing.sha256Hex("hello".toByteArray())
        assertEquals(Hashing.sha256Hex("a.png|$content".toByteArray()), Hashing.fileProfileHash("a.png", content.lowercase()))
    }

    @Test fun parseCamelAndPascal() {
        val a = ClipProfile.parse("""{"type":"Image","hash":"H","text":"x.png","hasData":true,"dataName":"x.png","size":3}""")
        assertEquals("Image", a.type); assertTrue(a.hasData); assertEquals("x.png", a.dataName); assertEquals(3L, a.size)
        // synchub_server.py /api/hub/text 写入的是 PascalCase
        val b = ClipProfile.parse("""{"Type":"Text","Hash":"H2","Text":"你好","HasData":false,"DataName":""}""")
        assertEquals("Text", b.type); assertEquals("你好", b.text); assertFalse(b.hasData)
        // 旧版 v2 协议
        val c = ClipProfile.parse("""{"Type":"Text","Clipboard":"old","File":""}""")
        assertEquals("old", c.text); assertEquals(null, c.dataName)
    }

    @Test fun profileJsonRoundTrip() {
        val p = ClipProfile("Text", "ABC", "hi", false, null, size = 2)
        val q = ClipProfile.parse(p.toJson())
        assertEquals(p, q)
        assertTrue(p.toJson().contains("\"hasData\":false"))
    }

    @Test fun basicAuthIsStrictBase64() {
        val h = ServerConfig("https://x", "admin", "p@ss:wörd!#").basicAuth()!!
        assertTrue(h.matches(Regex("^Basic [A-Za-z0-9+/=]+$")))
    }

    @Test fun sanitizeAndUniqueName() {
        assertEquals("a_b.txt", AutoReceiver.sanitize("a:b.txt"))
        assertEquals("c.txt", AutoReceiver.sanitize("..\\x/c.txt"))
        val dir = Files.createTempDirectory("sink").toFile()
        val sink = DirectFileSink(dir)
        dir.resolve("r.pdf").writeText("1")
        assertEquals("r (1).pdf", AutoReceiver.uniqueName(sink, "r.pdf"))
        assertTrue(sink.existsWithSize("r.pdf", 1)); assertFalse(sink.existsWithSize("r.pdf", 2))
    }
}
