/// 「有没有新版本」：版本号比较 + 远端应答的解析（**纯 Dart，零平台**）。
///
/// ## 为什么值得有
///
/// 手机 App 只能从 GitHub Release 拿到 APK（`app/tools` 之外没有分发渠道），
/// 而用户不会天天去刷 Release 页。一个"当前版本 / 最新版本 / 有新版"的只读查询，
/// 让"我是不是该更新"变成一眼能答的问题。
///
/// ## 判据只有两条，都写死在这里
///
/// 1. **比较按数字段**：`0.2.10 > 0.2.9`（字符串比会得出反的结论）。
/// 2. **预发布不算新**：`0.2.3-rc.1` 不比 `0.2.3` 新。
///
/// 远端用哪个源、怎么发请求，是平台层的事（`platform/update_checker.dart`）——
/// 这一层不认识 HTTP，也不认识 GitHub。
library;

/// 本机 App 版本。**构建期注入**（CI 用 `--dart-define=APP_VERSION=<tag>`），
/// 没注入时是 `dev` —— 不猜一个版本号。
const String kAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'dev',
);

/// 一次版本比对的结论（**UI 只读它**）。
class AppUpdate {
  const AppUpdate({required this.current, this.latest, this.error});

  /// 本机版本（[kAppVersion]，或测试注入的值）。
  final String current;

  /// 远端最新版本（去掉 `v` 前缀）；`null` = 没查到。
  final String? latest;

  /// 查询失败的原话（**不吞**：查不到 ≠ 已是最新）。
  final String? error;

  /// 本机版本能不能参与比对。`dev`（本地构建，没注入 `APP_VERSION`）不能 ——
  /// 拿它去比只会得出"永远有新版本"，那是骚扰开发构建，不是在报事实。
  bool get comparable => current.isNotEmpty && current != 'dev';

  /// 有新版（`latest` 缺失、或本机是 `dev` 时恒 false）。
  bool get hasUpdate =>
      comparable && latest != null && isNewerVersion(current, latest!);

  /// 一句话状态（界面直接显示）。
  String get label {
    if (error != null) return '查不到最新版本';
    if (!comparable) return '开发版（不比对版本）';
    if (latest == null) return '还没查过';
    return hasUpdate ? '有新版本 v$latest' : '已是最新';
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
