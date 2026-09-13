package com.example.lares_app

import android.content.Intent
import android.net.Uri
import android.service.quicksettings.TileService

/**
 * Quick Settings Tile:下拉状态栏点一下,一键加入**主圈子**(§4.2 安卓双入口)。
 *
 * 与主屏 Widget 用同一条 `lares://join` 深链,因此两个入口天然一致 ——
 * 目标圈子都由 App 侧读 CircleStore.primaryCircle 解析,Tile 无需感知圈子。
 */
class LaresTileService : TileService() {
    override fun onClick() {
        super.onClick()
        val intent = Intent(this, MainActivity::class.java).apply {
            setData(Uri.parse("lares://join"))
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        startActivityAndCollapse(intent)
    }
}
