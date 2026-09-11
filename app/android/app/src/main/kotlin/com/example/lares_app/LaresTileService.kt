package com.example.lares_app

import android.content.Intent
import android.net.Uri
import android.service.quicksettings.TileService

/**
 * Quick Settings Tile:下拉状态栏点一下,直达进房(§4.2 安卓双入口)。
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
