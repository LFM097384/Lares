package com.example.lares_app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 自动更新的 Android 原生侧:把下载好的 APK 交给系统包安装器。
 *
 * 为什么必须落到 Kotlin:
 * 从 Android 7(N)起,直接把 `file://` URI 丢给安装器会抛
 * FileUriExposedException。正确做法是经 FileProvider 生成 `content://` URI,
 * 并给接收方授予 FLAG_GRANT_READ_URI_PERMISSION —— 这三件事都没法在 Dart 侧做。
 *
 * 本类**只**做这一件事,不持有 Activity,不改动既有深链逻辑。
 */
class LaresUpdatePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        /** 与 Dart 侧 AndroidInstaller._channel 保持一致 */
        const val CHANNEL = "lares/update"

        /**
         * 必须与 AndroidManifest.xml 里 <provider> 的 authorities 完全一致。
         * 用 ${applicationId} 派生,避免与任何第三方库的 authority 撞车。
         */
        fun authorityOf(context: Context): String = "${context.packageName}.updateprovider"
    }

    private var channel: MethodChannel? = null
    private var appContext: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "installApk" -> installApk(call, result)
            // 供 Dart 侧在需要时判断是否已获得「安装未知应用」许可
            "canRequestInstall" -> {
                val ctx = appContext
                if (ctx == null) {
                    result.success(false)
                } else {
                    val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        ctx.packageManager.canRequestPackageInstalls()
                    } else {
                        true
                    }
                    result.success(ok)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun installApk(call: MethodCall, result: MethodChannel.Result) {
        val ctx = appContext
        if (ctx == null) {
            result.error("NO_CONTEXT", "插件未附着到引擎", null)
            return
        }
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) {
            result.error("BAD_ARGS", "缺少 APK 路径", null)
            return
        }
        val file = File(path)
        if (!file.exists()) {
            result.error("NOT_FOUND", "APK 文件不存在:$path", null)
            return
        }

        try {
            val uri: Uri = FileProvider.getUriForFile(ctx, authorityOf(ctx), file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                // 读权限授予系统安装器;NEW_TASK 是从 application context 启动的必需项
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            ctx.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("INSTALL_FAILED", e.message, null)
        }
    }
}
