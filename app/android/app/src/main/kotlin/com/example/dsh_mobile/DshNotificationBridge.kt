package com.example.dsh_mobile

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/**
 * 原生 → Dart 的**唯一**回话口（通知上的按钮、通知被点开）。
 *
 * ## 为什么是全局单例
 *
 * 广播接收器由系统实例化（不是我们自己 new 的），它拿不到 Activity，
 * 也就拿不到那个 `MethodChannel`。所以通道在 `MainActivity.configureFlutterEngine`
 * 里注册时**登记到这里**，接收器从这里取。
 *
 * ## 引擎不在时是"空"，不是"兜底"
 *
 * `channel == null` 表示**没有 Dart 在听**（Activity/引擎已销毁）。这时
 * `approve()` 直接返回 `false`，调用方（接收器）据此什么都不做 ——
 * 不排队、不落盘、不模拟成功。用户重开 App 之后那张卡仍然待处理，
 * 这正是 DSH 原生语义（审批没有超时，没人答就一直等）。
 */
object DshNotificationBridge {
    private var channel: MethodChannel? = null

    /** 由 `MainActivity` 在注册通道时调用。 */
    fun attach(channel: MethodChannel) {
        this.channel = channel
    }

    /** 由 `MainActivity` 在 `cleanUpFlutterEngine` 里调用。 */
    fun detach() {
        channel = null
    }

    /**
     * 通知上的审批按钮：`outcome` 是 **DSH 的 outcome 值**
     * （`allowed-once` / `deny`，`user-approval/src/types.ts:32`）。
     *
     * 返回 `false` = 没有 Dart 在听（见文件头）。**调用方必须真的处理这个 false**，
     * 不能因为"发过了"就以为答上了。
     */
    fun approve(itemId: String, outcome: String): Boolean {
        val target = channel ?: return false
        Handler(Looper.getMainLooper()).post {
            target.invokeMethod(
                "approval",
                mapOf("itemId" to itemId, "outcome" to outcome),
            )
        }
        return true
    }

    /** 通道是否有人听（Dart 侧 `status` 用它报"现在是前台还是后台"）。 */
    fun attached(): Boolean = channel != null
}
