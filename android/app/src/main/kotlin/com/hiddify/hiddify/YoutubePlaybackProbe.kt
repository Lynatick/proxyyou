package com.hiddify.hiddify

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Dialog
import android.os.Handler
import android.os.Looper
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.core.content.ContextCompat
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class YoutubePlaybackProbe(private val activity: Activity, channel: MethodChannel) : MethodChannel.MethodCallHandler {
    private var pending: MethodChannel.Result? = null
    private var session: String? = null
    private var browser: WebView? = null
    private var dialog: Dialog? = null
    private val handler = Handler(Looper.getMainLooper())
    private var script = ""
    private var videoId = ""
    private var evaluating = false
    private var acceptedProof: Map<String, Any>? = null
    private var closingPlayer = false
    private val closeTimeout = Runnable { finish(mapOf("status" to "cancelled")) }
    private val timeout = Runnable { finish(mapOf("status" to "failed")) }
    private val poll = object : Runnable {
        override fun run() {
            val view = browser ?: return
            if (!evaluating && pending != null) {
                evaluating = true
                val token = session
                view.evaluateJavascript(script) { raw ->
                    if (token != session) return@evaluateJavascript
                    evaluating = false
                    try {
                        val proof = JSONObject(raw)
                        if (proof.optString("status") == "unsupported") {
                            finish(mapOf("status" to "unsupported"))
                        } else {
                            accept(proof)
                        }
                    } catch (_: Exception) { /* The page may be navigating or waiting for its player. */ }
                }
            }
            if (pending != null && !closingPlayer) handler.postDelayed(this, 500)
        }
    }

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(call, result)
            "cancel" -> {
                if (call.argument<String>("session") == session) finish(mapOf("status" to "cancelled"))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun start(call: MethodCall, result: MethodChannel.Result) {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
            result.success(mapOf("status" to "unsupported")); return
        }
        val port = call.argument<Int>("port") ?: 0
        val id = call.argument<String>("videoId") ?: ""
        val source = call.argument<String>("script") ?: ""
        val token = call.argument<String>("session") ?: ""
        if (port !in 1..65535 || !Regex("^[a-zA-Z0-9_-]{11}$").matches(id) || source.isEmpty() || token.isEmpty()) {
            result.success(mapOf("status" to "failed")); return
        }
        finish(mapOf("status" to "cancelled"))
        pending = result
        session = token
        videoId = id
        script = "window.__proxyyouExpectedSession = ${JSONObject.quote(token)};\nwindow.__proxyyouExpectedId = '$id';\n$source"
        val config = ProxyConfig.Builder().addProxyRule("http://127.0.0.1:$port").removeImplicitRules().build()
        // Load only after the override is active: the app itself is excluded from VpnService.
        ProxyController.getInstance().setProxyOverride(config, ContextCompat.getMainExecutor(activity)) {
            if (session != token || activity.isFinishing) return@setProxyOverride
            val view = WebView(activity)
            browser = view
            view.settings.javaScriptEnabled = true
            view.settings.domStorageEnabled = true
            view.settings.mediaPlaybackRequiresUserGesture = true
            view.settings.cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
            view.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(v: WebView, request: WebResourceRequest): Boolean {
                    val host = request.url.host?.lowercase() ?: ""
                    return request.url.scheme != "https" ||
                        !(host == "youtube.com" || host.endsWith(".youtube.com") || host == "consent.google.com")
                }
                override fun onReceivedError(v: WebView, request: WebResourceRequest, error: WebResourceError) {
                    if (request.isForMainFrame) finish(mapOf("status" to "failed"))
                }
            }
            val player = Dialog(activity)
            player.setTitle("ProxyYou — нажмите Play для проверки")
            player.setContentView(view)
            player.setOnDismissListener { closePlayer() }
            dialog = player
            player.show()
            player.window?.setLayout(android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.ViewGroup.LayoutParams.MATCH_PARENT)
            handler.postDelayed(timeout, 90000)
            handler.postDelayed(poll, 500)
            view.loadUrl("https://www.youtube.com/watch?v=$id")
        }
    }

    private fun accept(proof: JSONObject) {
        val seconds = proof.optDouble("seconds")
        if (proof.optString("status") != "passed" || proof.optString("videoId") != videoId ||
            proof.optString("session") != session || !seconds.isFinite() || seconds < 12 || proof.optInt("frames") < 10) return
        val response = mapOf("status" to "passed", "seconds" to proof.getDouble("seconds"),
            "frames" to proof.getInt("frames"), "videoId" to videoId)
        acceptedProof = response
        handler.removeCallbacks(timeout)
        handler.removeCallbacks(poll)
        val result = pending
        pending = null
        result?.success(response)
    }

    private fun closePlayer() {
        if (closingPlayer) return
        val view = browser
        val token = session
        if (acceptedProof != null || view == null || token == null) {
            finish(mapOf("status" to "cancelled"))
            return
        }
        closingPlayer = true
        handler.removeCallbacks(timeout)
        handler.removeCallbacks(poll)
        handler.postDelayed(closeTimeout, 1000)
        view.evaluateJavascript(script) { raw ->
            if (token != session) return@evaluateJavascript
            try { accept(JSONObject(raw)) } catch (_: Exception) { }
            finish(mapOf("status" to "cancelled"))
        }
    }

    fun close() { finish(mapOf("status" to "cancelled")) }

    private fun finish(response: Map<String, Any>) {
        val result = pending
        val finalResponse = acceptedProof ?: response
        acceptedProof = null
        closingPlayer = false
        pending = null
        session = null
        handler.removeCallbacks(timeout)
        handler.removeCallbacks(poll)
        handler.removeCallbacks(closeTimeout)
        browser?.stopLoading()
        browser?.loadUrl("about:blank")
        browser?.destroy()
        browser = null
        dialog?.setOnDismissListener(null)
        dialog?.dismiss()
        dialog = null
        evaluating = false
        // Keep the override until the next session so an async clear cannot expose a new player to DIRECT.
        result?.success(finalResponse)
    }
}
