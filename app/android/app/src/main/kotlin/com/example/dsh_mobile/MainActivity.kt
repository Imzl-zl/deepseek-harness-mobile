package com.example.dsh_mobile

import android.app.Activity
import android.content.Intent
import android.graphics.Rect
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import kotlin.concurrent.thread

/**
 * 两个平台通道都在这里，**都不引第三方插件**。
 *
 * 理由：`app/` 下只有 `android/` / `ios/` / `windows/` 三个工程
 * （**没有 `ohos/`**），而本仓 Flutter 版本的上界是留给鸿蒙 fork 的。
 * 引一个走平台通道的第三方插件，等于把"鸿蒙能不能编过"交给别人的发布节奏；
 * 而这两个能力在 Android 侧各只有几十行。先例是
 * `dsh/gesture-exclusion`（2026-10-16 立的）。
 */
class MainActivity : FlutterActivity() {
    private val gestureChannelName = "dsh/gesture-exclusion"
    private val photoChannelName = "dsh/photo-picker"

    /** 选图请求的 requestCode（与本文件其它 startActivityForResult 区分）。 */
    private val pickImageRequest = 4711

    /**
     * 选图期间挂起的回包。
     *
     * `FlutterActivity` 继承 `android.app.Activity`（不是 `ComponentActivity`），
     * 所以拿不到 `registerForActivityResult`；只能走
     * `startActivityForResult` + `onActivityResult`，于是要自己把
     * `MethodChannel.Result` 存一下（它只能被调用一次）。
     */
    private var pendingPick: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerGestureExclusion(flutterEngine)
        registerPhotoPicker(flutterEngine)
    }

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
    private fun registerGestureExclusion(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, gestureChannelName)
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
                        android.util.Log.i("DSHGesture", "setRects: $rects")
                        // 用 decorView 而不是 window：View 版 API 会替我们做坐标换算，
                        // 而 decorView 的坐标系就是窗口坐标系（左上角 0,0）。
                        window.decorView.systemGestureExclusionRects = rects
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 选一张图，回 `{mediaType, data(base64), name, byteCount}`；用户取消回 `null`。
     *
     * ## 为什么用系统照片选择器，而不是自造相册
     *
     * - **API 33+ 用 `MediaStore.ACTION_PICK_IMAGES`**：系统照片选择器，
     *   **不需要任何权限**（Google 明确说它取代 `READ_MEDIA_IMAGES`），
     *   而且只把用户选中的那一张交给我们。
     * - API 33 以下退到 `ACTION_GET_CONTENT`：走 SAF，同样**不需要权限**。
     *
     * **两条路都不申请权限**，所以这份实现里没有 `requestPermissions`，
     * `AndroidManifest.xml` 也没有多加任何权限 —— 少一个用户会被弹窗打扰的地方。
     *
     * ## 为什么把字节读成 base64 回给 Dart
     *
     * DSH 的 `PromptContentPart` 图片就是这样：
     * `{type:'image', mediaType, data(base64), name?}`
     * （`packages/api/session-controller/src/types.ts:90-98`，内联直发、
     * 不需要先上传）。而且 `content://` 的读权限只在这段回调窗口内有效 ——
     * 立刻读完，不留 URI 生命周期的坑。
     *
     * **媒体类型原样回**（不在这里过滤）：DSH 只认 png/jpeg/webp/gif，
     * 而"哪些该拒"是**业务判断**，放在 Dart 侧可测。
     */
    private fun registerPhotoPicker(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, photoChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickImage" -> {
                        if (pendingPick != null) {
                            result.error("busy", "上一次选图还没返回", null)
                            return@setMethodCallHandler
                        }
                        pendingPick = result
                        val intent = if (Build.VERSION.SDK_INT >= 33) {
                            Intent(MediaStore.ACTION_PICK_IMAGES).apply { type = "image/*" }
                        } else {
                            Intent(Intent.ACTION_GET_CONTENT).apply {
                                type = "image/*"
                                addCategory(Intent.CATEGORY_OPENABLE)
                            }
                        }
                        try {
                            startActivityForResult(intent, pickImageRequest)
                        } catch (error: Exception) {
                            // 设备上没有能处理这个 intent 的 Activity（少见，但如实回）。
                            pendingPick = null
                            result.error("unavailable", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("FlutterActivity 继承 Activity，拿不到 registerForActivityResult")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != pickImageRequest) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingPick
        pendingPick = null
        if (result == null) return
        val uri: Uri? = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            // 用户取消：**不是错误**，回 null，Dart 侧静默什么都不做。
            result.success(null)
            return
        }
        // 读字节要离开 UI 线程（一张几 MB 的图会卡帧）。
        thread(name = "dsh-photo-read") {
            try {
                val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                    ?: throw IOException("打不开选中的图片")
                val payload = mapOf(
                    "mediaType" to (contentResolver.getType(uri) ?: "image/png"),
                    "data" to Base64.encodeToString(bytes, Base64.NO_WRAP),
                    "name" to displayName(uri),
                    "byteCount" to bytes.size,
                )
                runOnUiThread { result.success(payload) }
            } catch (error: Exception) {
                runOnUiThread { result.error("read-failed", error.message, null) }
            }
        }
    }

    /** `content://` 的显示名（取不到给空串，不编一个）。 */
    private fun displayName(uri: Uri): String {
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getString(0) else ""
                } ?: ""
        } catch (_: Exception) {
            ""
        }
    }
}
