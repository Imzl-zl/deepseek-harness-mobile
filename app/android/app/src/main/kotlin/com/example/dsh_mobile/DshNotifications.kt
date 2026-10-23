package com.example.dsh_mobile

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat

/**
 * 通知渠道与通知的构造。
 *
 * ## 渠道就是"声音/震动"的唯一真值
 *
 * 平台规矩（官方文档《Create and manage notification channels》原文）：
 * **渠道一经创建，App 改不了它的重要级/声音/震动 —— 用户有完全控制权**。
 * 所以这里**只负责创建**，不在 App 里再造一套"震动开关"（那必然与系统设置
 * 不一致）。用户想调，走 `dsh/notifications` 的 `openChannelSettings` 跳到系统页。
 *
 * ## 为什么两个渠道
 *
 * - `dsh_running`：前台服务的**常驻通知**（LOW、静音）—— 它只是"这条连接还活着"
 *   的可见凭据，不该响也不该弹；
 * - `dsh_attention`：**要你处理**的通知（DEFAULT、有声）—— 有人等审批、
 *   有提问、或者你不在时那一轮跑完了。
 *
 * 合成一个渠道会让"常驻"和"敲门"共用一个重要级 —— 要么常驻也响，要么敲门不响。
 */
object DshNotifications {
    /** 前台服务的常驻通知渠道（静音）。 */
    const val CHANNEL_RUNNING = "dsh_running"

    /** 需要用户处理的通知渠道（有声）。 */
    const val CHANNEL_ATTENTION = "dsh_attention"

    /** 常驻通知的固定 id（停服务时按它撤）。 */
    const val RUNNING_NOTIFICATION_ID = 1001

    /**
     * 创建两个渠道。**幂等**：重复创建同名渠道是 no-op（官方原文：
     * "Recreating an existing notification channel with its original values
     * performs no operation"）。
     */
    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val running = NotificationChannel(
            CHANNEL_RUNNING,
            "后台保活",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "App 退到后台时保持与电脑的连接（只在跑动中才有意义）"
            setShowBadge(false)
            enableVibration(false)
            enableLights(false)
        }
        val attention = NotificationChannel(
            CHANNEL_ATTENTION,
            "需要你处理",
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "有人等你审批、有人在问你，或者你不看着的时候那一轮跑完了"
        }
        manager.createNotificationChannels(listOf(running, attention))
    }

    /** 常驻通知（前台服务那张，不可滑掉）。 */
    fun buildRunning(context: Context, title: String, text: String) =
        NotificationCompat.Builder(context, CHANNEL_RUNNING)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

    /** 撤掉某条通知（不存在就 no-op）。 */
    fun cancel(context: Context, id: Int) {
        context.getSystemService(NotificationManager::class.java)?.cancel(id)
    }
}
