package com.example.dsh_mobile

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 前台服务：**保住进程**，好让那条 WebSocket 在 App 退到后台之后还活着。
 *
 * ## 类型为什么是 `remoteMessaging`
 *
 * Android 14+ 必须声明类型（官方文档《Foreground service types》首段）。
 * 三选一的判据（全部来自平台文档，见
 * `.agents/notes/proposed/2026-10-24-notifications-and-ui-gaps.md` §1.2）：
 *
 * | 类型 | 时限 | 判据 |
 * |---|---|---|
 * | `dataSync` | **24 小时内累计 6 小时**，超了调 `onTimeout`、再起抛 `ForegroundServiceStartNotAllowedException`；且属性文档直接写 *"this type should NOT be used"*（targetSdk≥34） | **不选** |
 * | `specialUse` | 无时限 | 要 `<property>` 子类型 + Play 审核；我们侧载不走 Play，但语义不诚实 —— 备选 |
 * | `remoteMessaging` | **无时限** | 平台原文 *"Transfer text messages from one device to another. Assists with continuity of a user's messaging tasks when they switch devices."* —— 这是"两台自己的设备之间接力会话"，**选它** |
 *
 * ## 什么时候起、什么时候停
 *
 * **不在这里判断**：起停完全由 Dart 侧决定（`lib/platform/notify.dart` 的
 * `startKeepAlive` / `stopKeepAlive`），因为"现在该不该保活"的唯一真值是连接
 * 状态机与用户的授权，而它们都在 Dart。这个服务只做两件事：
 * `startForeground` 挂上常驻通知、以及在 `onDestroy` 里如实收尾。
 *
 * ## 手动杀掉就是杀掉
 *
 * 用户从最近任务里划掉 → 宿主 Activity 被 finish → Flutter 引擎随之销毁 →
 * Dart 侧连接与服务一起结束。**不做"缓存引擎"那一套**（`FlutterEngineCache`）：
 * 它能把 Dart 活到划掉之后，但代价是改 App 启动形态（引擎搬到 Application），
 * 而用户要的语义正是"手动杀了才没"。
 */
class DshForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        DshNotifications.ensureChannels(this)
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "DeepSeek Harness"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "正在后台保持与电脑的连接"
        val notification = DshNotifications.buildRunning(this, title, text)
        if (Build.VERSION.SDK_INT >= 34) {
            // 类型只能在 34+ 用（`FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING` 是 API 34
            // 引入的；29–33 传一个未定义的类型会被拒）。
            startForeground(
                DshNotifications.RUNNING_NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING,
            )
        } else {
            startForeground(DshNotifications.RUNNING_NOTIFICATION_ID, notification)
        }
        // **不 sticky**：进程被系统回收时不要让系统拿一个没有 Dart 的壳再起来
        // ——那会挂一条"看起来在保活、其实没连"的假通知。
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        // 通知跟着服务走：`stopForeground(STOP_FOREGROUND_REMOVE)` 由系统在
        // 服务销毁时一起处理，这里只补一次显式撤除，避免个别 ROM 留下残影。
        DshNotifications.cancel(this, DshNotifications.RUNNING_NOTIFICATION_ID)
        super.onDestroy()
    }

    companion object {
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"

        fun start(context: Context, title: String, text: String) {
            val intent = Intent(context, DshForegroundService::class.java).apply {
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, DshForegroundService::class.java))
        }
    }
}
