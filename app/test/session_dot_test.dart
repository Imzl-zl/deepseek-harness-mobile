/// 抽屉行首那枚状态点：**四态 + 优先级**，以及它依赖的那份"未读收口"。
///
/// ## 这一组守什么
///
/// 1. 优先级照 DSH（`packages/client/ui-workspace/src/client/rows/Rows.tsx:344-398`）：
///    待处理 > 运行中 > 已完成 > 空闲。
/// 2. `completionUnread` 是**派生**，只在一个边沿上置位：看着它从"在跑"变成"不跑了"，
///    而且**那个会话不是当前正在看的那个**（DSH 的字段注释：
///    *"an observed stop outside the main view still needs acknowledgement"*，
///    `ui-session/src/client/index.ts:65-66`；规则 `:490-498,511`）。
/// 3. 基线（首包 `session.list`）**不造**绿点：`previous === undefined` 那一条（`:495`）。
/// 4. 打开那个会话就清掉（`:511` 的"在主视图里就清"）。
/// 5. **不落盘**：这条只是提示，不是持久事实（与浏览器刷新即丢同义）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/session_dot.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 能换 `session.list` 应答、能推 `status` 帧的最小替身。
class _Client extends FakeSyncClient {
  List<Map<String, Object?>> rows = const [];

  final _status = StreamController<SessionStatus>.broadcast();

  void emitStatus(String sid, bool running) =>
      _status.add(SessionStatus(sid: sid, running: running));

  @override
  conn.ConnectionState get state => conn.ConnectionState.serving;
  @override
  Stream<conn.ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();
  @override
  Stream<SessionStatus> get sessionStatus => _status.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> reconnect() => start();
  @override
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> unsubscribe(String sid) async {}
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'session.list') return {'sessions': rows} as T;
    return <String, Object?>{} as T;
  }
}

Map<String, Object?> _row(String sid, {required bool running}) => {
  'sid': sid,
  'updatedAt': 0,
  'running': running,
};

/// 让 `_status` 的事件真的投递到 `AppModel`（纯 `test` 里可以等零延迟）。
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('优先级（纯函数）', () {
    test('待处理压过运行中、运行中压过已完成、其余是空闲', () {
      expect(
        sessionDotOf(pendingCount: 1, running: true, completionUnread: true),
        SessionDot.warning,
      );
      expect(
        sessionDotOf(pendingCount: 0, running: true, completionUnread: true),
        SessionDot.ongoing,
      );
      expect(
        sessionDotOf(pendingCount: 0, running: false, completionUnread: true),
        SessionDot.done,
      );
      expect(
        sessionDotOf(pendingCount: 0, running: false, completionUnread: false),
        SessionDot.idle,
      );
    });
  });

  group('completionUnread（派生，不落盘）', () {
    test('别的会话跑完 ⇒ 置位；打开它就清掉', () async {
      final client = _Client()..rows = [_row('a', running: false)];
      final app = AppModel(client: client);
      addTearDown(() {
        app.dispose();
        unawaited(client._status.close());
      });
      await app.start();
      await app.openSession('b');
      expect(app.completionUnreadOf('a'), isFalse);

      client.emitStatus('a', true); // 开始跑
      await settle();
      expect(app.runningOf('a'), isTrue);
      expect(app.completionUnreadOf('a'), isFalse);

      client.emitStatus('a', false); // 跑完（此时我在看 b）
      await settle();
      expect(app.runningOf('a'), isFalse);
      expect(app.completionUnreadOf('a'), isTrue, reason: '收口发生在我看的会话之外');

      await app.openSession('a'); // 点进去 = 看见了
      expect(app.completionUnreadOf('a'), isFalse);
    });

    test('正在看的那个跑完 ⇒ 不算未读（结果就在眼前）', () async {
      final client = _Client()..rows = [_row('a', running: false)];
      final app = AppModel(client: client);
      addTearDown(() {
        app.dispose();
        unawaited(client._status.close());
      });
      await app.start();
      await app.openSession('a');

      client.emitStatus('a', true);
      await settle();
      client.emitStatus('a', false);
      await settle();
      expect(app.completionUnreadOf('a'), isFalse);
    });

    test('基线（首包就是 false）不造绿点', () async {
      final client = _Client()..rows = [_row('a', running: false)];
      final app = AppModel(client: client);
      addTearDown(() {
        app.dispose();
        unawaited(client._status.close());
      });
      await app.start();
      await app.openSession('b');
      await app.refreshSessions();
      expect(app.runningOf('a'), isFalse);
      expect(app.completionUnreadOf('a'), isFalse, reason: '没看着它跑过，就不该说"刚跑完"');
    });

    test('先 true 后 false 的快照也会置位（断线期间跑完、重连才纠正）', () async {
      final client = _Client()..rows = [_row('a', running: true)];
      final app = AppModel(client: client);
      addTearDown(() {
        app.dispose();
        unawaited(client._status.close());
      });
      await app.start();
      await app.openSession('b');
      await app.refreshSessions();
      expect(app.runningOf('a'), isTrue);

      client.rows = [_row('a', running: false)];
      await app.refreshSessions();
      expect(app.runningOf('a'), isFalse);
      expect(
        app.completionUnreadOf('a'),
        isTrue,
        reason: '这一轮真的跑了（快照说过 true），回网才知道它完了',
      );
    });
  });
}
