package io.github.imzlzl.dsh_mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper

/**
 * 通知上的按钮按下来之后，把动作**交给 Dart**。
 *
 * ## 为什么是广播而不是打开 App
 *
 * 通知上的「允许一次 / 拒绝」必须**在通知栏里就答完** —— 打开 App 再去找那张卡
 * 就不叫"直接答"了。所以按钮挂的是 `PendingIntent.getBroadcast`（明确指向本接收器），
 * 接收器再把 `{itemId, outcome}` 交给 Dart 侧那个 MethodChannel。
 *
 * ## 为什么必须有前台服务在跑才有意义
 *
 * 这个接收器**不自己发网络请求**：答复只能走既有的唯一出口
 * `interaction.respond`（契约 §5.7），而它住在 Dart 的连接里。
 * 连接活在 Flutter 引擎里，引擎跟着 Activity 走 —— 而"通知存在"这件事本身
 * 就依赖前台服务活着。所以二者的生命周期是同一个：
 * **有通知 ⇒ 有服务 ⇒ 有引擎 ⇒ 有连接**。
 *
 * 引擎真的不在时（用户刚划掉任务）`DshNotificationBridge` 是空的，
 * 这里**什么都不做**：那条通知随即被系统撤掉，用户重开 App 会看到那张卡
 * 仍然待处理 —— 与"没人答就一直等"同一条（审批在 DSH 侧没有超时）。
 */
class DshActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        val itemId = intent.getStringExtra(EXTRA_ITEM_ID)
        val notificationId = intent.getIntExtra(EXTRA_NOTIFICATION_ID, 0)
        if (action == ACTION_DISMISS) {
            DshNotifications.cancel(context, notificationId)
            return
        }
        if (itemId.isNullOrEmpty()) return
        val outcome = when (action) {
            ACTION_ALLOW_ONCE -> "allowed-once"
            ACTION_DENY -> "deny"
            else -> return
        }
        // 撤得快一点：用户已经表态，提示不该还挂在那儿（真正的撤销由 Dart 侧
        // 收到答复后的 `cancel` 兜，这一句只是先手）。
        DshNotifications.cancel(context, notificationId)
        val bridge = DshNotificationBridge
        // `invokeMethod` 必须在主线程 —— 广播是在主线程投递的，但显式排队更稳
        // （个别 ROM 会从别的 displatcher 递送）。
        Handler(Looper.getMainLooper()).post {
            bridge.approve(itemId, outcome)
        }
    }

    companion object {
        const val ACTION_ALLOW_ONCE = "com.example.dsh_mobile.ALLOW_ONCE"
        const val ACTION_DENY = "com.example.dsh_mobile.DENY"
        const val ACTION_DISMISS = "com.example.dsh_mobile.DISMISS"
        const val EXTRA_ITEM_ID = "itemId"
        const val EXTRA_NOTIFICATION_ID = "notificationId"
    }
}
