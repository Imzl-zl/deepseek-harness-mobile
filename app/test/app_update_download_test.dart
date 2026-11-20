/// 下载通道（`dsh/app-update`）的**返回值类型**边界。
///
/// 守一件事：原生回的下载任务 id 是 `Long`，过 `StandardMessageCodec` 到 Dart
/// 侧是 `int`；这一层**不读它**（「入队即返回」，见 `platform/app_update_downloader.dart`
/// 的文件头），所以它对类型必须完全免疫。
///
/// 为什么这条要单独钉：v0.2.18~v0.2.20 里这里写的是 `invokeMethod<String>`，
/// 而 `platform_channel.dart:366` 是 `codec.decodeEnvelope(result) as T?` ——
/// 一句 `as String?` 撞上 `int`，用户点「下载」看到的就是
/// `type 'int' is not a subtype of type 'String?' in type cast`。
/// 界面上那句「下载失败：…」把这段 Dart 内部错误原样念给了用户。
library;

import 'package:dsh_mobile/platform/app_update_downloader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('dsh/app-update');

/// 起一个假的平台通道，回 [reply]。
void _mockReply(Object? Function(MethodCall call) reply, List<MethodCall> calls) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    calls.add(call);
    return reply(call);
  });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('startAppUpdateDownload：只管把下载交出去', () {
    test('原生回下载任务 id（Kotlin Long → Dart int）时不炸', () async {
      // 真实值来自 `DshAppUpdate.kt:48` 的 `result.success(enqueue(...))`，
      // 而 `enqueue` 返回 `DownloadManager.enqueue()` 的 `Long`（> 0 = 已受理）。
      final calls = <MethodCall>[];
      _mockReply((_) => 42, calls);

      await expectLater(
        startAppUpdateDownload(
          url: Uri.parse('https://example.invalid/dsh-mobile-arm64-v8a.apk'),
          fileName: 'dsh-mobile-arm64-v8a.apk',
        ),
        completes,
        reason: '返回值是任务 id，不是错误 —— 类型对不上也不该让下载失败',
      );
      expect(calls.single.method, 'download');
    });

    test('原生回 null（有的平台不给 id）时也不炸', () async {
      _mockReply((_) => null, <MethodCall>[]);

      await expectLater(
        startAppUpdateDownload(
          url: Uri.parse('https://example.invalid/x.apk'),
          fileName: 'x.apk',
        ),
        completes,
      );
    });

    test('url 与文件名原样过通道（同一处改名会撞 `Downloads/` 里认不出是哪一版）', () async {
      final calls = <MethodCall>[];
      _mockReply((_) => 1, calls);

      await startAppUpdateDownload(
        url: Uri.parse('https://example.invalid/dsh-mobile-v0.2.20-arm64-v8a.apk'),
        fileName: 'dsh-mobile-v0.2.20-arm64-v8a.apk',
      );

      final args = calls.single.arguments as Map;
      expect(
        args['url'],
        'https://example.invalid/dsh-mobile-v0.2.20-arm64-v8a.apk',
      );
      expect(args['fileName'], 'dsh-mobile-v0.2.20-arm64-v8a.apk');
    });
  });

  group('原生拒了照实说（不是被上面那条吞掉）', () {
    test('`result.error` 仍然抛成 PlatformException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        _channel,
        (call) async => throw PlatformException(
          code: 'download-failed',
          message: 'no space left',
        ),
      );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, null),
      );

      await expectLater(
        startAppUpdateDownload(
          url: Uri.parse('https://example.invalid/x.apk'),
          fileName: 'x.apk',
        ),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'download-failed'),
        ),
        reason: '「不读返回值」不等于「吞掉失败」',
      );
    });
  });

  group('ABI → 发布物后缀（`release.yml` 的 `--split-per-abi` 命名）', () {
    test('本机 ABI 认得出就是那三个后缀之一，认不出是空串（不猜）', () {
      expect(
        deviceAbiName(),
        anyOf('', 'arm64-v8a', 'armeabi-v7a', 'x86_64'),
        reason: '空串 = 交给 `apkAssetFor` 退到"任意 .apk"，不是猜一个',
      );
    });
  });
}
