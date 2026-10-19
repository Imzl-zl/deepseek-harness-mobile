/// 子智能体这条链的回归（`subagentCatalog` 投影 → 面板）。
///
/// ## 为什么单独一组
///
/// 2026-10-15 之前这里是**两条写死的示例**（`Extract DSH icon paths` /
/// `Research rikkahub standalone mode`），状态文字带「· 示例」——
/// 标记是有，但它**无条件**出现在面板里，真连上了也照显示。
///
/// 而"能接"这个结论是**翻案**得来的：上一轮我判成"阻塞"，
/// 依据是 `subagents.listChildren` / `listDescendants` 没有 `@Remote`
/// （`packages/subagent/subagent/src/index.ts:374,393`，已核实）。
/// **找错了门** —— `SubagentRuntime` 本身就是 `TypertRemoteService`（`:192`），
/// 读面在 `subagentCatalog` 投影里（`catalog.ts:122`）。
/// 所以这里除了钉行为，还要钉"投影是唯一入口"这件事别再被忘记。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

class _SubClient extends FakeSyncClient {
  _SubClient({this.onCall});

  final Object? Function(String method, Map<String, Object?> params)? onCall;
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
    final result = onCall?.call(method, params);
    return result as T;
  }
}

void main() {
  test('subagentCatalog 投影 → 列表', () async {
    final client = _SubClient(
      onCall: (m, p) => m == 'session.projections'
          ? {
              'subagentCatalog': [
                {
                  'id': 'child-1',
                  'createdAt': 1000,
                  'mode': 'continuable',
                  'label': '调研实现',
                },
                {
                  'id': 'child-2',
                  'createdAt': 2000,
                  'mode': 'one-shot',
                  'label': '抽图标',
                },
              ],
            }
          : null,
    );
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');

    final rows = app.subagentsOf('sid_A');
    expect(rows.map((r) => r.id).toList(), ['child-1', 'child-2']);
    expect(rows[0].displayLabel, '调研实现');
    expect(rows[0].mode, 'continuable');
    expect(rows[0].isLive, isTrue);
    // `one-shot` 是终态 —— 与 DSH 的 mode 词汇表对应，不自己造。
    expect(rows[1].status, 'completed');
    expect(rows[1].isLive, isFalse);
    app.dispose();
  });

  test('没有 subagentCatalog 键：空表（不造假的）', () async {
    final client = _SubClient(
      onCall: (m, p) => m == 'session.projections' ? {'tokenUsage': {}} : null,
    );
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');

    expect(app.subagentsOf('sid_A'), isEmpty);
    app.dispose();
  });

  test('形状不对：跳过坏条目，不抛', () async {
    final client = _SubClient(
      onCall: (m, p) => m == 'session.projections'
          ? {
              'subagentCatalog': [
                {'id': 'ok', 'createdAt': 1, 'mode': 'continuable'},
                {'createdAt': 2, 'mode': 'one-shot'}, // 缺 id
                {'id': 'x', 'createdAt': '不是数字', 'mode': 'one-shot'}, // 时间戳坏
                {'id': 'y', 'createdAt': 3}, // 缺 mode
                '不是对象',
              ],
            }
          : null,
    );
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');

    expect(app.subagentsOf('sid_A').map((r) => r.id).toList(), ['ok']);
    app.dispose();
  });

  test('缺 label 时靠 id 显示（不留空行）', () {
    const row = SubagentRow(id: 'child-9', createdAt: 1, mode: 'continuable');
    expect(row.displayLabel, 'child-9');
  });

  test('parseSubagentCatalog：非 Map / 非数组都是空表', () {
    expect(parseSubagentCatalog(null), isEmpty);
    expect(parseSubagentCatalog('x'), isEmpty);
    expect(parseSubagentCatalog({'subagentCatalog': 'x'}), isEmpty);
  });
}
