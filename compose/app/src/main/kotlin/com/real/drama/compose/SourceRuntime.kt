package com.real.drama.compose

import android.content.Context
import android.net.Uri
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class SourceRuntime(private val context: Context, val subscriptions: Subscriptions, val store: LocalStore, val secrets: Secrets) {
    private val lanes = ConcurrentHashMap<String, Mutex>()
    private val states = ConcurrentHashMap<String, JSONObject>()
    private val slots = Semaphore(3)
    private val paced = Mutex()
    private var nextRequest = 0L
    private var cooldown = 0L
    private val serial = AtomicLong(System.currentTimeMillis() * 1000)
    private val active = ConcurrentHashMap<String, JSONObject>()
    suspend fun clearCredentials(group: String) {
        cancel()
        val ids = subscriptions.sources.filter { it.group == group }.map { it.id }
        states.keys.filter { key -> ids.any { ":$it:" in key } }.forEach(states::remove)
    }
    private fun authorize(packageValue: SourcePackage, epoch: Long, configure: Boolean) {
        check(store.epoch == epoch && !store.locked.value && (configure || store.allowed(packageValue.id)) && subscriptions.source(packageValue.id)?.digest == packageValue.digest) { "站源已关闭、更新或用户已切换" }
    }
    suspend fun cancel() {
        withContext(NonCancellable + Dispatchers.IO) {
            active.values.toList().forEach { runCatching { NativeBridge.call(it.copy().put("action", "cancelRead")) } }
        }
    }
    suspend fun execute(source: String, action: String, payload: JSONObject = JSONObject(), configure: Boolean = false): JSONObject {
        val packageValue = subscriptions.source(source) ?: error("请先导入此站源订阅")
        val epoch = store.epoch
        val lane = if (action in setOf("danmaku", "creator", "comments")) action else if (packageValue.group == "bilibili" && action in setOf("detail", "resolve", "metadata")) "playback" else "main"
        val key = "${store.active}:$source:${packageValue.digest}:$lane"
        return lanes.getOrPut(key) { Mutex() }.withLock {
            slots.withPermit {
                authorize(packageValue, epoch, configure)
                val id = "compose:${serial.incrementAndGet()}"
                val read = obj("session" to id, "sequence" to serial.incrementAndGet())
                active[id] = read
                var request = obj("command" to "start", "id" to id, "program" to packageValue.program, "action" to action,
                    "payload" to payload.copy().put("source", source), "state" to (states[key] ?: JSONObject()))
                try {
                    withTimeout(if (packageValue.group == "douyin") 120000 else 30000) {
                        repeat(16) {
                            ensureActive(); authorize(packageValue, epoch, configure)
                            val data = NativeBridge.call(request, true)
                            val value = data.optJSONObject("value") ?: JSONObject()
                            if (data.optBoolean("done")) {
                                authorize(packageValue, epoch, configure)
                                value.optJSONObject("state")?.let { state -> states[key] = state; value.remove("state") }
                                if (states.size > 64) states.keys.firstOrNull { it != key }?.let(states::remove)
                                check(!value.has("error")) { value.text("error") }
                                return@withTimeout value
                            }
                            val response: Any = when (value.text("type")) {
                                "sign" -> { require(packageValue.group == "douyin"); sign(value.getString("query"), value.text("userAgent")) }
                                "http" -> if (packageValue.group == "douyin") paced.withLock {
                                    val wait = maxOf(nextRequest, cooldown) - System.currentTimeMillis()
                                    if (wait > 0) delay(wait)
                                    authorize(packageValue, epoch, configure)
                                    try {
                                        http(packageValue, action, value, read).also { response ->
                                            if (response.optInt("status") == 429) {
                                                val seconds = response.text("retryAfter").toLongOrNull()?.coerceIn(1, 600) ?: 60
                                                cooldown = System.currentTimeMillis() + seconds * 1000
                                            }
                                        }
                                    } finally { nextRequest = System.currentTimeMillis() + 1500 }
                                } else http(packageValue, action, value, read)
                                else -> error("订阅请求了不支持的能力")
                            }
                            request = obj("command" to "next", "id" to id, "response" to response)
                        }
                        error("站源单次请求次数过多")
                    }
                } catch (error: Exception) {
                    if (error !is CancellationException) withContext(NonCancellable) { (context.applicationContext as DramaApplication).repository.diagnostics.record("source_error", obj("source" to source, "operation" to action, "code" to ((error as? NativeFailure)?.code ?: "source_error"), "exceptionType" to error.javaClass.simpleName)) }
                    if (error is TimeoutCancellationException) {
                        currentCoroutineContext().ensureActive()
                        throw NativeFailure("source_timeout", "站源请求超时")
                    }
                    throw error
                } finally {
                    active.remove(id)
                    withContext(NonCancellable + Dispatchers.IO) {
                        runCatching { NativeBridge.call(read.copy().put("action", "cancelRead")) }
                        runCatching { NativeBridge.call(obj("command" to "cancel", "id" to id), true) }
                    }
                }
            }
        }
    }
    private suspend fun http(packageValue: SourcePackage, action: String, command: JSONObject, read: JSONObject): JSONObject {
        var uri = URI(command.getString("url"))
        Subscriptions.validateUrl(uri)
        require(uri.host in packageValue.domains) { "请求超出站源声明域名" }
        var cookie = ""
        val headers = command.optJSONObject("headers")?.copy() ?: JSONObject()
        if (command.optBoolean("credential")) {
            require(uri.host in packageValue.credentials) { "禁止向此域名发送凭据" }
            cookie = secrets.read("cookie.${packageValue.group}.${store.active}")
            check(cookie.isNotEmpty() || !packageValue.document.optBoolean("credentialRequired")) { "请在站源设置中配置 Cookie" }
            if (packageValue.group == "douyin") Regex("(?:^|;\\s*)(?:uifid|uifid_temp)=([^;]+)", RegexOption.IGNORE_CASE).find(cookie)?.groupValues?.get(1)?.let { headers.put("uifid", it.trim()) }
        }
        if (command.optBoolean("sign") && !Uri.parse(uri.toString()).queryParameterNames.contains("a_bogus")) {
            require(packageValue.group == "douyin" && uri.host in packageValue.credentials)
            var address = Uri.parse(uri.toString())
            val token = Regex("(?:^|;\\s*)msToken=([^;]+)").find(cookie)?.groupValues?.get(1)
            if (token != null) address = address.buildUpon().appendQueryParameter("msToken", token).build()
            val signed = sign(address.encodedQuery.orEmpty(), headers.text("User-Agent"))
            uri = URI(address.buildUpon().appendQueryParameter("a_bogus", signed).build().toString())
        }
        read.put("sequence", serial.incrementAndGet())
        val body = command.opt("body")
        return NativeBridge.call(read.copy().put("action", "subscriptionHttp").put("subscriptionHttp", obj(
            "url" to uri.toString(), "source" to packageValue.id, "operation" to action, "method" to command.text("method", "GET"),
            "headers" to headers, "binary" to command.optBoolean("binary"), "bodyBase64" to command.text("bodyBase64"),
            "body" to (if (body == null || body == JSONObject.NULL) "" else body.toString()), "domains" to JSONArray(packageValue.domains),
            "credentialDomains" to JSONArray(packageValue.credentials), "cookie" to cookie,
            "browser" to (packageValue.document.optBoolean("browser") && (cookie.isEmpty() || uri.host in packageValue.document.array("browserCredentialDomains").strings())))))
    }
    private suspend fun sign(query: String, userAgent: String): String = withContext(Dispatchers.Main) {
        require(query.length <= 32768 && userAgent.length <= 1024)
        withTimeout(6000) {
            suspendCancellableCoroutine { continuation ->
                val view = WebView(context)
                var finished = false
                fun finish(value: String?, error: Exception?) {
                    if (finished) return
                    finished = true; view.stopLoading(); view.destroy()
                    if (continuation.isActive) {
                        if (error != null) continuation.resumeWithException(error) else continuation.resume(value.orEmpty())
                    }
                }
                continuation.invokeOnCancellation { android.os.Handler(android.os.Looper.getMainLooper()).post { finish(null, null) } }
                try {
                    view.settings.javaScriptEnabled = true; view.settings.blockNetworkLoads = true
                    view.settings.allowFileAccess = false; view.settings.allowContentAccess = false
                    val script = context.assets.open("douyin_abogus.js").bufferedReader().use { it.readText() }
                    var started = false
                    view.webViewClient = object : WebViewClient() {
                        override fun onPageFinished(webView: WebView, url: String?) {
                            if (started || finished) return
                            started = true
                            view.evaluateJavascript(script + "\ngetABogus(${JSONObject.quote(query)},${JSONObject.quote(userAgent)})") { result ->
                                try { val value = JSONArray("[$result]").optString(0); check(value.isNotBlank() && value != "null"); finish(value, null) }
                                catch (error: Exception) { finish(null, IllegalStateException("请求签名失败")) }
                            }
                        }
                    }
                    view.loadDataWithBaseURL(null, "<html></html>", "text/html", "UTF-8", null)
                } catch (error: Exception) { finish(null, IllegalStateException("请更新 Android System WebView 后重试", error)) }
            }
        }
    }
}
