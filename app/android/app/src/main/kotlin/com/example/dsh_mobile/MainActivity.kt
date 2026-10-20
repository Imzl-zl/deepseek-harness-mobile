package com.example.dsh_mobile

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Rect
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Base64
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
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

    /**
     * 单张图片**原样通过**的字节阈值。
     *
     * **算出来的，不是估的**：契约 §40 / `connector/src/transport/codec.ts:53,77`
     * 规定**单帧上限 8 MiB**（超了接收侧 `protocol/bad-frame` **并关闭连接**）。
     * 二进制载荷在线上要过两次 1.33 倍膨胀（JSON 的 base64 + `box` 的 base64url），
     * 一帧 ≈ **1.78 ×** 原始字节。
     *
     * 而**一条消息的所有图片合起来只占一帧**，所以单张的阈值必须远小于
     * 整条消息的预算（3 MiB）：取 **1.5 MiB** —— 这样压过的图 ≤1 MiB，
     * 一条消息能放几张（Dart 侧 `fitsMessageBudget` 按合计放行）。
     * 单张给 3 MiB 是 2026-10-20 自查前的错：两张就 6 MiB ≈ 10.7 MB 的帧。
     */
    private val MAX_RAW_IMAGE_BYTES = 1536 * 1024

    /** 重编码时的最长边。按"主流视觉模型按 ~1.5k 像素切块"取。 */
    private val MAX_IMAGE_EDGE = 1600

    /** 重编码目标字节（1 MiB × 1.78 ≈ 1.8 MiB/张，3 张 ≈ 5.3 MiB，仍在一帧之内）。 */
    private val TARGET_IMAGE_BYTES = 1024 * 1024

    /** 选图（相册）请求的 requestCode。 */
    private val pickGalleryRequest = 4711

    /** 拍照请求的 requestCode。 */
    private val takePictureRequest = 4713

    /** 相机权限请求的 requestCode。 */
    private val cameraPermissionRequest = 4712

    /**
     * 选图/拍照期间挂起的回包。
     *
     * `FlutterActivity` 继承 `android.app.Activity`（不是 `ComponentActivity`），
     * 所以拿不到 `registerForActivityResult`；只能走
     * `startActivityForResult` + `onActivityResult`，于是要自己把
     * `MethodChannel.Result` 存一下（它只能被调用一次）。
     */
    private var pendingPick: MethodChannel.Result? = null

    /** 这次是相册还是拍照（决定回包怎么读）。 */
    private var pendingCamera = false

    /** 拍照写进这个临时文件；读完即删。 */
    private var pendingCaptureFile: File? = null

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
     * 选一张图（相册或拍照），回
     * `{mediaType, data(base64), name, byteCount}`；用户取消回 `null`。
     *
     * ## 相册：系统照片选择器，**不申请权限**
     *
     * - API 33+ 用 `MediaStore.ACTION_PICK_IMAGES`：系统照片选择器，
     *   **不需要任何权限**（Google 明确说它取代 `READ_MEDIA_IMAGES`），
     *   而且只把用户选中的那一张交给我们。
     * - API 33 以下退 `ACTION_GET_CONTENT`：走 SAF，同样**不需要权限**。
     *
     * ## 拍照：**必须先有 CAMERA**
     *
     * 这一点容易漏：`AndroidManifest.xml` **已经为配对页的扫一扫声明了
     * `CAMERA`**（那是另一个功能）。而 Android 的规矩是 ——
     * **一旦应用声明了 CAMERA 权限，`ACTION_IMAGE_CAPTURE` 就要求它已授予**，
     * 否则抛 `SecurityException`
     * （MediaStore.ACTION_IMAGE_CAPTURE 的官方文档原话）。
     * 所以这里先查、没授予就申请，授予了才发 intent。
     *
     * `EXTRA_OUTPUT` 走 `FileProvider`（`cacheDir/dsh_photo/`）：
     * API 24+ 给 `file://` 会抛 `FileUriExposedException`。
     *
     * ## 为什么把字节读成 base64 回给 Dart
     *
     * DSH 的 `PromptContentPart` 图片就是这样：
     * `{type:'image', mediaType, data(base64), name?}`
     * （`packages/api/session-controller/src/types.ts:90-98`，内联直发、
     * 不需要先上传）。而 `content://` 的读权限只在这段回调窗口内有效 ——
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
                        val source = call.argument<String>("source") ?: "gallery"
                        if (pendingPick != null) {
                            result.error("busy", "上一次选图还没返回", null)
                            return@setMethodCallHandler
                        }
                        if (source == "camera") {
                            startCameraPick(result)
                        } else {
                            startGalleryPick(result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startGalleryPick(result: MethodChannel.Result) {
        pendingPick = result
        pendingCamera = false
        val intent = if (Build.VERSION.SDK_INT >= 33) {
            Intent(MediaStore.ACTION_PICK_IMAGES).apply { type = "image/*" }
        } else {
            Intent(Intent.ACTION_GET_CONTENT).apply {
                type = "image/*"
                addCategory(Intent.CATEGORY_OPENABLE)
            }
        }
        launch(intent, pickGalleryRequest, result)
    }

    /**
     * 拍照。**权限先行** —— 见 [registerPhotoPicker] 的说明：
     * 声明了 CAMERA 之后，没授予就发 `ACTION_IMAGE_CAPTURE` 会抛
     * `SecurityException`。
     */
    private fun startCameraPick(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED
        ) {
            // 先把回包存着，权限回来之后再决定发 intent 还是报错。
            pendingPick = result
            pendingCamera = true
            requestPermissions(arrayOf(Manifest.permission.CAMERA), cameraPermissionRequest)
            return
        }
        launchCamera(result)
    }

    private fun launchCamera(result: MethodChannel.Result) {
        pendingPick = result
        pendingCamera = true
        val dir = File(cacheDir, "dsh_photo").apply { mkdirs() }
        val file = File(dir, "capture-${System.currentTimeMillis()}.jpg")
        pendingCaptureFile = file
        val uri = FileProvider.getUriForFile(this, "$packageName.dshfileprovider", file)
        val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
            putExtra(MediaStore.EXTRA_OUTPUT, uri)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            // 有些机型只认 clipData 里的授权（社区踩过的坑），一起给上。
            clipData = ClipData.newRawUri("", uri)
        }
        launch(intent, takePictureRequest, result)
    }

    private fun launch(intent: Intent, requestCode: Int, result: MethodChannel.Result) {
        try {
            startActivityForResult(intent, requestCode)
        } catch (error: Exception) {
            // 设备上没有能处理这个 intent 的 Activity（少见，但如实回）。
            pendingPick = null
            pendingCaptureFile = null
            result.error("unavailable", error.message, null)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode != cameraPermissionRequest) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
            return
        }
        val result = pendingPick
        pendingPick = null
        if (result == null) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (granted) {
            launchCamera(result)
        } else {
            // **不静默**：Dart 侧会把它显示成一句人话。
            result.error("camera-permission", "没有相机权限，拍不了照", null)
        }
    }

    @Deprecated("FlutterActivity 继承 Activity，拿不到 registerForActivityResult")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != pickGalleryRequest && requestCode != takePictureRequest) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingPick
        pendingPick = null
        val camera = pendingCamera
        val captureFile = pendingCaptureFile
        pendingCaptureFile = null
        if (result == null) return

        if (resultCode != Activity.RESULT_OK) {
            // 用户取消：**不是错误**，回 null，Dart 侧静默什么都不做。
            captureFile?.delete()
            result.success(null)
            return
        }

        // 相册给 URI，拍照给临时文件（`EXTRA_OUTPUT` 写进去的）。
        val uri: Uri? = if (camera) {
            captureFile?.let { FileProvider.getUriForFile(this, "$packageName.dshfileprovider", it) }
        } else {
            data?.data
        }
        if (uri == null) {
            captureFile?.delete()
            result.error("read-failed", "拿不到选中的图片", null)
            return
        }
        // 读字节要离开 UI 线程（一张几 MB 的图会卡帧，压缩更慢）。
        thread(name = "dsh-photo-read") {
            try {
                val raw = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                    ?: throw IOException("打不开选中的图片")
                val declared = contentResolver.getType(uri)
                    ?: if (camera) "image/jpeg" else "image/png"
                // **过大就先压**（否则会撞 8 MiB 单帧上限，见 encodeForTransport 的说明）。
                val (bytes, mediaType) = encodeForTransport(raw, declared)
                val payload = mapOf(
                    "mediaType" to mediaType,
                    "data" to Base64.encodeToString(bytes, Base64.NO_WRAP),
                    "name" to if (camera) "" else displayName(uri),
                    "byteCount" to bytes.size,
                )
                // 临时文件读完即删（它只是 `EXTRA_OUTPUT` 的落盘中转）。
                captureFile?.delete()
                runOnUiThread { result.success(payload) }
            } catch (error: ImageTooLarge) {
                captureFile?.delete()
                runOnUiThread { result.error("image-too-large", error.message, null) }
            } catch (error: Exception) {
                captureFile?.delete()
                runOnUiThread { result.error("read-failed", error.message, null) }
            }
        }
    }

    /** 原图超过通路上限时抛它（Dart 侧会显示成一句人话）。 */
    private class ImageTooLarge(message: String) : Exception(message)

    /**
     * 把一张图压到"整帧塞得进 8 MiB"的尺寸。
     *
     * ## 为什么必须压（这是算出来的，不是保险起见）
     *
     * 契约 §40 与 `connector/src/transport/codec.ts:53,77`：**单帧上限 8 MiB**，
     * 超了发送侧不得发出、接收侧收下即 `protocol/bad-frame` **并关闭连接**。
     *
     * 而图片在线上要过**两次** 1.33 倍膨胀：
     * 原始字节 `N` → JSON 里的 base64 `1.33N` → 密文 ≈ `1.33N`
     * → `box` 的 base64url（`协议 §132`：`base64url(密文 ‖ 16 字节 tag)`）
     * **再乘 1.33** ⇒ **一帧 ≈ 1.78N**。
     *
     * 所以 `N = 5 MB` 的手机照片 ≈ **8.9 MB 的帧** —— 直接把连接打断。
     * 单张阈值取 1.5 MiB（见 [MAX_RAW_IMAGE_BYTES]），**整条消息的合计**
     * 由 Dart 侧的 `fitsMessageBudget` 守在 3 MiB。
     *
     * ## 小图原样过
     *
     * 只有超阈值才重编码：那样 PNG 的透明与 GIF 的动画都保住了
     * （重编码只能出 JPEG，会丢透明）。
     *
     * **尺寸目标**不是 DSH 的 `maxImageDimension`（那是部署解析的、手机不知道），
     * 而是"能塞进我们自己的帧"这个**已知**约束；1600 像素的最长边另按
     * "主流视觉模型按 ~1.5k 切块"取，属于我们自己的选择，不是猜 DSH 的限额。
     */
    private fun encodeForTransport(
        raw: ByteArray,
        declared: String,
    ): Pair<ByteArray, String> {
        if (raw.size <= MAX_RAW_IMAGE_BYTES) return raw to declared
        // 只读图片头拿尺寸，不分配像素。
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(raw, 0, raw.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            // 解不了（HEIC 之类）却又超大：**如实报错**，绝不发一个超限的帧。
            throw ImageTooLarge("这张图 ${raw.size / 1024} KB，太大且这台设备压不了")
        }
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_IMAGE_EDGE) {
            sample *= 2
        }
        val decoded = BitmapFactory.decodeByteArray(
            raw,
            0,
            raw.size,
            BitmapFactory.Options().apply { inSampleSize = sample },
        ) ?: throw ImageTooLarge("这张图压不了（解码失败）")

        var edge = MAX_IMAGE_EDGE
        var quality = 85
        var out = compressJpeg(scaleDown(decoded, edge), quality)
        while (out.size > TARGET_IMAGE_BYTES) {
            if (quality > 45) {
                quality -= 20
            } else if (edge > 640) {
                edge = edge * 3 / 4
                quality = 75
            } else {
                break
            }
            out = compressJpeg(scaleDown(decoded, edge), quality)
        }
        // 循环里反复用 `decoded` 做源，所以到这里才回收（`createScaledBitmap`
        // 可能返回同一个对象，判一下再 recycle）。
        decoded.recycle()
        if (out.size > MAX_RAW_IMAGE_BYTES) {
            throw ImageTooLarge("这张图压到 ${out.size / 1024} KB 仍然太大")
        }
        return out to "image/jpeg"
    }

    /** 最长边缩到 [edge] 以内（已经更小就原样回）。 */
    private fun scaleDown(bitmap: Bitmap, edge: Int): Bitmap {
        val longest = maxOf(bitmap.width, bitmap.height)
        if (longest <= edge) return bitmap
        val ratio = edge.toFloat() / longest
        val width = maxOf(1, (bitmap.width * ratio).toInt())
        val height = maxOf(1, (bitmap.height * ratio).toInt())
        return Bitmap.createScaledBitmap(bitmap, width, height, true)
    }

    private fun compressJpeg(bitmap: Bitmap, quality: Int): ByteArray {
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, stream)
        return stream.toByteArray()
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
