/// 图片附件的**宿主上限**（`session.projections` 的 `imageLimits`，契约 §5.7）。
///
/// ## 为什么这些数只能从电脑侧读
///
/// 它们由 DSH 的附件服务定（`packages/attachment/attachment/src/index.ts:34-46` 的默认值：
/// `maxImageBytes` 50 MB、`maxImagesPerMessage` 20、`maxMessageImageBytes` 200 MB、
/// `maxImagePixels` 64,000,000、`maxImageDimension` 65,535、`mediaTypes` png/jpeg/webp/gif），
/// **而且部署可以改**。手机侧抄一份就是第二份真值：电脑上调小到 5 MB，手机还按 50 MB 放行，
/// 用户会看到"选得上、发出去被拒"。
///
/// 投影由 `session-controller/src/list.ts:98-105` 注册（`wire.view` 就是
/// `ctx.attachments.imageLimits`，schema 在 `list.ts:32-39`），随我们已经调用的
/// `session.projections` 一起到手机 —— **不需要新方法**。
///
/// ## 与"通道层预算"是两件事
///
/// `platform/photo_picker.dart` 里那两个 `kMax*BytesFor*` 描述的是**我们这条管道**
/// （单帧 8 MiB、二进制在线上 ×1.78），是所有者自己定的；本文件的数是**宿主的业务上限**。
/// 两条判据都会生效，也各自说各自的话 —— 谁先撞上就报谁。
library;

/// 宿主的图片附件上限（`ImageAttachmentLimits`，`attachment/src/types.ts:74-82`）。
class DshImageLimits {
  const DshImageLimits({
    required this.maxImageBytes,
    required this.maxImagesPerMessage,
    required this.maxMessageImageBytes,
    this.maxImagePixels = 0,
    this.maxImageDimension = 0,
    this.mediaTypes = const <String>[],
  });

  /// 解析投影里的 `imageLimits`；**认不出就 `null`**（= 不知道上限，不前置拦）。
  ///
  /// 三个字节/张数上限是判据必需项：缺一个就整个当"不知道"，
  /// 因为拿一半的限制作判断会给出"这张能发"的错误结论。
  static DshImageLimits? fromWire(Object? value) {
    if (value is! Map) return null;
    final maxImageBytes = value['maxImageBytes'];
    final maxImagesPerMessage = value['maxImagesPerMessage'];
    final maxMessageImageBytes = value['maxMessageImageBytes'];
    if (maxImageBytes is! int || maxImageBytes <= 0) return null;
    if (maxImagesPerMessage is! int || maxImagesPerMessage <= 0) return null;
    if (maxMessageImageBytes is! int || maxMessageImageBytes <= 0) return null;
    final mediaTypes = value['mediaTypes'];
    final maxImagePixels = value['maxImagePixels'];
    final maxImageDimension = value['maxImageDimension'];
    return DshImageLimits(
      maxImageBytes: maxImageBytes,
      maxImagesPerMessage: maxImagesPerMessage,
      maxMessageImageBytes: maxMessageImageBytes,
      maxImagePixels: maxImagePixels is int && maxImagePixels > 0
          ? maxImagePixels
          : 0,
      maxImageDimension: maxImageDimension is int && maxImageDimension > 0
          ? maxImageDimension
          : 0,
      mediaTypes: mediaTypes is List
          ? mediaTypes.whereType<String>().toList(growable: false)
          : const <String>[],
    );
  }

  /// 单张图片的字节上限。
  final int maxImageBytes;

  /// 一条消息里的图片张数上限。
  final int maxImagesPerMessage;

  /// 一条消息里所有图片的字节合计上限。
  final int maxMessageImageBytes;

  /// 单张图片的像素上限（`0` = 没报，不判）。
  final int maxImagePixels;

  /// 单张图片的长边像素上限（`0` = 没报，不判）。
  final int maxImageDimension;

  /// 允许的媒体类型（空 = 没报，不判）。
  final List<String> mediaTypes;
}

/// 字节数的展示：≥1 MiB 用 MB、≥1 KiB 用 KB、再小就直接给字节。
///
/// **不能一律取 MB**：部署把单图上限调到 1000 字节时，"0.0 MB" 等于什么都没说
/// （用户既看不出上限、也看不出自己差多少）。
String _size(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '$bytes B';
}

/// 选这张图会不会撞上**宿主**的上限：`null` = 放行，否则是那句该说的话。
///
/// **`limits == null`（老连接器 / 投影缺席）时恒放行**：不知道上限就不前置拦，
/// 让 DSH 自己拒 —— 它拒的时候会把码写在错误里（`IMAGES_TOO_LARGE` /
/// `TOO_MANY_IMAGES`），手机原样显示，而不是我们编一句。
///
/// 每次只说**第一条**撞上的限制，并在话里点名是哪一条 —— "超限"两个字
/// 答不了用户"我该删一张还是换一张"。
String? imageLimitViolationOf({
  required DshImageLimits? limits,
  required int images,
  required int incomingBytes,
  required int totalBytes,
  String mediaType = '',
}) {
  if (limits == null) return null;
  if (limits.mediaTypes.isNotEmpty && mediaType.isNotEmpty) {
    final allowed = limits.mediaTypes.map((type) => type.toLowerCase()).toSet();
    if (!allowed.contains(mediaType.toLowerCase())) {
      return '这台电脑不收 $mediaType：只收 ${limits.mediaTypes.join(' / ')}';
    }
  }
  if (images >= limits.maxImagesPerMessage) {
    return '一条消息最多 ${limits.maxImagesPerMessage} 张图：先发出去，或者删掉几张';
  }
  if (incomingBytes > limits.maxImageBytes) {
    return '这张图 ${_size(incomingBytes)}，超过这台电脑的单图上限 '
        '${_size(limits.maxImageBytes)}：换一张小一点的';
  }
  if (totalBytes + incomingBytes > limits.maxMessageImageBytes) {
    return '加上这张，这条消息的图片合计超过这台电脑的上限 '
        '${_size(limits.maxMessageImageBytes)}';
  }
  return null;
}
