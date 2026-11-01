/// 会话列表的分页（契约 §5.7 的 `session.list` `{limit, offset}` + `hasMore`）。
///
/// ## 这一组守什么
///
/// 一次性重取整表（本机 351 行 ~250 KB）在每次标题变更 / 切模型时都要付一遍，
/// 而屏幕上只有十来行。分页之后有四件事必须钉住，任何一条错了都表现为
/// "翻着翻着少了几条 / 列表里出现两条一样的 / 翻过的页被一条通知打回第一页"：
///
/// 1. **刷新只问已加载窗口**（首屏 = 一页；翻过页之后问的是"翻过多少"）；
/// 2. **加载更多从 `offset = 已加载行数` 接着要**；
/// 3. **按 `sid` 去重**（宿主按活动排序，两次翻页之间可能有会话移动）；
/// 4. **`hasMore: false` 之后不再发请求**（翻到底就停，别一直问）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

/// 记账替身：把 `session.list` 每一次的 (limit, offset) 记下来，按页回行。
class _PagingClient extends FakeSyncClient {
  _PagingClient({required this.total, this.repeatFirstRowOfSecondPage = false});

  /// 宿主那一份清单有多少行。
  final int total;

  /// 第二页故意**重复第一页的最后一行**（模拟"两次翻页之间会话移动了"）。
  final bool repeatFirstRowOfSecondPage;

  /// 每次 `session.list` 的参数（按调用顺序）。
  final List<({int? limit, int? offset})> requests = <({int? limit, int? offset})>[];

  Map<String, Object?> _row(int index) => <String, Object?>{
    'sid': 'sid_$index',
    'updatedAt': 1000 - index,
    'running': false,
    'blank': false,
    'subagent': false,
  };

  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();
  @override
  Stream<HostStateChanged> get hostStateChanges => const Stream.empty();
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
    if (method != 'session.list') {
      return <String, Object?>{'values': <String, Object?>{}} as T;
    }
    final limit = params['limit'] as int?;
    final offset = (params['offset'] as int?) ?? 0;
    requests.add((limit: limit, offset: offset));
    final end = limit == null ? total : (offset + limit).clamp(0, total);
    final rows = <Map<String, Object?>>[
      for (var i = offset; i < end; i += 1) _row(i),
    ];
    if (repeatFirstRowOfSecondPage && offset > 0) {
      // 把上一页最后一行再塞一次（真实世界里是"那条会话活动更新、位置后移"）。
      rows.insert(0, _row(offset - 1));
    }
    return <String, Object?>{
      'sessions': rows,
      'hasMore': limit != null && offset + limit < total,
    } as T;
  }
}

Future<AppModel> _started(_PagingClient client) async {
  final app = AppModel(client: client);
  await app.start();
  return app;
}

void main() {
  test('首屏只要一页：limit = kSessionRowPageSize，且不带 offset', () async {
    final client = _PagingClient(total: 120);
    final app = await _started(client);
    addTearDown(app.dispose);

    await app.refreshSessionRows();
    expect(client.requests, <({int? limit, int? offset})>[
      (limit: kSessionRowPageSize, offset: 0),
    ]);
    expect(app.sessions.length, kSessionRowPageSize);
    expect(app.hasMoreSessions, isTrue);
  });

  test('加载更多从已加载行数接着要，并追加（不替换）', () async {
    final client = _PagingClient(total: 120);
    final app = await _started(client);
    addTearDown(app.dispose);

    await app.refreshSessionRows();
    final firstIds = app.sessions.map((s) => s.sid).toList();

    await app.loadMoreSessionRows();
    expect(client.requests.last, (limit: kSessionRowPageSize, offset: kSessionRowPageSize));
    expect(app.sessions.length, kSessionRowPageSize * 2);
    // 前一半还是原来那批（顺序不变），新行接在后面。
    expect(app.sessions.take(kSessionRowPageSize).map((s) => s.sid), firstIds);
    expect(app.sessions.last.sid, 'sid_99');
    expect(app.hasMoreSessions, isTrue);

    await app.loadMoreSessionRows();
    expect(app.sessions.length, 120);
    expect(app.hasMoreSessions, isFalse, reason: '翻到底就该说没有了');
  });

  test('翻到底之后不再发请求（hasMore: false 就停）', () async {
    final client = _PagingClient(total: 60);
    final app = await _started(client);
    addTearDown(app.dispose);

    await app.refreshSessionRows();
    await app.loadMoreSessionRows();
    expect(app.hasMoreSessions, isFalse);
    final before = client.requests.length;
    await app.loadMoreSessionRows();
    expect(client.requests.length, before, reason: '没有下一页就别再问一次');
  });

  test('按 sid 去重：跨页重复的行不会出现两遍', () async {
    final client = _PagingClient(total: 120, repeatFirstRowOfSecondPage: true);
    final app = await _started(client);
    addTearDown(app.dispose);

    await app.refreshSessionRows();
    await app.loadMoreSessionRows();
    final ids = app.sessions.map((s) => s.sid).toList();
    expect(ids.toSet().length, ids.length, reason: '一个 sid 只能有一行');
  });

  test('要整表时一并把窗口撑到整表，之后刷新不再只问一页', () async {
    // 判据来自 `AppModel.ensureFullSessionRows` 的四条：搜索 / 落点 / 归档 / 子智能体面板
    // 都需要"整份清单"，它们不是"浏览列表"。这里钉**机制**，四条调用点各自在 UI 层接。
    final client = _PagingClient(total: 120);
    final app = await _started(client);
    addTearDown(app.dispose);

    await app.refreshSessionRows();
    expect(app.hasMoreSessions, isTrue);

    await app.ensureFullSessionRows();
    expect(client.requests.last, (limit: null, offset: 0), reason: '整表 = 不带 limit');
    expect(app.sessions.length, 120);
    expect(app.hasMoreSessions, isFalse);

    // 窗口被撑到整表：之后的通知刷新照旧拿全量（不再只问一页）。
    await app.refreshSessionRows();
    expect(client.requests.last, (limit: 120, offset: 0));
  });

  test('已加载窗口不缩水：翻过页之后刷新问的是"翻过多少"', () async {
    final client = _PagingClient(total: 120);
    final app = await _started(client);
    addTearDown(app.dispose);

    await app.refreshSessionRows();
    await app.loadMoreSessionRows();
    await app.refreshSessionRows();
    expect(
      client.requests.last,
      (limit: kSessionRowPageSize * 2, offset: 0),
      reason: '一条通知到达时不该把用户翻过的页丢掉',
    );
    expect(app.sessions.length, kSessionRowPageSize * 2);
  });
}
