package io.github.imzlzl.dsh_mobile

import android.app.Activity
import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Environment
import io.flutter.plugin.common.MethodChannel

/**
 * 新版本下载（`dsh/app-update`）。
 *
 * ## 为什么是系统 DownloadManager，而不是自己写下载
 *
 * 断点续传、通知、下载完成后"点开即安装"都是系统那套的事；自己写一遍只会多一个
 * 会过期的下载器，还要求存储权限。交给 DownloadManager 之后**入队即返回**，
 * 进度与完成通知都由系统给 —— 这也是"检查更新"之后**直接下载**的那一半。
 *
 * ## 为什么落到公共下载目录
 *
 * `Downloads/dsh-mobile-<tag>-<abi>.apk`：用户在文件管理器里能自己找到它重装，
 * 而"App 私有目录"里那份用户看不见。发布物是按 ABI 拆包的（`release.yml` 的
 * `--split-per-abi`），文件名本身就是有用的信息，不改名。
 *
 * ## GitHub 的资产地址是 302
 *
 * `browser_download_url` 会跳一次到 `objects.githubusercontent.com`，
 * DownloadManager 会自己跟。**不要**为了"少一跳"在这里改写 URL ——
 * 那一跳的签名参数是 GitHub 生成的，猜不出来。
 */
object DshAppUpdate {
    /**
     * 由 `MainActivity` 在注册通道时调用。
     *
     * 收 [Activity] 而不是 `Context`：`DownloadManager` 与通知的归属都以
     * 应用为界，而 `this` 就是它 —— 与 `registerNotifications` 同一写法。
     */
    fun attach(activity: Activity, channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "download" -> {
                    val url = call.argument<String>("url")
                    val fileName = call.argument<String>("fileName")
                    if (url.isNullOrBlank() || fileName.isNullOrBlank()) {
                        result.error("bad-args", "download 需要 url 与 fileName", null)
                    } else {
                        try {
                            result.success(enqueue(activity, url, fileName))
                        } catch (error: Exception) {
                            result.error(
                                "download-failed",
                                error.message ?: error.javaClass.simpleName,
                                null,
                            )
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 入队并返回系统给的任务 id（> 0 = 已受理）。 */
    private fun enqueue(context: Context, url: String, fileName: String): Long {
        val request = DownloadManager.Request(Uri.parse(url))
            .setTitle(fileName)
            .setDescription("正在下载新版本")
            // 下载中与完成后都在通知栏：完成那一条点开就是系统安装器。
            .setNotificationVisibility(
                DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED,
            )
            .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, fileName)
            .setMimeType("application/vnd.android.package-archive")
        val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        return manager.enqueue(request)
    }
}
