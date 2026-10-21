/// 子智能体这条链的数据面回归（`subagentCatalog` 投影 → 目录三态 + 行指标）。
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
/// 读面在 `subagentCatalog` 投影里（`catalog.ts:121-131`）。
///
/// ## 2026-10-21 补的三件事
///
/// 1. **三态**：`loading` / `ready` / `error` 必须分开 —— 原来"读到空"与
///    "没读到"都是同一句「没有子智能体」（本仓第八条教训 4：空有两种表达）。
/// 2. **行指标**：`session.list` 行早就原样带着
///    `projections.values.subagentTiming` / `tokenUsage`
///    （`connector/src/handlers.ts:527-533`），手机此前只取了 `title`。
/// 3. **不污染当前会话**：读子级的目录不能覆盖当前会话的投影包
///    （统计条 / 标题 / 权限档的来源）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/subagent.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

typedef _Handler =
    Future<Object?> Function(String method, Map<String, Object?> params);

class _SubClient extends FakeSyncClient {
  _SubClient({this.onCall});

  final _Handler? onCall;
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
    final result = await onCall?.call(method, params);
    return result as T;
  }
}

/// 一行 `session.list`：只有 `projections.values` 里那三个键是这组关心的。
Map<String, Object?> _sessionRow({
  required String sid,
  String title = '',
  bool running = false,
  bool subagent = false,
  Map<String, Object?>? timing,
  Map<String, Object?>? tokenUsage,
}) {
  // **显式 `if` 赋值，不用 null-aware element**：`?x: x` 在 map 里会让键
  // 取值的字符串形式（`tools.md` 记过这个坑），而 `dart analyze` 恰恰会
  // 反过来建议改过去（`use_null_aware_elements`）—— 别听。
  final values = <String, Object?>{};
  if (title.isNotEmpty) values['title'] = title;
  if (timing != null) values['subagentTiming'] = timing;
  if (tokenUsage != null) values['tokenUsage'] = tokenUsage;
  return {
    'sid': sid,
    'updatedAt': 1,
    'running': running,
    'subagent': subagent,
    'projections': {'kind': 'hints', 'asOfSeq': 1, 'values': values},
  };
}

const Map<String, Object?> _usage = {
  'uncachedInputTokens': 1000,
  'outputTokens': 200,
  'cacheReadTokens': 40000,
  'cacheWriteTokens': 500,
};

List<Map<String, Object?>> _catalogRow({
  required String id,
  required String mode,
  String? label,
}) {
  final row = <String, Object?>{'id': id, 'createdAt': 1000, 'mode': mode};
  if (label != null) row['label'] = label;
  return [row];
}

