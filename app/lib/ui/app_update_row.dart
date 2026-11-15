/// 「App 版本」那一行：**点它就是检查更新，查到就问一句，确认后直接下载**。
///
/// ## 为什么单独一个文件
///
/// 它是设置页里唯一会打外网、并且会调起系统组件（`DownloadManager`）的一行 ——
/// 三段动作（查 / 确认 / 下载）加两条回执文案，塞回 `settings_page.dart` 会让那个
/// 文件继续长（它是尺寸棘轮里的一张脸，1353 行的上限不是摆设）。
///
/// ## 一件事一个入口（2026-11-15 用户反馈）
///
/// 原话：「为啥一个版本号一个检测更新，检测更新还只是检测更新，不是直接下载」。
/// 这一行只承诺一件事：**让我变成最新版**。
///
/// | 当前状态 | 点一下 |
/// |---|---|
/// | 还不知道 | 查 `releases/latest` |
/// | 查到有新版 | 弹「下载并安装」，确认后交给系统下载器 |
/// | 已经知道有新版 | **直接下载**（不再白查一次网络） |
/// | 已是最新 / 查不到 | 查一次，并如实说结果（查不到 ≠ 已是最新） |
///
/// 复制版本号挪到**长按**（贴 issue 时要那一串，但不值得为它再占一行）。
///
/// 决策与代价见 `.agents/notes/implemented/2026-11-15-version-row-checks-and-downloads.md`。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_update.dart';
import '../data/app_model.dart';
import 'dsh_sheet.dart';
import 'dsh_toast.dart';
import 'settings_row.dart';

/// 设置页「关于与连接」里的版本行。
class AppVersionRow extends StatelessWidget {
  const AppVersionRow({super.key, required this.app});

  final AppModel app;

  @override
  Widget build(BuildContext context) {
    final update = app.appUpdate;
    return SettingsRow(
      // 有新版时图标就是下载：这一行的承诺变了，图标先说。
      icon: update?.hasUpdate == true ? 'download' : 'refresh',
      label: 'App 版本',
      value: app.updateChecking ? '查询中…' : (update?.rowValue ?? kAppVersion),
      onTap: () => unawaited(_checkOrDownload(context)),
      onLongPress: () => unawaited(_copyVersion(context)),
    );
  }

  Future<void> _copyVersion(BuildContext context) async {
    await Clipboard.setData(const ClipboardData(text: kAppVersion));
    if (!context.mounted) return;
    DshToast.show(context, '版本号已复制');
  }

  Future<void> _checkOrDownload(BuildContext context) async {
    final known = app.appUpdate;
    // 已经知道有新版：再点一下就是**下载**（不再白查一次网络）。
    if (known != null && known.hasUpdate) {
      await _download(context, known);
      return;
    }
    await app.checkAppUpdate();
    if (!context.mounted) return;
    final result = app.appUpdate;
    if (result == null) return;
    if (result.hasUpdate) {
      final download = await _confirmDownload(context, result);
      if (!download || !context.mounted) return;
      await _download(context, result);
      return;
    }
    DshToast.show(
      context,
      // **失败带原因**：国内网络下 GitHub API 常常不可达，只说"查不到"
      // 会让人以为是 App 的锅；把 HTTP 状态 / 超时原话带出来。
      result.error == null ? result.label : '查不到最新版本：${result.error}',
      kind: result.error == null ? DshToastKind.info : DshToastKind.error,
    );
  }

  /// 查到新版后问一句「下载吗」。**不自动下载**：几十 MB 的流量该由用户点。
  Future<bool> _confirmDownload(BuildContext context, AppUpdate update) async {
    final action = await showDshSheet<String>(
      context: context,
      title: '有新版本 v${update.latest}',
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DshPickerRow(
            name: '下载并安装',
            // 如实说清"点了会发生什么"：交给系统下载器，装的时候是系统安装器。
            tags: const ['系统下载，完成后通知栏点开安装'],
            selected: false,
            icon: 'download',
            onTap: () => Navigator.of(context).pop('download'),
          ),
          DshPickerRow(
            name: '稍后',
            tags: const [],
            selected: false,
            icon: 'close',
            onTap: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
    return action == 'download';
  }

  /// 交给系统下载器（Android）；其余平台如实说"这台设备不能直接下载"，
  /// **退成复制链接**（能做的那一件事），而不是假装成功了。
  Future<void> _download(BuildContext context, AppUpdate update) async {
    final url = update.downloadUrl;
    if (url == null) {
      DshToast.show(context, '这个版本没有可下载的安装包', kind: DshToastKind.error);
      return;
    }
    if (!app.canDownloadUpdate) {
      await Clipboard.setData(ClipboardData(text: url));
      if (!context.mounted) return;
      DshToast.show(context, '已复制下载链接（这台设备不能直接下载）');
      return;
    }
    final failure = await app.downloadAppUpdate();
    if (!context.mounted) return;
    DshToast.show(
      context,
      failure == null
          ? '已开始下载 v${update.latest}（通知栏看进度，完成后点开安装）'
          : '下载失败：$failure',
      kind: failure == null ? DshToastKind.info : DshToastKind.error,
    );
  }
}
