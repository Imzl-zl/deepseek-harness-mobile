/// 连接终态恢复的单测（议题 2：`ClientAction` 的唯一执行处 + AppModel 的呈递）。
///
/// ## 这一组钉两件事
///
/// 1. **`ConnectionRecovery` 是 `ClientAction` 的唯一执行处**：`rePair` → 清凭据 +
///    回配对页（给的是人话，不是裸 401）；映射不到的动作 → 照实上报，**不清凭据、
///    不回配对页**（无静默兜底）。
/// 2. **`AppModel` 只在连接层确认"终态"时呈递一次**：网络类失败（连接层自行退避）
///    不呈递；终态（身份不被认）呈递一次，不重复。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/connection_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConnectionRecovery：ClientAction 的唯一执行处', () {
    test('rePair（notPaired）→ 清凭据 + 回配对页，给人话不是裸 401', () async {
      var cleared = 0;
      final messages = <String>[];
      var reported = 0;
      final recovery = ConnectionRecovery(
        clearCredentials: () async => cleared += 1,
        openPairing: messages.add,
        report: (_) => reported += 1,
      );

      await recovery.onTerminated(
        const ProtocolException(ErrorCode.notPaired, '换票被拒（HTTP 401）'),
      );

      expect(cleared, 1, reason: '身份不被认必须清掉本地凭据');
      expect(messages, hasLength(1));
      expect(messages.single, contains('不再认可本机'));
      expect(
        messages.single,
        isNot(contains('401')),
        reason: '别把裸 401 当成人话 —— 电脑侧今天把三种原因都归成 401',
      );
      expect(reported, 0);
    });

    test('revoked 同样是 rePair（停用 = 终态，恢复 = 重新扫码）', () async {
      var cleared = 0;
      final recovery = ConnectionRecovery(
        clearCredentials: () async => cleared += 1,
        openPairing: (_) {},
        report: (_) => fail('revoked 不该走到上报'),
      );
      await recovery.onTerminated(
        const ProtocolException(ErrorCode.revoked, '设备已停用'),
      );
      expect(cleared, 1);
    });

    test('映射不到的动作 → 照实上报，不清凭据、不回配对页（无静默兜底）', () async {
      var cleared = 0;
      var opened = 0;
      ProtocolException? reportedError;
      final recovery = ConnectionRecovery(
        clearCredentials: () async => cleared += 1,
        openPairing: (_) => opened += 1,
        report: (e) => reportedError = e,
      );

      await recovery.onTerminated(
        const ProtocolException(ErrorCode.internal, '未归类的终态'),
      );

      expect(cleared, 0, reason: '映射不到就绝不清凭据');
      expect(opened, 0, reason: '也不回配对页');
      expect(
        reportedError?.code,
        ErrorCode.internal,
        reason: '照实上报，而不是"试试看继续重连"',
      );
    });

    test('repair()（手动重新配对，议题 3）走同一条：清凭据 + 回配对页', () async {
      var cleared = 0;
      final messages = <String>[];
      final recovery = ConnectionRecovery(
        clearCredentials: () async => cleared += 1,
        openPairing: messages.add,
        report: (_) => fail('repair 不该走到上报'),
      );
      await recovery.repair();
      expect(cleared, 1);
      expect(messages.single, ConnectionRecovery.manualMessage);
    });
  });

  group('AppModel：只在连接终态时呈递 onConnectionTerminated', () {
    test('网络类 closed 不呈递；终态 closed 呈递一次且不重复', () async {
      final client = _RecoveryFakeClient();
      final surfaced = <ProtocolException>[];
      final app = AppModel(
        client: client,
        onConnectionTerminated: surfaced.add,
      );
      await app.start();

      // 网络类失败：连接层会自行退避 → app 不动作、不清凭据。
      client.emitClosed(
        terminal: false,
        error: const ProtocolException(ErrorCode.relayOffline, '中转不可达'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(surfaced, isEmpty, reason: '网络类失败由连接层退避，app 不动作');

      // 终态（身份不被认）：呈递一次。
      client.emitClosed(
        terminal: true,
        error: const ProtocolException(ErrorCode.notPaired, '换票被拒（HTTP 401）'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(surfaced, hasLength(1));
      expect(surfaced.single.code, ErrorCode.notPaired);

      // 再呈递同一个终态：不重复（一个连接周期只触发一次重新配对）。
      client.emitClosed(
        terminal: true,
        error: const ProtocolException(ErrorCode.notPaired, '换票被拒（HTTP 401）'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(surfaced, hasLength(1), reason: '不重复触发重新配对');

      app.dispose();
      await client.close();
    });
  });
}

/// 既能推连接状态、又是 `SyncClientProbe` 的假客户端。
///
/// `AppModel` 靠 `client is SyncClientProbe` 读 `lastConnectWasTerminal` /
/// `lastProtocolError` 判终态，所以这个替身必须**同时**实现两个接口 ——
/// 只实现 `SyncClient` 的话 `is SyncClientProbe` 为 false，呈递逻辑会被跳过
/// （那会让测试空转）。
class _RecoveryFakeClient implements SyncClient, SyncClientProbe {
  final _states = StreamController<ConnectionState>.broadcast();
  ConnectionState _state = ConnectionState.idle;
  ProtocolException? _lastError;
  bool _terminal = false;

  void emitClosed({required bool terminal, ProtocolException? error}) {
    _terminal = terminal;
    _lastError = error;
    _state = ConnectionState.closed;
    _states.add(ConnectionState.closed);
  }

  @override
  ConnectionState get state => _state;

  @override
  Stream<ConnectionState> get connection => _states.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> setAppState(AppState state) async {}

  @override
  Future<void> close() async => _states.close();

  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();

  @override
  Future<void> subscribe(String sid, {required int since}) async {}

  @override
  Future<void> unsubscribe(String sid) async {}

  @override
  Stream<SessionDelta> sessionUpdates(String sid) =>
      const Stream<SessionDelta>.empty();

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => null as T;

  // ---- SyncClientProbe ----

  @override
  List<(Map<String, Object?>, String)> get jobFrames => const [];

  @override
  List<Map<String, Object?>> get presenceFrames => const [];

  @override
  ProtocolException? get lastProtocolError => _lastError;

  @override
  int? get lastHalfOpenSilentMs => null;

  @override
  int? get lastCloseCode => null;

  @override
  String? get lastCloseReason => null;

  @override
  String? get lastHandshakeFailure => null;

  @override
  int get pendingCalls => 0;

  @override
  int? get lastRejectedCalls => null;

  @override
  Object? get lastPersistError => null;

  @override
  Map<String, int> get declaredSessions => const {};

  @override
  List<Map<String, Object?>> get sentRequests => const [];

  @override
  bool get lastConnectWasTerminal => _terminal;
}
