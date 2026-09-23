package com.example.lares_app

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin

/**
 * 主屏幕 Widget:**主圈子**名 + 在线状态,点一下一键加入主圈子(设计.md §3.2-1)。
 *
 * 数据由 Flutter 侧(WidgetService)经 home_widget 推送。
 * 点按发的是 `lares://join`,**不带圈子 id** —— 目标圈子由 App 在进房时
 * 读 CircleStore.primaryCircle 解析。这样共享存储哪怕陈旧或读不到,
 * 最坏也只是显示退化成默认文案,绝不会把人送进错误的房间。
 *
 * 在房时多一个麦克风按钮(见 [WidgetActionReceiver]):点它不打开 App,
 * 文案只写真实状态。「在房」要同时满足:Dart 写的是 in_room=true、
 * 心跳时间戳没过期([STALE_AFTER_MS])、圈子 id 非空 —— App 被杀后
 * 没人会来写 in_room=false,靠过期时间自己回落。
 */
class LaresWidgetProvider : AppWidgetProvider() {

    companion object {
        /** 与 Dart `WidgetService.staleAfterSeconds` 一致(契约测试会比对)。 */
        const val STALE_AFTER_SECONDS = 150L
        private const val STALE_AFTER_MS = STALE_AFTER_SECONDS * 1000L
        private const val REQ_OPEN = 0
        private const val REQ_MIC = 1
        private const val REQ_STALE = 2
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val data = HomeWidgetPlugin.getData(context)
        // 在房判断三件事缺一不可(见类注释)。读不到一律当「不在房」、「静音」——
        // 宁可少显示一个按钮,也不能把一个不知道状态的麦克风画成开着。
        val stamp = data.getString("state_updated_at", null)?.toLongOrNull()
        val now = System.currentTimeMillis()
        val fresh = stamp != null && now < stamp + STALE_AFTER_MS
        val roomCircleId = data.getString("room_circle_id", null) ?: ""
        val inRoom = data.getBoolean("in_room", false) && fresh && roomCircleId.isNotEmpty()
        val muted = if (inRoom) data.getBoolean("muted", true) else true

        for (id in appWidgetIds) {
            // 共享数据缺失(首次安装 / 进程被清 / 读取失败)-> 退化到中性占位文案
            val hasPrimary = data.getBoolean("has_primary", true)
            val title = data.getString("circle_name", null)
                ?: context.getString(R.string.widget_title_default)
            val presence = data.getString("presence_text", null)
                ?: context.getString(R.string.widget_presence_default)

            val views = RemoteViews(context.packageName, R.layout.lares_widget).apply {
                setTextViewText(R.id.widget_title, title)
                setTextViewText(R.id.widget_presence, presence)
                // 没有主圈子(圈子列表为空):不打余烬标记,主操作改为「建个圈」
                setViewVisibility(
                    R.id.widget_primary_mark,
                    if (hasPrimary) View.VISIBLE else View.GONE,
                )
                setTextViewText(
                    R.id.widget_action,
                    context.getString(
                        if (hasPrimary) R.string.widget_action_join
                        else R.string.widget_action_open
                    ),
                )

                // 点 Widget 任意处:拉起 App 并带 lares://join 深链,直达主圈子
                val intent = Intent(context, MainActivity::class.java).apply {
                    setData(Uri.parse("lares://join"))
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                }
                val pending = PendingIntent.getActivity(
                    context,
                    REQ_OPEN,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                setOnClickPendingIntent(R.id.widget_root, pending)

                // 在房:显示麦克风按钮,隐藏「进圈」;不在房反过来。
                setViewVisibility(R.id.widget_action, if (inRoom) View.GONE else View.VISIBLE)
                setViewVisibility(R.id.widget_mic, if (inRoom) View.VISIBLE else View.GONE)
                if (inRoom) {
                    setTextViewText(
                        R.id.widget_mic,
                        context.getString(if (muted) R.string.widget_mic_muted else R.string.widget_mic_on),
                    )
                    setInt(
                        R.id.widget_mic,
                        "setBackgroundResource",
                        if (muted) R.drawable.widget_mic_muted_bg else R.drawable.widget_mic_on_bg,
                    )
                    setTextColor(
                        R.id.widget_mic,
                        if (muted) 0xFFF2EEE9.toInt() else 0xFF1A120C.toInt(),
                    )
                    // 显式指定接收器 + exported=false:只有本 App 能发这条广播。
                    val toggle = Intent(context, WidgetActionReceiver::class.java).apply {
                        action = WidgetActionReceiver.ACTION_TOGGLE_MUTE
                        putExtra(WidgetActionReceiver.EXTRA_CIRCLE_ID, roomCircleId)
                    }
                    val togglePending = PendingIntent.getBroadcast(
                        context,
                        REQ_MIC,
                        toggle,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    )
                    setOnClickPendingIntent(R.id.widget_mic, togglePending)
                }
            }
            appWidgetManager.updateAppWidget(id, views)
        }

        scheduleStaleRefresh(context, if (inRoom && stamp != null) stamp + STALE_AFTER_MS else null)
    }

    /**
     * 在房时约一个「心跳过期」时刻的刷新。App 被杀后没人会来 updateWidget,
     * 不约这一下,麦克风按钮会一直挂在那里,直到下次系统碰巧刷新。
     *
     * 用不精确闹钟(set,非 setExact):不需要 SCHEDULE_EXACT_ALARM 权限,
     * 晚几分钟无妨 —— 过期之后按钮点下去也只会得到「App 没在运行」的如实回应。
     * 每次 onUpdate 都重排(FLAG_UPDATE_CURRENT 覆盖同一个),心跳续上就往后推。
     */
    private fun scheduleStaleRefresh(context: Context, at: Long?) {
        val alarm = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(ComponentName(context, LaresWidgetProvider::class.java))
        val intent = Intent(context, LaresWidgetProvider::class.java).apply {
            action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
        }
        val pending = PendingIntent.getBroadcast(
            context,
            REQ_STALE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        if (at == null || ids.isEmpty()) {
            alarm.cancel(pending)
            return
        }
        // +1 秒:确保醒来时已经严格越过过期点。
        alarm.set(AlarmManager.RTC, at + 1000L, pending)
    }
}
