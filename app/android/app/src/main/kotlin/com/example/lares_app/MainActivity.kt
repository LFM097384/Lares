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
        // 应用内更新插件必须手动注册:GeneratedPluginRegistrant 只登记 pub 插件,
        // 不会登记 App 本地的类。漏掉这一行,installApk 会抛 MissingPluginException,
        // 表现为「拉起安装器失败」—— 下载和校验却都正常,极易误判成下载问题。
        flutterEngine.plugins.add(LaresUpdatePlugin())
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
        // 小组件麦克风按钮的通道:把活着的引擎交给 WidgetActionReceiver。
        // 引擎在,接收器才能把请求递进 Dart;引擎销毁时在 cleanUpFlutterEngine 清掉,
        // 免得接收器往一条死通道里发、然后干等到超时。
        WidgetActionReceiver.channel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WidgetActionReceiver.CHANNEL)
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

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        WidgetActionReceiver.channel = null
        // 引擎没了就不可能在房:如实把小组件写回「不在房」,
        // 而不是等心跳过期那两分多钟里还挂着一个按不动的麦克风按钮。
        WidgetActionReceiver.writeRoomState(this, inRoom = false, muted = true, circleId = "")
        WidgetActionReceiver.refreshWidgets(this)
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
