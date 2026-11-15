/// 「有没有新版本、该下哪一个」：版本号比较 + 远端应答解析 + APK 挑选
/// （**纯 Dart，零平台**）。
///
/// ## 为什么值得有
///
/// 手机 App 只能从 GitHub Release 拿到 APK，而用户不会天天去刷 Release 页。
/// 这一层回答两个问题：**是不是新版**、**这台设备该下哪个包里那个 APK**。
///
/// ## 发布物是"按 ABI 拆包"的（所以必须挑）
///
/// `release.yml` 用 `flutter build apk --split-per-abi`，产物名是
/// `dsh-mobile-<tag>-<abi>.apk`（`arm64-v8a` / `armeabi-v7a` / `x86_64`）。
/// 装错 ABI 的包装不上（或装上就崩），所以"给个最新 Release 的链接"是不够的 ——
/// 必须按设备的 ABI 选一个。判据在 [apkAssetFor]。
///
/// ## 判据都写死在这里
///
/// 1. **比较按数字段**：`0.2.10 > 0.2.9`（字符串比会得出反的结论）。
/// 2. **预发布不算新**：`0.2.3-rc.1` 不比 `0.2.3` 新。
/// 3. **挑包先精确、后兜底**：`-<abi>.apk` 命中就用它；否则用任意 `.apk`
///    （老版本发的是通用包）；一个都没有 ⇒ `null`（不猜）。
///
/// 远端用哪个源、怎么发请求、怎么下载，是平台层的事（`platform/update_checker.dart`、
/// `platform/app_update_android.dart`）—— 这一层不认识 HTTP，也不认识 Android。
library;

/// 本机 App 版本。**构建期注入**（CI 用 `--dart-define=APP_VERSION=<tag>`），
/// 没注入时是 `dev` —— 不猜一个版本号。
const String kAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'dev',
);

/// GitHub Release 里的一个发布物（只留手机用得上的两个字段）。
class AppAsset {
  const AppAsset({required this.name, required this.url});

  /// 文件名（如 `dsh-mobile-v0.2.17-arm64-v8a.apk`）。
  final String name;

  /// 下载地址（`browser_download_url`）。
  final String url;
}

/// 一次 Release 查询的结论：版本 + 发布物清单。
class AppRelease {
  const AppRelease({required this.version, this.assets = const []});

  /// 版本号（去掉 `v` 前缀）。
  final String version;

  final List<AppAsset> assets;

  /// 这台设备该下载的包；`null` = 这个 Release 没有可用的 APK。
  ///
  /// [abi] 取 Android 的 `Build.SUPPORTED_ABIS[0]`；非 Android（桌面调试）
  /// 传空串 —— 那时退到"任意 `.apk`"。
  AppAsset? assetFor(String abi) => apkAssetFor(assets, abi);
}

/// 一次版本比对的结论（**UI 只读它**）。
class AppUpdate {
  const AppUpdate({
    required this.current,
    this.latest,
    this.downloadUrl,
    this.error,
  });

  /// 本机版本（[kAppVersion]，或测试注入的值）。
  final String current;

  /// 远端最新版本（去掉 `v` 前缀）；`null` = 没查到。
  final String? latest;

  /// 这台设备该下的那个 APK 的地址；`null` = 没有（或本机是 `dev`）。
  final String? downloadUrl;

  /// 查询失败的原话（**不吞**：查不到 ≠ 已是最新）。
  final String? error;

  /// 本机版本能不能参与比对。`dev`（本地构建，没注入 `APP_VERSION`）不能 ——
  /// 拿它去比只会得出"永远有新版本"，那是骚扰开发构建，不是在报事实。
  bool get comparable => current.isNotEmpty && current != 'dev';

  /// 有新版（`latest` 缺失、或本机是 `dev` 时恒 false）。
  bool get hasUpdate =>
      comparable && latest != null && isNewerVersion(current, latest!);

  /// 有一句话状态（查询结论）。
  String get label {
    if (error != null) return '查不到最新版本';
    if (!comparable) return '开发版（不比对版本）';
    if (latest == null) return '还没查过';
    return hasUpdate ? '有新版本 v$latest' : '已是最新';
  }

