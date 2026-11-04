package com.real.drama

import android.app.Activity
import android.app.AlertDialog
import android.net.http.SslError
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.plugin.common.MethodChannel

class HanimeCloudflareVerifier(private val activity: Activity) {
    fun open(result: MethodChannel.Result) {
        val cookies = CookieManager.getInstance()
        val webView = try {
            WebView(activity)
        } catch (_: Exception) {
            result.error("hanime_webview_unavailable", "请更新 Android System WebView 后重试", null)
            return
        }
        val message = TextView(activity).apply {
            text = "请在页面中完成 Hanime / Cloudflare 验证，再点“同步 Cookie”。Cookie 只保存在当前资料的安全存储。"
            setPadding(24, 20, 24, 20)
        }
        val content = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(message, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(webView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        var dialog: AlertDialog? = null
        var finished = false
        fun finish(cookie: String?) {
            if (finished) return
            finished = true
            cookies.flush()
            (webView.parent as? ViewGroup)?.removeView(webView)
            webView.stopLoading()
            webView.destroy()
            dialog?.dismiss()
            result.success(cookie)
        }
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            userAgentString = USER_AGENT
        }
        webView.webChromeClient = WebChromeClient()
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                if (!request.isForMainFrame) return false
                val uri = request.url
                val host = uri.host.orEmpty().lowercase()
                return uri.scheme != "https" ||
                    uri.port != -1 && uri.port != 443 ||
                    host != HOST && !host.endsWith(".$HOST")
            }

            override fun onPageFinished(view: WebView, url: String?) {
                message.text = "若页面出现人机验证，请先完成；确认页面已通过后点“同步 Cookie”。"
            }

            override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
                handler.cancel()
                message.text = "安全连接失败，请检查设备时间、网络或 Android System WebView。"
            }
        }
        dialog = AlertDialog.Builder(activity)
            .setTitle("Hanime Cloudflare 验证")
            .setView(content)
            .setNegativeButton("取消", null)
            .setPositiveButton("同步 Cookie", null)
            .create()
        dialog?.setOnShowListener {
            dialog?.window?.setLayout(
                (activity.resources.displayMetrics.widthPixels * 0.94f).toInt(),
                (activity.resources.displayMetrics.heightPixels * 0.84f).toInt()
            )
            dialog?.getButton(AlertDialog.BUTTON_POSITIVE)?.setOnClickListener {
                val cookie = cookies.getCookie(URL).orEmpty()
                if (!CLEARANCE.containsMatchIn(cookie)) {
                    message.text = "还没有检测到 Cloudflare clearance Cookie。请先完成网页验证，再重试同步。"
                } else finish(cookie)
            }
        }
        dialog?.setOnDismissListener { finish(null) }
        cookies.setAcceptCookie(true)
        dialog?.show()
        webView.loadUrl(URL)
    }

    private companion object {
        const val HOST = "hanime1.me"
        const val URL = "https://hanime1.me/"
        const val USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
        val CLEARANCE = Regex("(?:^|;\\s*)cf_clearance=")
    }
}
