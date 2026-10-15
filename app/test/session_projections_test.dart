/// 会话投影这条链的回归（`session.projections` → 统计条 / 空态）。
///
/// ## 为什么单独一组
///
/// 2026-10-15 之前统计条三条全是写死的：`第 1 轮 · N 步` /
/// `302K · 缓存 0%` / `3%`（`chat_page.dart`）。它们与电脑侧毫无关系，
/// 而**用户无法分辨哪个是真的** —— 这是假数据最坏的地方。
///
/// 所以这里钉的不只是"能显示真值"，而是：
/// 1. 形状认不出时**整条不显示**，不猜数字；
/// 2. 缓存率算不出（没有输入）时**不拼那半句**，不显示 `缓存 0%`；
/// 3. 轮次为 0 时不说"第 0 轮"。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/session_stats.dart';
import 'package:flutter_test/flutter_test.dart';

class _ProjClient implements SyncClient {
  _ProjClient({this.onCall});

  final Object? Function(String method, Map<String, Object?> params)? onCall;
  final List<String> called = [];
  final _jobs = StreamController<JobFrame>.broadcast();

  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => _jobs.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> subscribe(String sid, {required int since}) async {}
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
    called.add(method);
    final result = onCall?.call(method, params);
    return result as T;
  }
}

/// 一个"什么投影都有"的应答（形状照 DSH 的 viewSchema）。
Map<String, Object?> _fullProjections() => {
  'tokenUsage': {
    'uncachedInputTokens': 1000,
    'outputTokens': 200,
    'cacheReadTokens': 40000,
    'cacheWriteTokens': 500,
  },
  'sessionStats': {'turns': 3, 'steps': 12, 'llmMs': 4200, 'toolMs': 800},
  'contextPressure': {'pressureTokens': 41000, 'projectedTokens': 44000},
};

void main() {
  test('点开会话就读一次投影', () async {
    final client = _ProjClient(
      onCall: (m, p) => m == 'session.projections' ? _fullProjections() : null,
    );
    final app = AppModel(client: client);
    await app.start();

    await app.openSession('sid_A');

    expect(client.called, contains('session.projections'));
    expect(app.projections, isNotNull);
    app.dispose();
  });

  test('统计条三条各自解析（形状照 DSH 的 viewSchema）', () async {
    final client = _ProjClient(
      onCall: (m, p) => m == 'session.projections' ? _fullProjections() : null,
    );
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');

    final usage = app.tokenUsage!;
    expect(usage.uncachedInputTokens, 1000);
    expect(usage.cacheReadTokens, 40000);
    // 40000 / (41700 + 200) ≈ 0.951
    expect(usage.cacheHitRate! > 0.94 && usage.cacheHitRate! < 0.96, isTrue);
    // 41700 / 1000 = 41.7 → ≥10 所以取整成 `42K`（与原来的 `302K` 同格式）。
    expect(usage.totalLabel, '42K');

    final stats = app.sessionStats!;
    expect(stats.turns, 3);
    expect(stats.steps, 12);
    expect(stats.turnLabel, '第 3 轮 · 12 步');
    app.dispose();
  });

  test('投影读不到：三个 getter 全 null（不猜数字）', () async {
    final client = _ProjClient(onCall: (m, p) => null);
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');

    expect(app.projections, isNull);
    expect(app.tokenUsage, isNull);
    expect(app.sessionStats, isNull);
    expect(app.contextPressure, isNull);
    app.dispose();
  });

  test('形状不对：当没有，不抛', () async {
    final client = _ProjClient(
      onCall: (m, p) => m == 'session.projections'
          ? {
              'tokenUsage': '不是对象',
              'sessionStats': {'turns': '不是数字'},
              'contextPressure': {'pressureTokens': 'x'},
            }
          : null,
    );
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');

    expect(app.tokenUsage, isNull);
    // `turns` 不是数字时按 0 算，于是 `turnLabel` 是 null（不说"第 0 轮"）。
    expect(app.sessionStats!.turnLabel, isNull);
    expect(app.contextPressure, isNull);
    app.dispose();
  });

  test('`session.projections` 失败：留声但不炸', () async {
    final client = _ProjClient(
      onCall: (m, p) => throw const ProtocolException(
        ErrorCode.connectorUnsupported,
        'session.projections 尚未实现',
      ),
    );
    final app = AppModel(client: client);
    await app.start();

    await app.openSession('sid_A');

    expect(app.lastError, isNotNull, reason: '失败必须留声');
    expect(app.projections, isNull);
    app.dispose();
  });

  test('缓存率：没有输入时是 null（除零会传出 NaN%）', () {
    const usage = TokenUsage(
      uncachedInputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
    );
    expect(usage.cacheHitRate, isNull);
    expect(usage.totalLabel, '0');
  });

  test('formatTokenCount：K / M 的进位', () {
    expect(formatTokenCount(999), '999');
    expect(formatTokenCount(1000), '1.0K');
    expect(formatTokenCount(9500), '9.5K');
    expect(formatTokenCount(41000), '41K');
    expect(formatTokenCount(1_200_000), '1.2M');
    expect(formatTokenCount(15_000_000), '15M');
  });

  test('turnLabel：轮次为 0 时是 null（不说"第 0 轮"）', () {
    const stats = SessionStats(turns: 0, steps: 0, llmMs: 0, toolMs: 0);
    expect(stats.turnLabel, isNull);
  });
}