  /// 版本那一行右侧的字：**一行说完"我是谁 + 有没有新版"**。
  ///
  /// `0.2.17` / `0.2.17 → 0.2.18` / `0.2.17 · 已是最新` / `0.2.17 · 查不到`
  /// （箭头比"有新版本 v0.2.18"短，值列只有 42% 宽，见 `ui/settings_row.dart`）。
  String get rowValue {
    if (error != null) return '$current · 查不到';
    if (!comparable) return current;
    if (latest == null) return current;
    return hasUpdate ? '$current → $latest' : '$current · 已是最新';
  }
}

/// 按**数字段**比较：`latest` 比 `current` 新则为 true。
///
/// 非数字段按 0 处理（`0.2` 与 `0.2.0` 等价）；`-` 之后一律忽略
/// （预发布串不比同号正式版新）。
bool isNewerVersion(String current, String latest) {
  List<int> parse(String value) => value
      .split('-')
      .first
      .split('.')
      .map((part) => int.tryParse(part.trim()) ?? 0)
      .toList(growable: false);
  final a = parse(current);
  final b = parse(latest);
  final length = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < length; i += 1) {
    final left = i < a.length ? a[i] : 0;
    final right = i < b.length ? b[i] : 0;
    if (right > left) return true;
    if (right < left) return false;
  }
  return false;
}

/// 从 GitHub Release 的应答里取 `tag_name`（形如 `v0.2.2` → `0.2.2`）。
///
/// 认不出就返回 `null`（**不猜**）：调用方把它显示成"查不到最新版本"，
/// 而不是"已是最新"。
String? latestVersionOfTag(Object? body) {
  if (body is! Map) return null;
  final tag = body['tag_name'];
  if (tag is! String || tag.isEmpty) return null;
  final stripped = tag.startsWith('v') ? tag.substring(1) : tag;
  return stripped.isEmpty ? null : stripped;
}

/// 从 GitHub Release 的应答里取出**版本 + 可下载的发布物**。
///
/// 版本认不出 ⇒ `null`（与 [latestVersionOfTag] 同一条判据）。发布物只留
/// `.apk`（README、源码包不算目标），认不出的条目跳过而不是整份失败 ——
/// 一个附件形状不对不该让"有新版本"这件事消失。
AppRelease? latestReleaseOf(Object? body) {
  final version = latestVersionOfTag(body);
  if (version == null) return null;
  final raw = body is Map ? body['assets'] : null;
  final assets = <AppAsset>[];
  if (raw is List) {
    for (final item in raw) {
      if (item is! Map) continue;
      final name = item['name'];
      final url = item['browser_download_url'];
      if (name is! String || name.isEmpty) continue;
      if (url is! String || url.isEmpty) continue;
      if (!name.toLowerCase().endsWith('.apk')) continue;
      assets.add(AppAsset(name: name, url: url));
    }
  }
  return AppRelease(version: version, assets: assets);
}

/// 挑这台设备该下的 APK。
///
/// 1. 名字里带 `-<abi>.apk` 的（发布物命名见 `release.yml`：
///    `dsh-mobile-<tag>-arm64-v8a.apk`）；
/// 2. 没有就退到**任意** `.apk`（老版本发的是通用包，那种包哪个 ABI 都能装）；
/// 3. 一个都没有 ⇒ `null` —— 界面显示"这个版本没有可下载的安装包"，
///    而不是给一个 404 的链接。
///
/// **`abi` 为空时只走第 2 步**（桌面调试 / 拿不到 ABI）：不猜一个 ABI 去试。
AppAsset? apkAssetFor(List<AppAsset> assets, String abi) {
  if (abi.isNotEmpty) {
    final suffix = '-${abi.toLowerCase()}.apk';
    for (final asset in assets) {
      if (asset.name.toLowerCase().endsWith(suffix)) return asset;
    }
  }
  final apks = assets.where(
    (asset) => asset.name.toLowerCase().endsWith('.apk'),
  );
  return apks.isEmpty ? null : apks.first;
}
