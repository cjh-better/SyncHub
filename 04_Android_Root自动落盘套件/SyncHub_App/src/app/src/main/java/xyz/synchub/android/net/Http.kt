package xyz.synchub.android.net

import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.Base64
import java.util.concurrent.TimeUnit

data class ServerConfig(val baseUrl: String, val username: String, val password: String) {
    val root: String get() = baseUrl.trim().trimEnd('/')

    /** 规范 Base64（nginx 会拒绝含非法字符的 Basic 头）。 */
    fun basicAuth(): String? {
        if (username.isEmpty() && password.isEmpty()) return null
        val raw = "$username:$password".toByteArray(Charsets.UTF_8)
        return "Basic " + Base64.getEncoder().encodeToString(raw)
    }

    fun req(path: String): Request.Builder {
        val b = Request.Builder().url(root + path).header("User-Agent", "SyncHub-Android/1.0")
        basicAuth()?.let { b.header("Authorization", it) }
        return b
    }
}

object Http {
    /** 短请求（轮询 / JSON）。 */
    val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(20, TimeUnit.SECONDS)
            .writeTimeout(20, TimeUnit.SECONDS)
            .retryOnConnectionFailure(true)
            .build()
    }

    /** 大文件传输。 */
    val transferClient: OkHttpClient by lazy {
        client.newBuilder()
            .readTimeout(30, TimeUnit.MINUTES)
            .writeTimeout(30, TimeUnit.MINUTES)
            .callTimeout(0, TimeUnit.MILLISECONDS)
            .build()
    }
}
