package com.example.lares_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin

/**
 * 主屏幕 Widget:圈子名 + 在线状态,点一下直接进房(设计.md §3.2-1)。
 * 数据由 Flutter 侧通过 HomeWidget.saveWidgetState 推送。
 */
class LaresWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) {
            val data = HomeWidgetPlugin.getData(context)
            val title = data.getString("circle_name", null) ?: "我们的圈"
            val presence = data.getString("presence_text", null) ?: "暂无人在,进去等等看?"

            val views = RemoteViews(context.packageName, R.layout.lares_widget).apply {
                setTextViewText(R.id.widget_title, title)
                setTextViewText(R.id.widget_presence, presence)

                // 点 Widget 任意处:拉起 App 并带 lares://join 深链,直达进房
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
