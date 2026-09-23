package com.example.lares_app

import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import es.antonborri.home_widget.HomeWidgetPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * 小组件麦克风按钮 -> 活着的 Flutter 引擎 -> RoomController.toggleMute()。
 *
 * `exported=false`:只有本 App 自己(小组件的 PendingIntent)能发进来,
 * 别的 App 不能伪造一条「替他开麦」的广播。
 *
 * ## 为什么不打开 App
 * 需求就是「不打开 App 就能静音/开麦」。这里只把请求递给已经在跑的引擎,
 * 做完把**真实**结果写回小组件。
 *
 * ## 引擎不在时
 * 不启动 Activity:Android 10+ 禁止从后台广播接收器拉起界面(BAL 限制),
 * 硬拉要么被系统拦下、要么行为因厂商而异。而且进程都没了就不可能在房 ——
 * 如实把小组件写回「不在房」,并用 Toast 告诉用户要先打开 App。
 * 之后小组件恢复成「点一下,进圈」,点整块照旧能打开 App。
 *
 * ## Android 14+ 后台开麦
 * 后台采集麦克风要求一个在前台时就已启动的 microphone 类型前台服务。
 * 这件事在 Dart 侧核对(WidgetService.handleToggleRequest 查
 * FlutterForegroundTask.isRunningService),服务没在跑就拒绝开麦、如实回报。
 */
class WidgetActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_TOGGLE_MUTE = "com.example.lares_app.action.TOGGLE_MUTE"
        const val EXTRA_CIRCLE_ID = "circleId"
        const val CHANNEL = "lares/widget_action"

        /** 等 Dart 回话的上限。闲时挂起后开麦要重连媒体,几秒是正常的;
         *  goAsync 给的总时长约 10 秒,留出写回与刷新的余量。 */
        private const val REPLY_TIMEOUT_MS = 8000L

        /**
         * 活着的引擎的通道。由 MainActivity 在 configureFlutterEngine 设置、
         * cleanUpFlutterEngine 清空。只在主线程读写。
         */
        @Volatile
        var channel: MethodChannel? = null

        /** 与 Dart WidgetService 写入同一份共享存储,格式也一致(毫秒时间戳存字符串)。 */
        fun writeRoomState(context: Context, inRoom: Boolean, muted: Boolean, circleId: String) {
            HomeWidgetPlugin.getData(context).edit()
                .putString("state_updated_at", System.currentTimeMillis().toString())
                .putBoolean("in_room", inRoom)
                .putBoolean("muted", muted)
                .putString("room_circle_id", circleId)
                .apply()
        }

        fun refreshWidgets(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, LaresWidgetProvider::class.java))
            if (ids.isEmpty()) return
            val update = Intent(context, LaresWidgetProvider::class.java).apply {
                action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
            }
            context.sendBroadcast(update)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_TOGGLE_MUTE) return
        val circleId = intent.getStringExtra(EXTRA_CIRCLE_ID) ?: ""
        val appContext = context.applicationContext
        val pending = goAsync()
        val main = Handler(Looper.getMainLooper())
        main.post {
            val ch = channel
            if (ch == null) {
                // 没有活着的引擎:不可能在房。不假装切换。
                writeRoomState(appContext, inRoom = false, muted = true, circleId = "")
                refreshWidgets(appContext)
                Toast.makeText(appContext, R.string.widget_mic_no_app, Toast.LENGTH_SHORT).show()
                pending.finish()
                return@post
            }
            var settled = false
            val finish = { ->
                if (!settled) {
                    settled = true
                    refreshWidgets(appContext)
                    pending.finish()
                }
            }
            // 超时:不知道真相,就不覆盖 —— Dart 做完会自己写回并刷新。
            main.postDelayed({ finish() }, REPLY_TIMEOUT_MS)
            ch.invokeMethod(
                "toggleMute",
                mapOf("circleId" to circleId),
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        if (settled) return
                        val map = result as? Map<*, *>
                        val inRoom = map?.get("inRoom") as? Boolean
                        val muted = map?.get("muted") as? Boolean
                        if (inRoom != null && muted != null) {
                            writeRoomState(
                                appContext,
                                inRoom,
                                muted,
                                map["circleId"] as? String ?: "",
                            )
                        }
                        finish()
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        // Dart 侧出错:不知道真相,不覆盖。
                        finish()
                    }

                    override fun notImplemented() {
                        // Dart 侧还没注册处理器(同意内容规范之前不初始化):不可能在房。
                        if (!settled) {
                            writeRoomState(appContext, inRoom = false, muted = true, circleId = "")
                        }
                        finish()
                    }
                },
            )
        }
    }
}
