/// 「最新版本是多少」的平台侧实现：查询 GitHub Releases（支持注入自定义镜像）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/app_update.dart';

/// 可选的版本检查接口（默认空；可通过 `--dart-define=APP_UPDATE_URL=...` 在构建期注入自定义镜像）。
const String kAppVersionEndpoint = String.fromEnvironment('APP_UPDATE_URL', defaultValue: '');

/// 仓库坐标（与 `README`、CI 一致；改仓库名要改这一处）。
const String kReleaseRepo = 'Imzl-zl/deepseek-harness-mobile';

/// 查一次最新版本。优先向构建期注入的镜像请求（如有），否则向 GitHub Releases 请求。
///
/// 失败**抛异常**（由调用方记成 `AppUpdate.error`）：
/// "查不到"和"已是最新"必须能分开。
Future<AppUpdateInfo?> fetchLatestAppUpdate({http.Client? client}) async {
  final owned = client == null;
  final active = client ?? http.Client();
  try {
    // 1. 若配置了自定义更新镜像，优先请求
    if (kAppVersionEndpoint.isNotEmpty) {
      try {
        final response = await active
            .get(
              Uri.parse(kAppVersionEndpoint),
              headers: const {
                'accept': 'application/json',
                'user-agent': 'dsh-mobile-app',
              },
            )
            .timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final decoded = jsonDecode(utf8.decode(response.bodyBytes));
          if (decoded is Map && decoded['version'] is String) {
            final version = (decoded['version'] as String).replaceFirst('v', '');
            final url = decoded['url'] as String?;
            final changelog = decoded['changelog'] as String?;
            return AppUpdateInfo(version: version, url: url, changelog: changelog);
          }
        }
      } catch (_) {
        // 自定义镜像不可达时，静默回退 GitHub
      }
    }

    // 2. 查官方 GitHub Releases
    final response = await active
        .get(
          Uri.parse(
            'https://api.github.com/repos/$kReleaseRepo/releases/latest',
          ),
          headers: const {
            'accept': 'application/vnd.github+json',
            'user-agent': 'dsh-mobile-app',
          },
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw Exception('检查更新失败：HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final version = latestVersionOfTag(decoded);
    if (version == null) throw Exception('Release 应答里没有 tag_name');

    // 尝试在 assets 中提取 arm64 apk 或首个 apk 的 download_url
    String? apkUrl;
    if (decoded is Map && decoded['assets'] is List) {
      for (final asset in decoded['assets']) {
        if (asset is Map && asset['browser_download_url'] is String) {
          final downloadUrl = asset['browser_download_url'] as String;
          if (downloadUrl.endsWith('.apk')) {
            if (downloadUrl.contains('arm64')) {
              apkUrl = downloadUrl;
              break;
            }
            apkUrl ??= downloadUrl;
          }
        }
      }
    }

    final changelog = decoded is Map ? decoded['body'] as String? : null;
    return AppUpdateInfo(version: version, url: apkUrl, changelog: changelog);
  } finally {
    if (owned) active.close();
  }
}

/// 兼容旧签名的包装（返回版本号字符串）。
Future<String?> fetchLatestAppVersion({http.Client? client}) async {
  final info = await fetchLatestAppUpdate(client: client);
  return info?.version;
}
