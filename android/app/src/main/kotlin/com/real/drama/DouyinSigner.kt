package com.real.drama

import android.content.Context
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

class DouyinSigner(private val context: Context) {
    fun sign(query: String, userAgent: String, result: MethodChannel.Result) {
        if (query.length > 32768 || userAgent.length > 1024) {
            result.error("invalid_request", "请求参数过长", null)
            return
        }
        val view = try { WebView(context) } catch (_: Exception) {
            result.error("sign_failed", "请更新 Android System WebView 后重试", null)
            return
        }
        var finished = false
        var started = false
        fun finish(value: String?, error: Boolean) {
            if (finished) return
            finished = true
            view.stopLoading()
            view.destroy()
            if (error) result.error("sign_failed", "抖音请求环境初始化失败", null)
            else result.success(value)
        }
        try {
            view.settings.javaScriptEnabled = true
            view.settings.blockNetworkLoads = true
            view.settings.allowFileAccess = false
            view.settings.allowContentAccess = false
            view.postDelayed({ finish(null, true) }, 5000)
            val script = context.assets.open("douyin_abogus.js").bufferedReader().use { it.readText() }
            val expression = script + "\ngetABogus(" + JSONObject.quote(query) + "," + JSONObject.quote(userAgent) + ")"
            view.webViewClient = object : WebViewClient() {
                override fun onPageFinished(webView: WebView, url: String?) {
                    if (finished || started) return
                    started = true
                    webView.evaluateJavascript(expression) { value ->
                        try {
                            val signed = JSONArray("[" + value + "]").optString(0)
                            finish(signed, signed.isBlank() || signed == "null")
                        } catch (_: Exception) { finish(null, true) }
                    }
                }
            }
            view.loadDataWithBaseURL(null, "<html><body></body></html>", "text/html", "UTF-8", null)
        } catch (_: Exception) { finish(null, true) }
    }
}
