/// 「检查更新 / 直接下载」：版本比较、远端解析、挑哪个 APK，以及 `AppModel` 的结论。
///
/// 守五件事：
/// 1. 比较按**数字段**（`0.2.10 > 0.2.9`），预发布不算新；
/// 2. GitHub 的 `tag_name` 去掉 `v`；认不出返回 `null`（不猜）；
/// 3. **发布物按 ABI 挑**（`--split-per-abi` 发了三个包，装错 ABI 装不上）：
///    精确命中 `-<abi>.apk` → 用；否则退任意 `.apk`；一个都没有 → `null`；
/// 4. **查不到 ≠ 已是最新**：`error` 留在结论上，`label` 说"查不到最新版本"；
/// 5. **下载是"把地址交给系统下载器"**：没有 url / 没有下载器 / 缝抛错各有自己的说法。
library;

import 'package:dsh_mobile/core/app_update.dart';
import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 只够 `AppModel` 构造与 dispose 的最小替身（版本查询与连接无关）。
class _Client extends FakeSyncClient {
  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> reconnect() async {}
  @override
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> unsubscribe(String sid) async {}
}

void main() {
  group('版本比较', () {
    test('按数字段，不是字符串', () {
      expect(isNewerVersion('0.2.9', '0.2.10'), isTrue);
      expect(isNewerVersion('0.2.10', '0.2.9'), isFalse);
      expect(isNewerVersion('0.2.10', '0.2.10'), isFalse);
      expect(isNewerVersion('0.3', '0.2.99'), isFalse);
      expect(isNewerVersion('0.2', '0.2.1'), isTrue, reason: '短版本按缺 0 处理');
    });

    test('预发布不比同号正式版新', () {
      expect(isNewerVersion('0.2.3', '0.2.3-rc.1'), isFalse);
      expect(isNewerVersion('0.2.2', '0.2.3-rc.1'), isTrue);
    });

    test('`dev` 永远判成"有新版"（不自称最新）', () {
      expect(isNewerVersion('dev', '0.2.2'), isTrue);
    });
  });

  group('Release 应答解析', () {
    test('取 tag_name 并去掉 v', () {
      expect(latestVersionOfTag({'tag_name': 'v0.2.3'}), '0.2.3');
      expect(latestVersionOfTag({'tag_name': '0.2.3'}), '0.2.3');
    });

    test('认不出就是 null（不猜）', () {
      expect(latestVersionOfTag(null), isNull);
      expect(latestVersionOfTag({'tag_name': ''}), isNull);
      expect(latestVersionOfTag({'name': 'x'}), isNull);
      expect(latestVersionOfTag('not a map'), isNull);
    });
  });

  group('结论文案（current 显式给，不依赖构建期注入）', () {
    test('有新版', () {
      const update = AppUpdate(current: '0.2.2', latest: '0.2.3');
      expect(update.hasUpdate, isTrue);
      expect(update.label, '有新版本 v0.2.3');
    });

    test('已是最新', () {
      const update = AppUpdate(current: '0.2.3', latest: '0.2.3');
      expect(update.hasUpdate, isFalse);
      expect(update.label, '已是最新');
    });

    test('dev 构建不参与比对（否则永远在报有新版）', () {
      const update = AppUpdate(current: 'dev', latest: '0.2.3');
      expect(update.comparable, isFalse);
      expect(update.hasUpdate, isFalse);
      expect(update.label, '开发版（不比对版本）');
    });
  });

  group('AppModel.checkAppUpdate', () {
    test('把远端结论落到 appUpdate 上（测试里 current 是 dev，所以不报有新版）', () async {
      final app = AppModel(
        client: _Client(),
        latestAppRelease: () async => const AppRelease(version: '99.0.0'),
      );
      addTearDown(app.dispose);

      await app.checkAppUpdate();
      final update = app.appUpdate;
      expect(update, isNotNull);
      expect(update!.latest, '99.0.0', reason: '远端版本要如实记下来');
      expect(update.hasUpdate, isFalse, reason: 'dev 构建不参与比对');
    });

    test('查失败：**不画成已是最新**，原话留在结论上', () async {
      final app = AppModel(
        client: _Client(),
        latestAppRelease: () async => throw Exception('HTTP 503'),
      );
      addTearDown(app.dispose);

      await app.checkAppUpdate();
      final update = app.appUpdate;
      expect(update, isNotNull);
      expect(update!.error, contains('503'));
      expect(update.hasUpdate, isFalse);
      expect(update.label, '查不到最新版本');
    });

    test('没注入查更新缝：点也不发请求、结论保持空', () async {
      final app = AppModel(client: _Client());
      addTearDown(app.dispose);
      await app.checkAppUpdate();
      expect(app.appUpdate, isNull);
    });

    test('结论里带上"这台设备该下哪个包"（dev 构建也算，下载与"是否新版"无关）', () async {
      final app = AppModel(
        client: _Client(),
        deviceAbi: () => 'arm64-v8a',
        latestAppRelease: () async => const AppRelease(
          version: '99.0.0',
          assets: [
            AppAsset(
              name: 'dsh-mobile-v99.0.0-armeabi-v7a.apk',
              url: 'https://example.invalid/v7a.apk',
            ),
            AppAsset(
              name: 'dsh-mobile-v99.0.0-arm64-v8a.apk',
              url: 'https://example.invalid/arm64.apk',
            ),
          ],
        ),
      );
      addTearDown(app.dispose);
      await app.checkAppUpdate();
      expect(app.appUpdate!.downloadUrl, 'https://example.invalid/arm64.apk');
    });
  });

  group('发布物：只留 APK，按 ABI 挑（`release.yml` 的 `--split-per-abi`）', () {
    const assets = [
      AppAsset(name: 'dsh-mobile-v0.2.17-armeabi-v7a.apk', url: 'u-v7a'),
      AppAsset(name: 'dsh-mobile-v0.2.17-arm64-v8a.apk', url: 'u-arm64'),
      AppAsset(name: 'dsh-mobile-v0.2.17-x86_64.apk', url: 'u-x64'),
    ];

    test('精确命中设备 ABI', () {
      expect(apkAssetFor(assets, 'arm64-v8a')!.url, 'u-arm64');
      expect(apkAssetFor(assets, 'armeabi-v7a')!.url, 'u-v7a');
      expect(apkAssetFor(assets, 'x86_64')!.url, 'u-x64');
    });

    test('没有对应 ABI 就退到任意 APK（老版本发的是通用包）', () {
      const universal = [
        AppAsset(name: 'dsh-mobile-v0.2.15.apk', url: 'u-all'),
      ];
      expect(apkAssetFor(universal, 'arm64-v8a')!.url, 'u-all');
    });

    test('ABI 为空（桌面调试 / 认不出）只走兜底，**不猜一个 ABI**', () {
      // 空 ABI 若去"猜"，会命中第一个 aarch64 之前的包 —— 那就可能装错。
      expect(apkAssetFor(assets, '')!.url, 'u-v7a');
    });

    test('一个 APK 都没有 ⇒ null（不给一个 404 链接）', () {
      expect(apkAssetFor(const [], 'arm64-v8a'), isNull);
      expect(
        apkAssetFor(const [
          AppAsset(name: 'source.tar.gz', url: 'u'),
        ], 'arm64-v8a'),
        isNull,
      );
    });

    test('`latestReleaseOf` 解析版本 + 只收 .apk，坏条目跳过而不是整份失败', () {
      final release = latestReleaseOf({
        'tag_name': 'v0.2.17',
        'assets': [
          {
            'name': 'dsh-mobile-v0.2.17-arm64-v8a.apk',
            'browser_download_url': 'a',
          },
          {'name': 'source.tar.gz', 'browser_download_url': 'b'},
          {'name': 'broken.apk'},
          {'browser_download_url': 'c'},
          'not a map',
        ],
      });
      expect(release, isNotNull);
      expect(release!.version, '0.2.17');
      expect(release.assets.length, 1, reason: '只有那一条真 APK');
      expect(release.assets.first.url, 'a');
      // 版本认不出 ⇒ 整份 null（与 `latestVersionOfTag` 同一条）。
      expect(latestReleaseOf({'assets': []}), isNull);
    });
  });

  group('版本那一行的字（`rowValue`）', () {
    test('四种状态各自一句话（值列只有 42% 宽，所以用箭头不用长句）', () {
      const updating = AppUpdate(
        current: '0.2.17',
        latest: '0.2.18',
        downloadUrl: 'u',
      );
      expect(updating.rowValue, '0.2.17 → 0.2.18');

      const latest = AppUpdate(current: '0.2.18', latest: '0.2.18');
      expect(latest.rowValue, '0.2.18 · 已是最新');

      const failed = AppUpdate(current: '0.2.17', error: 'HTTP 503');
      expect(failed.rowValue, '0.2.17 · 查不到');

      const unknown = AppUpdate(current: 'dev');
      expect(unknown.rowValue, 'dev', reason: '没查过就是版本号本身');
    });
  });

  group('AppModel.downloadAppUpdate', () {
    test('没有 url ⇒ 如实说（不假装下载）', () async {
      final app = AppModel(client: _Client());
      addTearDown(app.dispose);
      expect(await app.downloadAppUpdate(), contains('先检查更新'));
    });

    test('这台设备没有下载器 ⇒ 一句人话（界面据此退成复制链接）', () async {
      final app = AppModel(
        client: _Client(),
        deviceAbi: () => 'arm64-v8a',
        latestAppRelease: () async => const AppRelease(
          version: '99.0.0',
          assets: [
            AppAsset(name: 'dsh-mobile-v99.0.0-arm64-v8a.apk', url: 'u-arm64'),
          ],
        ),
      );
      addTearDown(app.dispose);
      await app.checkAppUpdate();
      expect(app.canDownloadUpdate, isFalse);
      expect(await app.downloadAppUpdate(), contains('不能直接下载'));
    });

    test('有下载器 ⇒ 把 **url 与文件名** 原样交出去（文件名取 URL 末段）', () async {
      Uri? got;
      String? name;
      final app = AppModel(
        client: _Client(),
        deviceAbi: () => 'arm64-v8a',
        latestAppRelease: () async => const AppRelease(
          version: '99.0.0',
          assets: [
            AppAsset(
              name: 'dsh-mobile-v99.0.0-arm64-v8a.apk',
              url: 'https://example.invalid/dsh-mobile-v99.0.0-arm64-v8a.apk',
            ),
          ],
        ),
        downloadAppUpdate: ({required url, required fileName}) async {
          got = url;
          name = fileName;
        },
      );
      addTearDown(app.dispose);
      await app.checkAppUpdate();
      expect(app.canDownloadUpdate, isTrue);
      expect(await app.downloadAppUpdate(), isNull, reason: 'null = 已交给系统');
      expect(got.toString(), contains('arm64-v8a.apk'));
      expect(name, 'dsh-mobile-v99.0.0-arm64-v8a.apk');
    });

    test('系统拒了 ⇒ 把它的原话带出来（不吞）', () async {
      final app = AppModel(
        client: _Client(),
        deviceAbi: () => 'arm64-v8a',
        latestAppRelease: () async => const AppRelease(
          version: '99.0.0',
          assets: [
            AppAsset(name: 'dsh-mobile-v99.0.0-arm64-v8a.apk', url: 'u-arm64'),
          ],
        ),
        downloadAppUpdate: ({required url, required fileName}) async {
          throw Exception('download-failed: no space left');
        },
      );
      addTearDown(app.dispose);
      await app.checkAppUpdate();
      expect(await app.downloadAppUpdate(), contains('no space left'));
    });
  });
}
