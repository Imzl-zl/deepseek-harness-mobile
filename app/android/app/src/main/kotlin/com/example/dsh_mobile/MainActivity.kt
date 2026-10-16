package com.example.dsh_mobile

import android.graphics.Rect
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 把"这两块边留给 App"告诉系统 —— Android 10(API 29)的
 * `View.setSystemGestureExclusionRects`。
 *
 * 为什么需要它：左右两条屏幕边是**系统返回手势**的地盘，App 内的边缘滑动
 * （开左右抽屉）会和它抢；实测（2026-10-16，小米 d61cf622）从 ≈15dp 起手的一划
 * 会被系统吃掉、直接把 App 退回桌面。
 *
 * 官方限制（Android Developers《Gesture Navigation: handling gesture conflicts》）：
 * - 只有 API 29+ 有这个 API；
 * - **每条边最多排除 200dp 的总高度**，超了系统只认"最靠下"的那 200dp ——
 *   所以 Dart 侧给的带子高度钉在 192dp（4×48dp 触摸目标，留在上限内）。
 *
 * 坐标是**物理像素**、以窗口左上角为原点（Flutter 侧换算好再传过来）。
 * 低版本 / 其它平台：这个方法直接 no-op（Dart 侧拿 false，不当真）。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "dsh/gesture-exclusion"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setRects" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val flat = call.argument<List<Int>>("rects") ?: emptyList()
                        val rects = ArrayList<Rect>(flat.size / 4)
                        var i = 0
                        while (i + 3 < flat.size) {
                            rects.add(Rect(flat[i], flat[i + 1], flat[i + 2], flat[i + 3]))
                            i += 4
                        }
                        android.util.Log.i(
                            "DSHGesture",
                            "setRects: $rects",
                        )
                        // 用 decorView 而不是 window：View 版 API 会替我们做坐标换算，
                        // 而 decorView 的坐标系就是窗口坐标系（左上角 0,0）。
                        window.decorView.systemGestureExclusionRects = rects
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}