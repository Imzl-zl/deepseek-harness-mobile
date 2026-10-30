/// **被另一台设备占用**（`device/busy`）在手机侧的四处落点（多机第 4 步）。
///
/// 判据（方案准入门槛 4 的手机侧一半）：第二台的失败原因是 `device/busy`
/// （**不是** `not-paired`、**不是**超时），且界面说得出"是谁占着"。
///
/// 四处的分工不能混：
///
/// 1. `splitCloseReason`：把 `协议码 说明` 切成码与说明 —— 切坏了码会归成 `internal`；
/// 2. `SyncClientProbe.lastConnectBusy`：只有"被占用"这一档（连接层不再自动重连）；
/// 3. `AppModel._viewOf`：把它翻成界面的 `ConnectionStateView.busy`；
/// 4. `connectionSummary`：把占用者名字放进 note（**优先于**其余诊断句）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/endpoint.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 能推连接状态、能给出**诊断面**真值的替身（`AppModel._viewOf` 读的就是这一面）。
class _BusyClient extends FakeSyncClient implements SyncClientProbe {
  final _states = StreamController<ConnectionState>.broadcast();
  ConnectionState _state = ConnectionState.closed;

  bool busy = false;
  String? busyMessage;

  void emit(ConnectionState next) {
    _state = next;
    _states.add(next);
  }

  @override
  ConnectionState get state => _state;

  @override
  Stream<ConnectionState> get connection => _states.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> reconnect() async {}

  @override
  Future<void> close() async => _states.close();

  /// 进服务态会拉 `endpoint.describe` 与会话清单：回空对象就够（本组不关心它们）。
  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => <String, Object?>{} as T;

  // ---- 诊断面 ----
  @override
  bool get lastConnectBusy => busy;

  @override
  ProtocolException? get lastProtocolError =>
      busy ? ProtocolException(ErrorCode.deviceBusy, busyMessage ?? '') : null;

  @override
  bool get lastConnectWasTerminal => false;

  @override
  bool get lastConnectGaveUp => false;

  @override
  List<(Map<String, Object?>, String)> get jobFrames => const [];

  @override
  List<Map<String, Object?>> get presenceFrames => const [];

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
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();
}

void main() {
  group('关闭理由的形状（契约 §4.1：`协议码` 或 `协议码 说明`）', () {
    test('按第一个空格切：码在前、说明在后', () {
      const reason = 'device/busy 我的手机';
      final parsed = splitCloseReason(reason);
      expect(parsed.wire, 'device/busy');
      expect(parsed.detail, '我的手机');
    });

    test('不带说明：整串就是码（老连接器的形状）', () {
      final parsed = splitCloseReason('protocol/not-paired');
      expect(parsed.wire, 'protocol/not-paired');
      expect(parsed.detail, isNull);
    });

    test('说明里有空格也不影响切码（只切第一处）', () {
      final parsed = splitCloseReason('device/busy 客厅 那台');
      expect(parsed.wire, 'device/busy');
      expect(parsed.detail, '客厅 那台');
    });

    test('切出来的码能逐字命中封闭表（切坏了会归成 internal）', () {
      expect(
        ErrorCode.fromWire(splitCloseReason('device/busy Pixel').wire),
        ErrorCode.deviceBusy,
      );
      expect(
        ErrorCode.fromWire(splitCloseReason('handshake-timeout').wire),
        ErrorCode.internal,
        reason: '本地判定名不在表里 —— 这是**如实**的，不是缺陷',
      );
    });
  });

  group('AppModel：被占用翻成界面那一档', () {
    test('closed + 诊断面报被占用 ⇒ busy，且说得出占用者', () async {
      final client = _BusyClient();
      final app = AppModel(client: client);
      await app.start();

      client.busy = true;
      client.busyMessage = 'Pixel';
      client.emit(ConnectionState.closed);
      await Future<void>.delayed(Duration.zero);

      expect(app.connection, ConnectionStateView.busy);
      expect(app.busyOccupant, 'Pixel');
      // 文案与状态同源：`connectionLabel` 是唯一的说法。
      expect(connectionLabel(app.connection), '未连接 · 电脑被占用');
      app.dispose();
    });

    test('连上之后 busy 那一档作废（诊断面复位）', () async {
      final client = _BusyClient();
      final app = AppModel(client: client);
      await app.start();

      client.busy = true;
      client.busyMessage = 'Pixel';
      client.emit(ConnectionState.closed);
      await Future<void>.delayed(Duration.zero);
      expect(app.connection, ConnectionStateView.busy);

      client.busy = false; // 用户手动重试成功 → `_onEstablished` 复位
      client.emit(ConnectionState.serving);
      await Future<void>.delayed(Duration.zero);
      expect(app.connection, ConnectionStateView.serving);
      expect(app.busyOccupant, isNull);
      app.dispose();
    });
  });

  group('连接摘要：占用者优先于其它诊断句', () {
    const endpoint = Endpoint(kind: EndpointKind.direct, url: 'ws://a:1');

    test('busy 时 note 是占用者，不是"端点都拨不通"', () {
      final summary = connectionSummary(
        state: ConnectionStateView.busy,
        active: null,
        endpoints: const [endpoint],
        attemptOf: (_) =>
            const EndpointAttempt(ok: false, reason: '拨不通', atMs: 0),
        detail: 'Pixel',
      );
      expect(summary.line, '未连接 · 电脑被占用');
      expect(summary.note, 'Pixel');
    });

    test('拨号中的 hint 只在没有更具体原因时出现', () {
      final hint = connectionSummary(
        state: ConnectionStateView.connecting,
        active: null,
        endpoints: const [endpoint],
        attemptOf: (_) => null,
        hint: connectionHintAt(const Duration(seconds: 9)),
      );
      expect(hint.note, '网络很慢，仍在尝试…（最长 15 秒）');

      final detailWins = connectionSummary(
        state: ConnectionStateView.busy,
        active: null,
        endpoints: const [endpoint],
        attemptOf: (_) => null,
        hint: '正在连接…',
        detail: 'Pixel',
      );
      expect(detailWins.note, 'Pixel');
    });

    test('提示时序：2 s 出阶段、8 s 说慢、之前什么都不说', () {
      expect(connectionHintAt(const Duration(milliseconds: 1500)), isNull);
      expect(connectionHintAt(const Duration(seconds: 2)), '正在连接…');
      expect(
        connectionHintAt(const Duration(seconds: 8)),
        '网络很慢，仍在尝试…（最长 15 秒）',
      );
    });
  });
}
