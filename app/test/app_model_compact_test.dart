/// 切换会话时**放掉不在看的正文**（`AppModel._compactIdleSessions`）。
///
/// ## 这个测试为什么这样写
///
/// 压缩的产物（`SessionStore.compact()`）在 `session_store_compact_test.dart` 里
/// 已经钉了"三个事实不变"。这里钉的是**触发条件与回来的路**，而这两件事只有
/// 一个可观察的行为差异：**下次打开时要不要从本地库读回来**。
///
/// 于是每条用例都在数 `readLocalItems` 的调用次数 —— 那正是线上会发生的事：
///
/// - 被压缩的会话 → 回来时读盘（正文从 sqflite 回填）；
/// - 在跑的 / 有待处理的 / 没本地库的 → 不压缩 → 回来时不读盘（正文一直在内存里）。
///
/// 这同时钉住了最危险的失效形态：**压缩之后回来只看到压缩后新到的那两条**
/// （`_restoreLocalHistory` 的早退条件写错就会这样）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/store.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

MessageItem _msg(String sid, int seq) => MessageItem(
  itemId: 'm$seq',
  seq: seq,
  updatedAt: seq,
  role: MessageRole.user,
  text: '$sid 第 $seq 条',
);

StoredItem _stored(String sid, int seq) => StoredItem(
  itemId: 'm$seq',
  sid: sid,
  seq: seq,
  kind: 'user/message',
  payloadJson:
      '{"id":"m$seq","role":"user","content":[{"type":"text","text":"$sid 第 $seq 条"}]}',
  updatedAt: seq,
);

class _Client extends FakeSyncClient {
  _Client({this.running = const <String>{}});

  /// 这些会话在 `session.list` 里被标成 `running`。
  final Set<String> running;

  final Map<String, StreamController<SessionDelta>> _deltas =
      <String, StreamController<SessionDelta>>{};

  StreamController<SessionDelta> controllerOf(String sid) => _deltas
      .putIfAbsent(sid, () => StreamController<SessionDelta>.broadcast());

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
  Stream<SessionDelta> sessionUpdates(String sid) => controllerOf(sid).stream;

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    // 改动记录要 `repo.info.caps.changes` 才发请求（老连接器不发）。
    if (method == 'repo.info') {
      return <String, Object?>{
            'protocol': 1,
            'caps': <String, Object?>{'changes': true},
            'methods': <String>[],
          }
          as T;
    }
    if (method == 'session.list') {
      return {
            'sessions': [
              for (final sid in <String>['a', 'b'])
                {
                  'sid': sid,
                  'updatedAt': 10,
                  'running': running.contains(sid),
                  'blank': false,
                  'subagent': false,
                  'projections': {
                    'kind': 'cached',
                    'asOfSeq': 1,
                    'values': {'title': sid},
                  },
                },
            ],
          }
          as T;
    }
    return <String, Object?>{} as T;
  }
}

/// 每次读盘都记一笔（判据就是它）。
({AppModel app, List<String> reads}) _build({
  String? tag,
  Set<String> running = const <String>{},
}) {
  final reads = <String>[];
  final client = _Client(running: running);
  final app = AppModel(
    client: client,
    // 不传 tag = 没有本地库的装配。
    readLocalItems: tag == null
        ? null
        : (sid) async {
            reads.add(sid);
            return [_stored(sid, 1), _stored(sid, 2)];
          },
  );
  return (app: app, reads: reads);
}

