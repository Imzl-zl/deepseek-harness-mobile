/// 冷启动：把本地库的条目与水位接回来（`core/session_restore.dart` 的判据）。
///
/// 三条判据，每条都有真实的失效形态：
///
/// 1. **有内容才认水位**：读不到条目就**不调** `restoreSession` —— 否则就是
///    "声称我有到 N、界面却是空的"（唯一不可接受的方向）；
/// 2. **水位取内容的上界**，不取 `cursors` 表里的计数器（那个数在"事件因空洞
///    没入库、却照样落了盘"时可能超前于内容）—— 这里用一条 seq 不连续的输入证明
///    我们取的是**条目自己的**上界；
/// 3. **`outcome == snapshot` 是整份替换**（不是 upsert）：本地那段历史与电脑侧
///    对不上时，以电脑侧为准（契约 §5.4 规则 4）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/recovery.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 一行本地库记录（事件原文落在 `payloadJson` 里）。
StoredItem _stored(String sid, int seq) => StoredItem(
  itemId: 'm$seq',
  sid: sid,
  seq: seq,
  kind: 'user/message',
  // `user/message` 的载荷**本身就是消息**（`{id, role, content}`），
  // 助手那条才在 `data.message` 上（`core/items.dart:101` 与
  // `projection.dart:832` 两处同一条判据）。
  payloadJson: jsonEncode({
    'id': 'm$seq',
    'role': 'user',
    'content': [
      {'type': 'text', 'text': '第 $seq 条'},
    ],
  }),
  updatedAt: seq,
);

class _Client extends FakeSyncClient {
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
  }) async => <String, Object?>{} as T;
}

void main() {
  test('冷启动读回条目：界面立刻有内容，水位取**内容的上界**', () async {
    final client = _Client();
    // 故意给一条不连续的输入（5、9 —— 中间的没落盘）：水位必须是 9（内容上界），
    // 而不是某个计数器；调用方也不会因为"中间缺"就拒绝恢复。
    final app = AppModel(
      client: client,
      readLocalItems: (sid) async => [_stored(sid, 5), _stored(sid, 9)],
    );
    addTearDown(app.dispose);

    await app.openSession('s1');

    expect(app.items, hasLength(2), reason: '打开会话就有内容（不必等电脑侧回窗口）');
    expect(client.restoredSince['s1'], 9, reason: '水位取条目的 seq 上界');
  });

  test('本地一条都没有 ⇒ 不认水位（退回从零开始，与今天一致）', () async {
    final client = _Client();
    final app = AppModel(
      client: client,
      readLocalItems: (sid) async => const <StoredItem>[],
    );
    addTearDown(app.dispose);

    await app.openSession('s1');

    expect(app.items, isEmpty);
    expect(
      client.restoredSince.containsKey('s1'),
      isFalse,
      reason: '"声称我有到 N、界面却是空的"是唯一不可接受的方向',
    );
  });

  test('内存里已经有内容 ⇒ 不读盘（否则会把更新的内存态盖成旧的）', () async {
    final client = _Client();
    var reads = 0;
    final app = AppModel(
      client: client,
      readLocalItems: (sid) async {
        reads += 1;
        return [_stored(sid, 5)];
      },
    );
    addTearDown(app.dispose);

    await app.openSession('s1'); // 第一次：读盘一次
    await app.openSession('s1'); // 第二次（切回来）：不该再读
    expect(reads, 1);
    expect(app.items, hasLength(1));
  });

  test('outcome == snapshot：整份替换（不是 upsert）', () async {
    final client = _Client();
    final app = AppModel(
      client: client,
      readLocalItems: (sid) async => [_stored(sid, 5), _stored(sid, 9)],
    );
    addTearDown(app.dispose);
    await app.openSession('s1');
    expect(app.items, hasLength(2));

    // 电脑侧说：你手里那段与我对不上，这份才是我的（was 5、9 → now 40）。
    client
        .controllerOf('s1')
        .add(
          const SessionDelta(
            sid: 's1',
            events: [
              SessionEvent(
                // 身份由**解码边界**产出（`core/items.dart` 的 `itemIdOf`）：线上那一条
                // 会是 `m:m40`，所以夹具也写 `m:m40`。投影不再替你重推一遍 ——
                // 写错的值现在会被照用（这正是要的：同一条事件不许有两个 id）。
                itemId: 'm:m40',
                type: 'user/message',
                seq: 40,
                time: 40,
                data: {
                  'id': 'm40',
                  'role': 'user',
                  'content': [
                    {'type': 'text', 'text': '第 40 条'},
                  ],
                },
              ),
            ],
            transient: <String, Object?>{},
            outcome: RecoveryOutcome.snapshot,
          ),
        );
    await Future<void>.delayed(Duration.zero);

    expect(app.items, hasLength(1), reason: '整份替换：旧的 5 / 9 不留在界面上');
    expect(
      app.items.single.itemId,
      'm:m40',
      reason: 'itemId 规则是 `m:<messageId>`（§5.2）',
    );
  });
}
