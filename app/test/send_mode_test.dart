/// 发送模式（排队 / 插话）的用例：`model/send_mode.dart` + `AppModel` 的持久化。
///
/// ## 为什么持久化要有用例
///
/// 这个偏好**穿过协议**（决定 `session.prompt` 带 `queue` 还是 `steer`）。
/// 只存内存的话，重启就回默认值，而用户看不出自己的选择为什么没了 ——
/// 那种"静默丢偏好"没有任何报错，只能靠用例钉。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/store.dart';
import 'package:dsh_mobile/model/send_mode.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内存偏好（测试用；生产的实现是 `MetaPreferences` 包 `ItemStore` 的 meta 表）。
class _MemoryPrefs implements PreferenceStore {
  final Map<String, String> _map = <String, String>{};

  @override
  Future<String?> read(String key) async => _map[key];

  @override
  Future<void> write(String key, String value) async => _map[key] = value;
}

/// 只回答 start 的假客户端（本组用例只走 `AppModel.start` 的偏好读取）。
class _IdleClient implements SyncClient {
  @override
  Future<void> start() async {}

  @override
  Future<void> setAppState(AppState state) async {}

  @override
  Future<void> close() async {}

  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();

  @override
  ConnectionState get state => ConnectionState.idle;

  @override
  Stream<ConnectionState> get connection => const Stream.empty();

  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();

  @override
  Future<void> subscribe(String sid, {required int since}) async {}

  @override
  Future<void> unsubscribe(String sid) async {}

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => throw UnimplementedError('本组用例只走 start');
}

void main() {
  group('线上值 ↔ 枚举', () {
    test('queue / steer 认得，认不出回 null（不猜）', () {
      expect(SendMode.fromWire('queue'), SendMode.queue);
      expect(SendMode.fromWire('steer'), SendMode.steer);
      // 认不出一律 null：调用方决定默认值，而不是把怪值读成某个模式。
      expect(SendMode.fromWire('Queue'), isNull);
      expect(SendMode.fromWire(''), isNull);
      expect(SendMode.fromWire(null), isNull);
      expect(SendMode.fromWire(42), isNull);
    });

    test('线上值与连接器的 mode 词汇表逐字一致', () {
      // 连接器侧 `handlers.ts` 的 `session.prompt` 只收 'queue' | 'steer'
      // （别的值回 `protocol/bad-frame`）。两边各写一份字符串必然漂移，
      // 所以这里钉住字面值。
      expect(SendMode.queue.wire, 'queue');
      expect(SendMode.steer.wire, 'steer');
    });
  });

  group('偏好落盘与恢复', () {
    test('切模式写进偏好；新实例 start 时读回来', () async {
      final prefs = _MemoryPrefs();
      final app = AppModel(client: _IdleClient(), prefs: prefs);
      expect(app.sendMode, SendMode.queue, reason: '默认排队（与 DSH 默认一致）');

      await app.setSendMode(SendMode.steer);
      expect(app.sendMode, SendMode.steer);
      expect(await prefs.read(AppModel.kSendModeKey), 'steer');

      // **换个实例**（模拟重启）：start 时要把落盘的值读回来。
      final revived = AppModel(client: _IdleClient(), prefs: prefs);
      await revived.start();
      expect(revived.sendMode, SendMode.steer, reason: '重启后还是用户选的那个');
      revived.dispose();
      app.dispose();
    });

    test('同一个值重复切是空操作（不重复写盘、不重复通知）', () async {
      final prefs = _MemoryPrefs();
      final app = AppModel(client: _IdleClient(), prefs: prefs);
      var notified = 0;
      app.addListener(() => notified += 1);

      await app.setSendMode(SendMode.queue); // 已经是 queue
      expect(notified, 0, reason: '没变就不该通知');

      await app.setSendMode(SendMode.steer);
      expect(notified, 1);
      app.dispose();
    });

    test('盘上是个不认识的值：保持默认，不猜', () async {
      final prefs = _MemoryPrefs().._map[AppModel.kSendModeKey] = 'bogus';
      final app = AppModel(client: _IdleClient(), prefs: prefs);
      await app.start();
      expect(app.sendMode, SendMode.queue);
      app.dispose();
    });

    test('没有偏好缝（测试 / 未装配）也能用：只走内存', () async {
      final app = AppModel(client: _IdleClient());
      await app.start();
      await app.setSendMode(SendMode.steer);
      expect(app.sendMode, SendMode.steer);
      app.dispose();
    });
  });

  group('错误码表里有插话的失败（界面据此决定提示什么）', () {
    test('steer 不可用与排队项失效都有专属码', () {
      // 轮次已变时 DSH 回这两个码（`packages/api/session-controller/src/...`），
      // 客户端动作都是 refresh-pending：刷新待处理列表即恢复。
      // 它们存在，界面上的"插话此刻不可用"才有依据可查。
      expect(
        ErrorCode.values.map((c) => c.wire),
        contains('session/steer-unavailable'),
      );
      expect(
        ErrorCode.values.map((c) => c.wire),
        contains('session/queue-item-not-found'),
      );
    });
  });
}