void main() {
  test('切走不跑的会话：正文被放掉，回来时从本地库回填', () async {
    final w = _build(tag: 'iso');
    addTearDown(w.app.dispose);

    // a 的内容**只在盘上**（不 seed）：所以第一次打开一定读盘。
    await w.app.openSession('a');
    expect(w.reads, ['a'], reason: '第一次打开：内存里没正文，读盘一次');
    expect(w.app.items, hasLength(2));

    // 切到 b（a 不在看、没在跑、没待处理 ⇒ 放掉 a 的正文）。
    w.app.seedForTest(
      sid: 'b',
      title: 'b',
      updatedAt: 10,
      items: [_msg('b', 1)],
    );
    await w.app.openSession('b');
    expect(
      w.app.hasVisibleItemsOf('a'),
      isTrue,
      reason: '"有内容"是事实：正文放掉了，判据不能跟着变成 false',
    );

    // 回到 a：必须重新读盘（否则只剩内存里那点残留）。
    await w.app.openSession('a');
    expect(w.reads, ['a', 'a'], reason: '被压缩过的会话，回来时要重新回填');
    expect(w.app.items, hasLength(2), reason: '回填后条目数与放掉前一致');
  });

  test('正在跑的会话不压缩（切走也不放）', () async {
    final w = _build(tag: 'iso', running: {'a'});
    addTearDown(w.app.dispose);
    await w.app.refreshSessionRows();

    await w.app.openSession('a');
    expect(w.reads, ['a']);
    w.app.seedForTest(
      sid: 'b',
      title: 'b',
      updatedAt: 10,
      items: [_msg('b', 1)],
    );
    await w.app.openSession('b');
    await w.app.openSession('a');

    expect(w.reads, ['a'], reason: '在跑的会话随时会追加条目，放掉等于刚放就要重建');
    expect(w.app.items, hasLength(2));
  });

  test('有待处理审批的会话不压缩（角标与提醒都长在条目上）', () async {
    final w = _build(tag: 'iso');
    addTearDown(w.app.dispose);

    w.app.seedForTest(
      sid: 'a',
      title: 'a',
      updatedAt: 10,
      items: [
        const ApprovalItem(
          itemId: 'i:ap1',
          seq: 1,
          updatedAt: 1,
          title: '允许写工作区外',
          decided: false,
        ),
      ],
    );
    await w.app.openSession('a');
    w.app.seedForTest(
      sid: 'b',
      title: 'b',
      updatedAt: 10,
      items: [_msg('b', 1)],
    );
    await w.app.openSession('b');
    await w.app.openSession('a');

    expect(w.reads, isEmpty, reason: '有待处理的会话一旦压缩，审批角标与提醒就没了');
    expect(w.app.items, hasLength(1));
  });

  test('没有本地库的装配：一律不压缩（读不回来就不放）', () async {
    final w = _build(); // readLocalItems == null
    addTearDown(w.app.dispose);

    w.app.seedForTest(
      sid: 'a',
      title: 'a',
      updatedAt: 10,
      items: [_msg('a', 1), _msg('a', 2)],
    );
    await w.app.openSession('a');
    w.app.seedForTest(
      sid: 'b',
      title: 'b',
      updatedAt: 10,
      items: [_msg('b', 1)],
    );
    await w.app.openSession('b');
    await w.app.openSession('a');

    expect(w.app.items, hasLength(2), reason: '没有回读能力就不该放掉正文');
  });

  test('改动记录缓存（按 <sid>:<seq>）跟着放掉，别人的不受影响', () async {
    final w = _build(tag: 'iso');
    addTearDown(w.app.dispose);

    // 两台会话各读过一条改动记录（键是 `<sid>:<seq>`）。
    await w.app.refreshRepoInfo(); // 能力位：没有 `caps.changes` 就不发请求
    await w.app.openSession('a');
    await w.app.loadChangesSummary(7);
    expect(w.app.changesStateOf(7).loaded, isTrue, reason: '读到了');

    await w.app.openSession('b');
    await w.app.loadChangesSummary(9);
    expect(w.app.changesStateOf(9).loaded, isTrue);
    // 注意：`changesStateOf` 的键取**当前会话**，所以此刻再问 7 拿到的是
    // `'b:7'`，必然 false —— 那**不能**当"被清掉了"的证据（第一版就是这么误判的，
    // 变异校验当场揭穿：不清缓存照样绿）。

    // 切回 a：若 a 的缓存被压缩清掉了，`changesStateOf(7)` 就是 false
    // （卡片会因此重新拉一次）；没清则仍是 true。
    await w.app.openSession('a');
    expect(
      w.app.changesStateOf(7).loaded,
      isFalse,
      reason: 'a 被压缩过 ⇒ 它的改动记录缓存一起放掉（重开这一屏会重拉）',
    );
  });

  test('blank 判据在压缩前后一致（宿主说 blank、手里有内容 ⇒ 不是新会话）', () async {
    final w = _build(tag: 'iso');
    addTearDown(w.app.dispose);

    w.app.seedForTest(
      sid: 'a',
      title: 'a',
      updatedAt: 10,
      items: [_msg('a', 1)],
      blank: true,
    );
    expect(w.app.sessionBlankOf('a'), isFalse, reason: '手里有东西就不是新会话');

    await w.app.openSession('a');
    w.app.seedForTest(
      sid: 'b',
      title: 'b',
      updatedAt: 10,
      items: [_msg('b', 1)],
    );
    await w.app.openSession('b');

    expect(w.app.sessionBlankOf('a'), isFalse, reason: '压缩放掉的是正文，不是"有内容"这个事实');
  });
}