void main() {
  group('目录三态（空 / 没读到 / 失败是三个说法）', () {
    test('没读过一个会话的目录：loading，不是"没有子智能体"', () async {
      final app = AppModel(client: _SubClient(onCall: (m, p) async => null));
      await app.start();

      final catalog = app.subagentCatalogOf('sid_A');
      expect(catalog.state, SubagentCatalogState.loading);
      expect(catalog.entries, isEmpty);
      // **只有"成功读到且为空"才敢说它没有下级**（Web `:196-198`）。
      expect(catalog.isKnownLeaf, isFalse);
      expect(catalog.isLoadingEmpty, isTrue);
      app.dispose();
    });

    test('读到内容：ready + 直接子级顺序照投影', () async {
      final app = AppModel(
        client: _SubClient(
          onCall: (m, p) async => m == 'session.projections'
              ? {
                  'subagentCatalog': [
                    ..._catalogRow(
                      id: 'child-1',
                      mode: 'continuable',
                      label: '调研实现',
                    ),
                    ..._catalogRow(
                      id: 'child-2',
                      mode: 'one-shot',
                      label: '抽图标',
                    ),
                  ],
                }
              : {'sessions': <Object?>[]},
        ),
      );
      await app.start();
      await app.openSession('sid_A');

      final catalog = app.subagentCatalogOf('sid_A');
      expect(catalog.state, SubagentCatalogState.ready);
      expect(catalog.entries.map((r) => r.id).toList(), ['child-1', 'child-2']);
      expect(catalog.entries[0].displayLabel, '调研实现');
      expect(catalog.entries[0].mode, 'continuable');
      expect(catalog.isKnownLeaf, isFalse);
      app.dispose();
    });

    test('成功读到且为空：才算已知空叶', () async {
      final app = AppModel(
        client: _SubClient(
          onCall: (m, p) async => m == 'session.projections'
              ? {'subagentCatalog': <Object?>[]}
              : null,
        ),
      );
      await app.start();
      await app.openSession('sid_A');

      final catalog = app.subagentCatalogOf('sid_A');
      expect(catalog.state, SubagentCatalogState.ready);
      expect(catalog.entries, isEmpty);
      expect(catalog.isKnownLeaf, isTrue);
      expect(catalog.isLoadingEmpty, isFalse);
      app.dispose();
    });

    test('读失败：error 态（不是空），并留声到 lastError', () async {
      final app = AppModel(
        client: _SubClient(
          onCall: (m, p) async => m == 'session.projections'
              ? throw const ProtocolException(ErrorCode.internal, 'boom')
              : null,
        ),
      );
      await app.start();
      await app.openSession('sid_A');

      final catalog = app.subagentCatalogOf('sid_A');
      expect(catalog.state, SubagentCatalogState.error);
      expect(catalog.isKnownLeaf, isFalse, reason: '读失败不是"它没有下级"的证据');
      expect(catalog.isLoadingEmpty, isFalse, reason: '失败不能显示成"正在加载"');
      expect(app.lastError, isNotNull, reason: '原始原因只有这一个出处');
      app.dispose();
    });

    test('应答不是对象：error 态（不静默当空）', () async {
      final app = AppModel(
        client: _SubClient(
          onCall: (m, p) async => m == 'session.projections' ? '不是对象' : null,
        ),
      );
      await app.start();
      await app.openSession('sid_A');

      expect(app.subagentCatalogOf('sid_A').state, SubagentCatalogState.error);
      app.dispose();
    });

    test('刷新时保留旧内容（loading 不闪空）', () async {
      var calls = 0;
      final gate = Completer<void>();
      final app = AppModel(
        client: _SubClient(
          onCall: (m, p) async {
            if (m != 'session.projections') return null;
            calls += 1;
            if (calls > 1) await gate.future;
            return {
              'subagentCatalog': _catalogRow(
                id: 'child-1',
                mode: 'continuable',
                label: '调研实现',
              ),
            };
          },
        ),
      );
      await app.start();
      await app.openSession('sid_A');
      expect(app.subagentCatalogOf('sid_A').entries, hasLength(1));

      final pending = app.refreshProjections('sid_A');
      // 读之前就置 loading —— 但**旧内容还在**（Web `:244-245` 同一条）。
      final during = app.subagentCatalogOf('sid_A');
      expect(during.state, SubagentCatalogState.loading);
      expect(during.entries, hasLength(1));
      expect(during.isLoadingEmpty, isFalse);

      gate.complete();
      await pending;
      expect(app.subagentCatalogOf('sid_A').state, SubagentCatalogState.ready);
      app.dispose();
    });
  });

  group('行的指标来自 session.list 的投影提示', () {
    Map<String, Object?> rows() => {
      'sessions': [
        _sessionRow(sid: 'sid_A', title: '父会话'),
        _sessionRow(
          sid: 'child-1',
          title: '调研实现',
          running: true,
          subagent: true,
          timing: {
            'settledMs': 1500,
            'active': {'since': 10000, 'through': 12000},
          },
          tokenUsage: _usage,
        ),
        _sessionRow(
          sid: 'child-2',
          running: false,
          subagent: true,
          timing: {'settledMs': 9000, 'lastTurnCompleted': true},
        ),
      ],
    };

    test('timing / token 都解析进会话行；running 来自行自己', () async {
      final app = AppModel(
        client: _SubClient(
          onCall: (m, p) async => m == 'session.list' ? rows() : null,
        ),
      );
      await app.start();
      await app.refreshSessions();

      final child = app.sessionOf('child-1')!;
      expect(child.running, isTrue);
      expect(child.title, '调研实现');
      expect(child.subagentTiming!.settledMs, 1500);
      expect(child.subagentTiming!.activeSince, 10000);
      expect(child.subagentTiming!.activeThrough, 12000);
      expect(child.subagentTiming!.lastTurnCompleted, isFalse);
      // 四桶之和 = 1000 + 200 + 40000 + 500。
      expect(child.tokenUsage!.grandTotal, 41700);

      final done = app.sessionOf('child-2')!;
      expect(done.running, isFalse);
      expect(done.subagentTiming!.lastTurnCompleted, isTrue);
      expect(done.tokenUsage, isNull, reason: '没有这个键就是没给，不是全零');
      app.dispose();
    });

    test('形状认不出：timing / token 各自为 null（不补零）', () async {
      final app = AppModel(
        client: _SubClient(
          onCall: (m, p) async => m == 'session.list'
              ? {
                  'sessions': [
                    _sessionRow(
                      sid: 'child-1',
                      timing: {
                        'active': {'since': 1},
                      }, // 缺 settledMs
                      tokenUsage: {'uncachedInputTokens': 3}, // 缺三个桶
                    ),
                  ],
                }
              : null,
        ),
      );
      await app.start();
      await app.refreshSessions();

      final row = app.sessionOf('child-1')!;
      expect(row.subagentTiming, isNull);
      expect(row.tokenUsage, isNull);
      app.dispose();
    });
  });

  group('读子级目录不污染当前会话', () {
    test('refreshSubagentCatalog(child) 只写那个子级的目录', () async {
      final app = AppModel(
        client: _SubClient(
          onCall: (m, p) async {
            if (m != 'session.projections') return null;
            if (p['sid'] == 'child-1') {
              return {
                'subagentCatalog': _catalogRow(
                  id: 'grand-1',
                  mode: 'one-shot',
                  label: '孙级',
                ),
                // 子会话自己的投影包（若被误写进 _projections，
                // 统计条与标题就会跳到子会话的）。
                'title': '子会话标题',
                'tokenUsage': {
                  'uncachedInputTokens': 7,
                  'outputTokens': 7,
                  'cacheReadTokens': 7,
                  'cacheWriteTokens': 7,
                },
              };
            }
            return {
              'subagentCatalog': _catalogRow(
                id: 'child-1',
                mode: 'continuable',
                label: '调研实现',
              ),
              'title': '父会话',
              'tokenUsage': _usage,
            };
          },
        ),
      );
      await app.start();
      await app.openSession('sid_A');
      expect(app.tokenUsage!.grandTotal, 41700);

      await app.refreshSubagentCatalog('child-1');

      expect(
        app.subagentCatalogOf('child-1').entries.map((r) => r.id).toList(),
        ['grand-1'],
        reason: '展开子级读到的就是它自己的直接子级',
      );
      expect(
        app.subagentCatalogOf('sid_A').entries.map((r) => r.id).toList(),
        ['child-1'],
        reason: '父会话的目录不该被孙级覆盖',
      );
      expect(app.tokenUsage!.grandTotal, 41700, reason: '统计条读的是当前会话');
      expect(app.projections!['title'], '父会话');
      app.dispose();
    });

    test('refreshSubagentCatalog(current) 顺手更新当前会话那一包', () async {
      final app = AppModel(
        client: _SubClient(
          onCall: (m, p) async => m == 'session.projections'
              ? {'subagentCatalog': <Object?>[], 'title': '重新读到的标题'}
              : null,
        ),
      );
      await app.start();
      await app.openSession('sid_A');
      await app.refreshSubagentCatalog('sid_A');
      expect(app.projections!['title'], '重新读到的标题');
      app.dispose();
    });
  });

  group('解析边界', () {
    test('形状不对：跳过坏条目，不抛', () async {
      final app = AppModel(
        client: _SubClient(
          onCall: (m, p) async => m == 'session.projections'
              ? {
                  'subagentCatalog': [
                    {'id': 'ok', 'createdAt': 1, 'mode': 'continuable'},
                    {'createdAt': 2, 'mode': 'one-shot'}, // 缺 id
                    {'id': 'x', 'createdAt': '不是数字', 'mode': 'one-shot'},
                    {'id': 'y', 'createdAt': 3}, // 缺 mode
                    '不是对象',
                  ],
                }
              : null,
        ),
      );
      await app.start();
      await app.openSession('sid_A');

      expect(app.subagentCatalogOf('sid_A').entries.map((r) => r.id).toList(), [
        'ok',
      ]);
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
  });
}
