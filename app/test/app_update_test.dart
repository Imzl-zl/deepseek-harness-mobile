/// 「检查更新」：版本比较、远端解析、以及 `AppModel` 的三种结论。
///
/// 守四件事：
/// 1. 比较按**数字段**（`0.2.10 > 0.2.9`），预发布不算新；
/// 2. GitHub 的 `tag_name` 去掉 `v`；认不出返回 `null`（不猜）；
/// 3. 查到新版 → `hasUpdate`；没新版 → 已是最新；
/// 4. **查不到 ≠ 已是最新**：`error` 留在结论上，`label` 说"查不到最新版本"。
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
        latestAppTag: () async => '99.0.0',
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
        latestAppTag: () async => throw Exception('HTTP 503'),
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
  });
}
