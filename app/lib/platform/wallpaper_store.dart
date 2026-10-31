/// 壁纸文件的落盘（App 私有目录，一张图）。
///
/// ## 为什么自己推路径，不引 `path_provider`
///
/// 本工程刻意不加"走平台通道的第三方插件"（先例：`platform/photo_picker.dart`
/// 自己写 `dsh/photo-picker` 通道，理由是鸿蒙 fork 能不能编过不该由别人的发布
/// 节奏决定）。要一个可写目录这件事，`sqflite` 已经给了：
/// `getDatabasesPath()` 返回 App 私有库目录 →
///
/// - Android：`/data/user/0/<pkg>/databases` → 父目录 + `files/appearance/`
/// - iOS：`<Documents>/databases` → 父目录 + `files/appearance/`
///
/// 两处都在 App 私有沙箱里，卸载即清、不被相册权限左右。
///
/// ## 为什么"文件在不在"就是壁纸的真值
///
/// 不加 `device.wallpaper` 这样的偏好键：那会变成两份真值（键说"设了"、
/// 文件却被清掉时无解）。于是这里只做文件读写，**有没有壁纸 = 文件在不在**。
/// 用户从相册选的那张图**另存一份**，不引用相册路径 —— 相册权限被收回
/// 或原图被删时，引用路径会让壁纸某天忽然变白。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// 壁纸的读写口。
class WallpaperStore {
  const WallpaperStore();

  /// 固定文件名。
  ///
  /// **不带扩展名**：写什么格式由选图原生侧定（png / jpeg / webp），
  /// 带一个 `.jpg` 只会骗人。解码器按内容识别，不看扩展名。
  static const String _fileName = 'wallpaper.img';

  Future<File> _file() async {
    final databases = await getDatabasesPath();
    final dir = Directory(p.join(p.dirname(databases), 'files', 'appearance'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, _fileName));
  }

  /// 读出现有的壁纸字节；没有就 `null`（"没有"是正常状态，不是错误）。
  ///
  /// **给字节而不是给 `File`**：`ui/` 不许 import `dart:io`
  /// （`app/tools/verify-platform-boundary.mjs` 的 `ui-no-platform-import`），
  /// 所以装配层把它包成 `MemoryImage` 再交给壁纸层。
  /// 顺带躲开一个坑：`FileImage` 的缓存键是「路径 + scale」，
  /// 同一路径覆盖写之后仍会命中旧图 —— 换字节就等于换了键。
  Future<Uint8List?> load() async {
    final file = await _file();
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  /// 覆盖写一张新壁纸。
  Future<void> save(Uint8List bytes) async {
    final file = await _file();
    await file.writeAsBytes(bytes, flush: true);
  }

  /// 删掉壁纸（没有也当成功）。
  Future<void> clear() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }
}
