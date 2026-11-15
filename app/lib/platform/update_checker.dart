/// 「最新版本是多少、该下哪个包」的平台侧实现：问 GitHub Releases。
///
/// ## 为什么是 GitHub 而不是应用商店
///
/// 这个项目只从 GitHub Release 发 APK（`docs/cookbook/release.md`），
/// 没有上任何商店 —— 所以"最新版"只有一个真值源。
///
/// ## 为什么这一层可以碰网络，而 `core/` 不行
///
/// 与 `http_sender.dart` 同一个理由：`core/` 是纯 Dart，
/// `node app/tools/verify-platform-boundary.mjs` 会拦 `dart:io` 与 `package:http`。
/// 所以"缝"（`Future<AppRelease?> Function()`）在 `core/app_update.dart` 的调用方，
/// 实现留在这里，选哪个实现在装配层（`main.dart`）。
///
/// ## 答案里必须带**发布物清单**
///
/// 只回一个版本号是不够的：`release.yml` 用 `--split-per-abi` 出三个包，
/// 装错 ABI 的包装不上。挑包判据是纯函数（`core/app_update.dart` 的
/// `apkAssetFor`），这一层只负责把 GitHub 的原文原样交上去。
///
/// ## 超时与 UA
///
/// 10 s（与 `httpCallTimeout` 同量级）：请求不返回时界面只是"查询中…"，
/// 不该无限转。GitHub 的 API 要求带 `User-Agent`，否则 403。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/app_update.dart';

/// 仓库坐标（与 `README`、CI 一致；改仓库名要改这一处）。
const String kReleaseRepo = 'Imzl-zl/deepseek-harness-mobile';

/// 查一次最新 Release（版本 + 发布物）。
///
/// 失败**抛异常**（由调用方记成 `AppUpdate.error`）：
/// "查不到"和"已是最新"必须能分开。
Future<AppRelease?> fetchLatestAppRelease({http.Client? client}) async {
  final owned = client == null;
  final active = client ?? http.Client();
  try {
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
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception('GitHub 回了 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final release = latestReleaseOf(decoded);
    if (release == null) throw Exception('Release 应答里没有 tag_name');
    return release;
  } finally {
    if (owned) active.close();
  }
}
