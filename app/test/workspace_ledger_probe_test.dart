/// 抽屉里的「未分组」不该是终局：账本落后时补问一次。
///
/// 真机现象（2026-11-07）：在电脑上新建一个会话，手机抽屉里它先挂在「未分组」，
/// 过一会儿才归到工作区。根因不是分组算法（`bucketSessionsByWorkspace` 是纯函数），
/// 而是**分组只认 `workspace.list` 的 `sessionIds`**，而 `session.list` 的那一行
/// 到达我们这边时，账本未必跟着更新过 —— 登记表里账本没有 `notification` 触发点
/// （`host_state.dart` 的口径：工作区没有宿主事件）。
///
/// 判据两条：
/// 1. 出现"不在任何工作区里的会话"时**自动补问一次**账本，回来就按宿主的分组显示；
/// 2. 同一个会话**只问一次** —— 问过还没归组，说明宿主此刻确实没放它进工作区，
///    再问就是替宿主做重试。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 按方法给固定应答的替身；`workspace.list` 记次数（判"补问了几次"）。
class _LedgerClient extends FakeSyncClient {
  _LedgerClient({required this.rows, required this.ledger});

  List<Map<String, Object?>> rows;
  Map<String, Object?> ledger;
  int ledgerCalls = 0;

  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();
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
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    switch (method) {
      case 'session.list':
        return <String, Object?>{'sessions': rows} as T;
      case 'workspace.list':
        ledgerCalls += 1;
        return ledger as T;
      default:
        return <String, Object?>{} as T;
    }
  }
}

Map<String, Object?> _row(
  String sid, {
  int updatedAt = 1,
  bool blank = false,
}) => <String, Object?>{
  'sid': sid,
  'cwd': r'D:\w1',
  'updatedAt': updatedAt,
  'blank': blank,
  // 恒发键：连接器对每一行无条件写出它们（`connector/src/handlers.ts:740-744`）。
  'running': false,
  'subagent': false,
};

Map<String, Object?> _ledger(List<String> sessionIds) => <String, Object?>{
  'workspaces': <Map<String, Object?>>[
    <String, Object?>{
      'workspaceId': 'w1',
      'title': 'W1',
      'path': r'D:\w1',
      'sessionIds': sessionIds,
      'createdAt': '',
    },
  ],
  'archivedSessionIds': const <String>[],
  'pinnedSessionIds': const <String>[],
};

/// 抽屉看到的桶（与 `SessionDrawer` 同一份纯函数）。
///
/// 排序档与时间键都从 `AppModel` 读 —— 与装配层（`main.dart` / `chat_page.dart`）
/// 完全同一条接线，于是这里量到的顺序就是真机上那份顺序。
List<WorkspaceBucket> _buckets(AppModel app) => bucketSessionsByWorkspace(
  [for (final s in app.sessions) s.sid],
  app.workspaces,
  isBlank: app.sessionBlankOf,
  order: app.sessionOrder,
  updatedAtOf: app.updatedAtOf,
);

void main() {
  test('新会话不在账本里 ⇒ 自动补问一次，回来就归组', () async {
    final client = _LedgerClient(rows: [_row('s1')], ledger: _ledger(['s1']));
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.start();
    // 首屏顺序：先清单、后账本（`host_state.dart` 的 connectLanding 一列）。
    await app.refreshSessionRows();
    await app.refreshWorkspaces();
    expect(client.ledgerCalls, 1, reason: '首屏读一次账本');

    // 电脑上新建了一个会话：清单多一行，账本也跟着变（宿主的两次写）。
    client.rows = [_row('s1'), _row('s2', updatedAt: 2)];
    client.ledger = _ledger(['s1', 's2']);
    await app.refreshSessionRows();
    // 补问是异步的，让它跑完。
    await Future<void>.delayed(Duration.zero);

    expect(client.ledgerCalls, 2, reason: '出现未归组的会话 ⇒ 补问一次账本');
    expect(
      _buckets(app).single.sessionIds,
      ['s2', 's1'],
      reason: '归组照宿主给的账本（两个都在 w1 里，没有「未分组」）；组内顺序照默认档「最近更新」⇒ s2(2) 在 s1(1) 前面',
    );
  });

  // AppModel → 分区这条接线：判据是 `sessionBlankOf`（宿主 blank + 本地无可见条目），
  // 不是行上的 `blank` 字段。场景是真实形态：复用一个老 blank，账本里它排在别的会话后面。
  // 注：`main.dart` 传参那一处只有类型兜底（`isBlank` 是必填），没有端到端用例。
  test('账本把新会话排在后面，它照样打头（分区读的是 AppModel 的 blank 判据）', () async {
    final client = _LedgerClient(
      rows: [_row('s2', updatedAt: 2), _row('s1', blank: true)],
      ledger: _ledger(['s2', 's1']),
    );
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.start();
    await app.refreshSessionRows();
    await app.refreshWorkspaces();

    expect(_buckets(app).single.sessionIds, [
      's1',
      's2',
    ], reason: 'blank 行打头，不跟账本序（账本里 s1 在后）');
  });

  test('同一个会话只补问一次：宿主没归组就不再问', () async {
    final client = _LedgerClient(rows: [_row('s1')], ledger: _ledger(['s1']));
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.start();
    await app.refreshSessionRows();
    await app.refreshWorkspaces();
    expect(client.ledgerCalls, 1, reason: '首屏读一次账本');

    // 清单多了 s2，而账本**始终**没有它（宿主没把它放进任何工作区）。
    client.rows = [_row('s1'), _row('s2', updatedAt: 2)];
    await app.refreshSessionRows();
    await Future<void>.delayed(Duration.zero);
    expect(client.ledgerCalls, 2, reason: '第一次出现 ⇒ 问一次');

    await app.refreshSessionRows();
    await Future<void>.delayed(Duration.zero);
    expect(client.ledgerCalls, 2, reason: '问过还没归组 ⇒ 不再重复问');

    expect(
      _buckets(app).map((b) => b.label),
      contains('未分组'),
      reason: '宿主没归组就如实停在「未分组」，不是我们猜一个工作区',
    );
  });
}
