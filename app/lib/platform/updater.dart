/// 应用内升级与安装通道（Android 原生 MethodChannel + 流式下载 + 弹窗）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../theme/dsh_colors.dart';

/// 应用内更新管理器。
class AppUpdater {
  const AppUpdater();

  static const MethodChannel _channel = MethodChannel('dsh/updater');

  /// 检查当前是否允许安装未知来源应用（Android 8.0+）。
  Future<bool> canInstall() async {
    if (!Platform.isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>('canInstall');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开未知来源应用安装权限设置页。
  Future<void> openInstallSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('openInstallSettings');
    } catch (_) {}
  }

  /// 调起原生系统安装器安装指定路径的 APK。
  Future<bool> installApk(String filePath) async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('installApk', {
        'path': filePath,
      });
      return res ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 获取下载 APK 存储目录（优先向原生查 cacheDir/dsh_updates，回退 sqflite 推导路径）。
  Future<Directory> _getUpdateDir() async {
    if (Platform.isAndroid) {
      try {
        final path = await _channel.invokeMethod<String>('getUpdateDir');
        if (path != null && path.isNotEmpty) {
          final dir = Directory(path);
          if (!await dir.exists()) await dir.create(recursive: true);
          return dir;
        }
      } catch (_) {}
    }
    final dbPath = await getDatabasesPath();
    final dir = Directory(p.join(p.dirname(dbPath), 'cache', 'dsh_updates'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 流式下载 APK 并返回本地文件路径，支持进度回调 (progress: 0.0 ~ 1.0, receivedBytes, totalBytes)。
  Future<String> downloadApk({
    required String url,
    required String version,
    void Function(double progress, int receivedBytes, int totalBytes)? onProgress,
    http.Client? client,
  }) async {
    final updateDir = await _getUpdateDir();
    final targetFile = File(p.join(updateDir.path, 'dsh-mobile-v$version.apk'));
    if (await targetFile.exists()) {
      try {
        await targetFile.delete();
      } catch (_) {}
    }

    final owned = client == null;
    final active = client ?? http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers['user-agent'] = 'dsh-mobile-app';
      final response = await active.send(request);
      if (response.statusCode != 200) {
        throw Exception('下载失败：HTTP ${response.statusCode}');
      }
      final total = response.contentLength ?? 0;
      var received = 0;
      final sink = targetFile.openWrite();
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && onProgress != null) {
          onProgress(received / total, received, total);
        }
      }
      await sink.flush();
      await sink.close();
      return targetFile.path;
    } finally {
      if (owned) active.close();
    }
  }
}

/// 弹出应用升级对话框。
Future<void> showUpdateDialog(
  BuildContext context, {
  required String version,
  String? url,
  String? changelog,
  AppUpdater updater = const AppUpdater(),
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _UpdateDialog(
      version: version,
      url: url,
      changelog: changelog,
      updater: updater,
    ),
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({
    required this.version,
    this.url,
    this.changelog,
    required this.updater,
  });

  final String version;
  final String? url;
  final String? changelog;
  final AppUpdater updater;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _downloading = false;
  double _progress = 0.0;
  int _received = 0;
  int _total = 0;
  String? _error;
  String? _downloadedApkPath;

  Future<void> _startDownload() async {
    final url = widget.url;
    if (url == null || url.isEmpty) return;

    final can = await widget.updater.canInstall();
    if (!can) {
      await widget.updater.openInstallSettings();
    }

    setState(() {
      _downloading = true;
      _error = null;
      _progress = 0.0;
    });

    try {
      final path = await widget.updater.downloadApk(
        url: url,
        version: widget.version,
        onProgress: (p, r, t) {
          if (!mounted) return;
          setState(() {
            _progress = p;
            _received = r;
            _total = t;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloadedApkPath = path;
      });
      await widget.updater.installApk(path);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final hasUrl = widget.url != null && widget.url!.isNotEmpty;

    return AlertDialog(
      backgroundColor: c.layer1,
      title: Text(
        '发现新版本 v${widget.version}',
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: c.labelPrimary),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.changelog != null && widget.changelog!.isNotEmpty) ...[
              Text(
                '更新说明：',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.labelSecondary),
              ),
              const SizedBox(height: 4),
              Text(
                widget.changelog!,
                style: TextStyle(fontSize: 13, height: 1.4, color: c.labelPrimary),
              ),
              const SizedBox(height: 12),
            ],
            if (!hasUrl)
              Text(
                '该版本未提供直接下载包，请前往发布页面下载。',
                style: TextStyle(fontSize: 13, color: c.labelSecondary),
              ),
            if (_downloading) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                backgroundColor: c.layer2,
                color: c.roleContext,
              ),
              const SizedBox(height: 8),
              Text(
                _total > 0
                    ? '${(_progress * 100).toInt()}% (${(_received / 1024 / 1024).toStringAsFixed(1)} MB / ${(_total / 1024 / 1024).toStringAsFixed(1)} MB)'
                    : '正在下载…',
                style: TextStyle(fontSize: 12, color: c.labelCaption),
              ),
            ],
            if (_downloadedApkPath != null && !_downloading) ...[
              const SizedBox(height: 6),
              Text(
                '下载完成，若未自动弹出安装请点击下方「安装」。',
                style: TextStyle(fontSize: 12, color: c.roleContext),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 6),
              Text(
                '下载出错：$_error',
                style: TextStyle(fontSize: 12, color: c.stateError),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (!_downloading)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('稍后再说', style: TextStyle(color: c.labelSecondary)),
          ),
        if (hasUrl && !_downloading && _downloadedApkPath == null)
          FilledButton(
            onPressed: _startDownload,
            style: FilledButton.styleFrom(backgroundColor: c.roleContext),
            child: const Text('立即更新'),
          ),
        if (_downloadedApkPath != null && !_downloading)
          FilledButton(
            onPressed: () => widget.updater.installApk(_downloadedApkPath!),
            style: FilledButton.styleFrom(backgroundColor: c.roleContext),
            child: const Text('安装'),
          ),
      ],
    );
  }
}
