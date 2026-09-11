package com.example.lares_app

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * 深链入口:lares://join 直达进房。
 * 冷启动经 MethodChannel 拉取(consumeJoin),运行中经 EventChannel 推送。
 */
class MainActivity : FlutterActivity() {
    private var joinRequested = false
    private var eventSink: EventChannel.EventSink? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private var pendingPayload: String? = null

    private fun handleIntent(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme != "lares") return
        when (data.host) {
            "join" -> {
                joinRequested = true
                eventSink?.success("join")
            }
            // 邀请链接:lares://circle/<圈子id>?name=<圈名>
            "circle" -> {
                val id = data.pathSegments?.firstOrNull() ?: return
                val name = data.getQueryParameter("name") ?: "朋友的圈"
                pendingPayload = "circle|$id|$name"
                eventSink?.success(pendingPayload)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lares/deeplink")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumeJoin" -> {
                        result.success(joinRequested)
                        joinRequested = false
                    }
                    // 冷启动深链(join 或 circle 邀请),取出即清
                    "consumeLink" -> {
                        result.success(pendingPayload ?: if (joinRequested) "join" else null)
                        pendingPayload = null
                        joinRequested = false
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "lares/deeplink/events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    eventSink = sink
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }
}
