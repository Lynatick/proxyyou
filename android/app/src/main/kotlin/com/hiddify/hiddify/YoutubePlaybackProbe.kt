package com.hiddify.hiddify

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Dialog
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.core.content.ContextCompat
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.ScriptHandler
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class YoutubePlaybackProbe(private val activity: Activity, channel: MethodChannel) : MethodChannel.MethodCallHandler {
    private var pending: MethodChannel.Result? = null
    private var session: String? = null
    private var browser: WebView? = null
    private var dialog: Dialog? = null
    private var renderingHost: FrameLayout? = null
    private var policyHandler: ScriptHandler? = null
    private val handler = Handler(Looper.getMainLooper())
    private var script = ""
    private var controls = ""
    private var background = false
    private var videoId = ""
    private var evaluating = false
    private var latestProof = emptyMap<String, Any>()
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
                    if (token != session || browser !== view) return@evaluateJavascript
                    evaluating = false
                    try {
                        val proof = JSONObject(raw)
                        if (proof.optString("status") == "unsupported") {
                            finish(mapOf("status" to "unsupported"))
                        } else {
                            recordProgress(proof)
                            accept(proof)
                        }
                    } catch (_: Exception) { /* Navigation or player not ready. */ }
                }
            }
            if (pending != null && !closingPlayer) handler.postDelayed(this, 500)
        }
    }

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(call, result)
            "progress" -> result.success(if (call.argument<String>("session") == session) latestProof else null)
            "show" -> { if (call.argument<String>("session") == session) showPlayer(); result.success(null) }
            "cancel" -> {
                if (call.argument<String>("session") == session) finish(mapOf("status" to "cancelled"))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun start(call: MethodCall, result: MethodChannel.Result) {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE) ||
            !WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            result.success(mapOf("status" to "unsupported")); return
        }
        val port = call.argument<Int>("port") ?: 0
        val id = call.argument<String>("videoId") ?: ""
        val source = call.argument<String>("script") ?: ""
        val policy = call.argument<String>("controls") ?: ""
        val token = call.argument<String>("session") ?: ""
        if (port !in 1..65535 || !Regex("^[a-zA-Z0-9_-]{11}$").matches(id) || source.isEmpty() || policy.isEmpty() || token.isEmpty()) {
            result.success(mapOf("status" to "failed")); return
        }
        finish(mapOf("status" to "cancelled"))
        pending = result
        session = token
        videoId = id
        controls = policy
        background = call.argument<Boolean>("background") == true
        script = "window.__proxyyouDecodedProbe = true;\nwindow.__proxyyouExpectedSession = ${JSONObject.quote(token)};\nwindow.__proxyyouExpectedId = '$id';\n$source"
        handler.postDelayed(timeout, 90000)
        val config = ProxyConfig.Builder().addProxyRule("http://127.0.0.1:$port").removeImplicitRules().build()
        ProxyController.getInstance().setProxyOverride(config, ContextCompat.getMainExecutor(activity)) {
            if (session != token || activity.isFinishing) return@setProxyOverride
            val view = WebView(activity)
            browser = view
            view.settings.javaScriptEnabled = true
            view.settings.domStorageEnabled = true
            view.settings.mediaPlaybackRequiresUserGesture = !background
            view.settings.cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
            installPolicy(view)
            view.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(v: WebView, request: WebResourceRequest): Boolean {
                    val host = request.url.host?.lowercase() ?: ""
                    return request.url.scheme != "https" ||
                        !(host == "youtube.com" || host.endsWith(".youtube.com") || host == "consent.google.com")
                }
                override fun onReceivedError(v: WebView, request: WebResourceRequest, error: WebResourceError) {
                    if (v === browser && session == token && request.isForMainFrame) finish(mapOf("status" to "failed"))
                }
                override fun onReceivedHttpError(v: WebView, request: WebResourceRequest, response: WebResourceResponse) {
                    if (v === browser && session == token && request.isForMainFrame && response.statusCode >= 400) finish(mapOf("status" to "failed"))
                }
                override fun onRenderProcessGone(v: WebView, detail: RenderProcessGoneDetail): Boolean {
                    if (v === browser && session == token) finish(mapOf("status" to "failed"))
                    return true
                }
            }
            if (background) {
                // Attach beneath Flutter so Chromium has a rendering host, without a dialog,
                // focus changes, accessibility controls or user-visible video.
                val root = activity.window.decorView as ViewGroup
                val host = FrameLayout(activity)
                host.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                host.alpha = 0.01f
                host.addView(view, FrameLayout.LayoutParams(320, 180))
                root.addView(host, 0, ViewGroup.LayoutParams(320, 180))
                renderingHost = host
            } else {
                showPlayer()
            }
            handler.postDelayed(poll, 500)
            view.loadUrl("https://www.youtube.com/watch?v=$id&autoplay=${if (background) 1 else 0}&mute=1")
        }
    }

    private fun installPolicy(view: WebView) {
        policyHandler?.remove()
        policyHandler = WebViewCompat.addDocumentStartJavaScript(view,
            "window.__proxyyouAutomaticPlayback = $background;\n$controls", setOf("*"))
    }

    private fun showPlayer() {
        if (dialog != null) return
        val view = browser ?: return
        background = false
        view.settings.mediaPlaybackRequiresUserGesture = true
        installPolicy(view)
        view.evaluateJavascript("window.__proxyyouRequireManualStart?.()", null)
        (view.parent as? ViewGroup)?.removeView(view)
        renderingHost?.let { (it.parent as? ViewGroup)?.removeView(it) }
        renderingHost = null
        val player = Dialog(activity)
        player.setTitle("ProxyYou — нажмите Play для проверки")
        player.setContentView(view)
        player.setOnDismissListener { closePlayer() }
        dialog = player
        player.show()
        player.window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
    }

    private fun recordProgress(proof: JSONObject) {
        val seconds = proof.optDouble("seconds")
        val frames = proof.optInt("frames")
        if (proof.optString("videoId") != videoId || proof.optString("session") != session || !seconds.isFinite() || seconds < 0 || frames < 0) return
        latestProof = mapOf("session" to session.orEmpty(), "videoId" to videoId, "seconds" to seconds, "frames" to frames)
        dialog?.setTitle("ProxyYou — ${(seconds / 12 * 100).toInt().coerceIn(0, 99)}%")
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
        if (background) { finish(response); return }
        dialog?.setTitle("ProxyYou — 100%")
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
            if (token != session || browser !== view) return@evaluateJavascript
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
        latestProof = emptyMap()
        handler.removeCallbacks(timeout)
        handler.removeCallbacks(poll)
        handler.removeCallbacks(closeTimeout)
        policyHandler?.remove()
        policyHandler = null
        browser?.stopLoading()
        browser?.loadUrl("about:blank")
        browser?.let { (it.parent as? ViewGroup)?.removeView(it) }
        browser?.destroy()
        browser = null
        renderingHost?.let { (it.parent as? ViewGroup)?.removeView(it) }
        renderingHost = null
        dialog?.setOnDismissListener(null)
        dialog?.dismiss()
        dialog = null
        evaluating = false
        result?.success(finalResponse)
    }
}
