package xyz.synchub.android.net

import java.io.InputStream
import java.security.MessageDigest

/** SyncClipboard 官方 Hash 规则（docs/Hash.md）：SHA-256，大写十六进制。 */
object Hashing {
    fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).toHex()

    fun sha256Hex(input: InputStream): String {
        val md = MessageDigest.getInstance("SHA-256")
        val buf = ByteArray(64 * 1024)
        while (true) {
            val n = input.read(buf)
            if (n < 0) break
            md.update(buf, 0, n)
        }
        return md.digest().toHex()
    }

    /** Text profile hash = SHA256(UTF8(text)) */
    fun textHash(text: String): String = sha256Hex(text.toByteArray(Charsets.UTF_8))

    /** File / Image profile hash = SHA256(UTF8("fileName|CONTENTHASH")) */
    fun fileProfileHash(fileName: String, contentHash: String): String =
        sha256Hex("$fileName|${contentHash.uppercase()}".toByteArray(Charsets.UTF_8))

    private fun ByteArray.toHex(): String {
        val sb = StringBuilder(size * 2)
        for (b in this) {
            val v = b.toInt() and 0xff
            sb.append(HEX[v ushr 4]).append(HEX[v and 0x0f])
        }
        return sb.toString()
    }

    private val HEX = "0123456789ABCDEF".toCharArray()
}
