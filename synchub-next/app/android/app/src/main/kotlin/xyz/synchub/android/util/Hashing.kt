package xyz.synchub.android.util

import java.security.MessageDigest

/** SHA-256 大写十六进制摘要（用于剪贴板回声抑制与 Root 进程回读确认）。 */
object Hashing {
    fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).toHex()

    fun textHash(text: String): String = sha256Hex(text.toByteArray(Charsets.UTF_8))

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
