package com.example.lares_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
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
 */
class LaresWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) {
            val data = HomeWidgetPlugin.getData(context)
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
                    0,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                setOnClickPendingIntent(R.id.widget_root, pending)
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
