/// P3：**流式尾部独立订阅**——流式期间页面级重建次数 = 0。
///
/// ## 判据（笔记 `2026-10-31-host-state-sync.md` 的 P3）
///
/// 用**计数桩**证，不靠肉眼：流式期间"会话页根那一层"的重建次数必须是 **0**，
/// 而尾条目自己跟得上（它的重建次数随每批增长）。
///
/// ## 为什么计数桩长这样
///
/// 会话页根是 `FrameCoalescedBuilder(listenable: app)`（`ui/chat_page.dart:716`），
/// 抽屉那一层同形（`main.dart:871`）——所以"根会不会重建"等价于"`AppModel` 会不会通知"。
/// 计数桩就用**同一个包装器**，它重建一次 = 真实的根重建一次。
/// 尾条目用 `ValueListenableBuilder(app.liveTail)`，与 `ui/chat_page.dart` 里
/// 那一格完全同形。
///
/// 这一组钉的是**通知路径**，不是像素：文本渲染的正确性另有
/// `live_text_turn_test.dart` / `message_rendering_test.dart`。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/live_message.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/ui/frame_coalesced.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

/// 能推 `live` 帧的替身（`SessionDelta.liveMessage`）。
///
/// **每条会话一条流**（与真客户端同形）：共一条流的话，切会话之后
/// 两个订阅会收到同一帧，把「旧会话的帧落在新会话上」这条真实形状测反。
class _LiveClient extends FakeSyncClient {
  final Map<String, StreamController<SessionDelta>> _streams =
      <String, StreamController<SessionDelta>>{};

  StreamController<SessionDelta> _streamOf(String sid) => _streams.putIfAbsent(
    sid,
    () => StreamController<SessionDelta>.broadcast(),
  );

  void emitLive(String sid, String text, {String reasoning = ''}) {
    _streamOf(sid).add(
      SessionDelta(
        sid: sid,
        events: const [],
        transient: const {},
        liveMessage: LiveMessage(reasoning: reasoning, text: text),
      ),
    );
  }

  @override
  conn.ConnectionState get state => conn.ConnectionState.serving;
  @override
  Stream<conn.ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();
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
  Stream<SessionDelta> sessionUpdates(String sid) => _streamOf(sid).stream;

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => <String, Object?>{} as T;
}

/// 计数桩：页面根（与 `chat_page.dart:716` 同一个包装器）。
class _CountedPage extends StatelessWidget {
  const _CountedPage({required this.app, required this.onBuild});

  final Listenable app;
  final void Function() onBuild;

  @override
  Widget build(BuildContext context) => FrameCoalescedBuilder(
    listenable: app,
    builder: (context, child) {
      onBuild();
      return const SizedBox.shrink();
    },
  );
}

/// 计数桩：尾条目（与 `ui/chat_page.dart` 里那一格同形）。
class _CountedTail extends StatelessWidget {
  const _CountedTail({required this.tail, required this.onBuild});

  final ValueListenable<LiveMessage?> tail;
  final void Function(LiveMessage? message) onBuild;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<LiveMessage?>(
    valueListenable: tail,
    builder: (context, message, child) {
      onBuild(message);
      return Text(message?.text ?? '', textDirection: TextDirection.ltr);
    },
  );
}

void main() {
  testWidgets('流式期间页面级重建 = 0，尾条目跟着每一批更新', (tester) async {
    final client = _LiveClient();
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.start();
    await app.openSession('s1');

    var pageBuilds = 0;
    var tailBuilds = 0;
    LiveMessage? tailMessage;
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: <Widget>[
            _CountedPage(app: app, onBuild: () => pageBuilds += 1),
            _CountedTail(
              tail: app.liveTail,
              onBuild: (message) {
                tailBuilds += 1;
                tailMessage = message;
              },
            ),
          ],
        ),
      ),
    );

    // **开流那一批**：尾条目从无到有 = 列表格数变了，页面通知一次是正确的
    // （它不是"流式期间"，而是"流开始"）。
    client.emitLive('s1', '第一');
    // `idle()` 先把流的微任务跑完再排帧：否则通知落在 build 之后，
    // 重建会被推到下一帧（交替掉帧，计数看起来"少了一半"）。
    await tester.idle();
    await tester.pump();
    expect(app.liveTail.value?.text, '第一');
    expect(tailMessage?.text, '第一');
    final pageAtStreamStart = pageBuilds;
    final tailAtStreamStart = tailBuilds;

    // **流式期间**：再来 5 批。文本一直变，格数不变。
    for (var i = 0; i < 5; i += 1) {
      client.emitLive('s1', '第${i + 2}');
      await tester.idle();
      await tester.pump();
    }

    expect(
      pageBuilds - pageAtStreamStart,
      0,
      reason: '流式期间页面根不该重建（实际 ${pageBuilds - pageAtStreamStart} 次）',
    );
    expect(
      tailBuilds - tailAtStreamStart,
      5,
      reason: '尾条目应当逐批更新（实际 ${tailBuilds - tailAtStreamStart} 次）',
    );
    expect(tailMessage?.text, '第6');
  });

  testWidgets('持久消息到达：尾条目消失 + 页面重建一次（那是形态变了）', (tester) async {
    final client = _LiveClient();
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.start();
    await app.openSession('s1');

    var pageBuilds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: _CountedPage(app: app, onBuild: () => pageBuilds += 1),
      ),
    );

    client.emitLive('s1', '正文');
    await tester.pump();
    expect(app.liveTail.value?.text, '正文');

    // 持久 `assistant/message` 到了：流式槽位让位（§2.2 以持久为准）。
    client.emitPersisted('s1');
    await tester.pump();

    expect(app.liveTail.value, isNull, reason: '持久形态到了，尾条目必须消失');
    expect(pageBuilds, greaterThan(1), reason: '格数变了要通知（这一次不是"流式期间"，是形态变化）');
  });

  test('纯流式 delta 不动条目表（流式文本不进 store）', () async {
    final client = _LiveClient();
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.start();
    await app.openSession('s1');

    client.emitLive('s1', '正文');
    await Future<void>.delayed(Duration.zero);
    expect(app.items, isEmpty);
    expect(app.liveTail.value?.text, '正文');
  });

  test('切到别的会话 ⇒ 流式尾必须清空（否则新会话页继续画上一个会话的正文）', () async {
    final client = _LiveClient();
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.start();
    await app.openSession('s1');

    client.emitLive('s1', '上一个会话正在生成的正文');
    await Future<void>.delayed(Duration.zero);
    expect(app.liveTail.value?.text, '上一个会话正在生成的正文');

    // 旧会话还在生成时点了「新建会话」（真机 2026-11-10，公网中转）：
    // 标题已经换成新会话，正文却还是旧会话的。
    // 成因：`_liveTail` 是 `AppModel` 上的**单例**，只在 `turn/end` /
    // 助手消息落盘时清（`_onDelta`），切会话时没清；
    // 而旧会话的订阅在切走之后仍然活着，流式内容还会继续往里灌。
    await app.openSession('s2');

    expect(
      app.liveTail.value,
      isNull,
      reason: '流式尾属于「那一个会话正在生成的内容」；换会话还留着，新页面就会画旧正文',
    );

    // 旧会话的订阅还活着（`openSession` 不退订）：它后续的 `live` 帧
    // **不许**把尾巴重新填上，否则新会话页又会长出旧会话的正文。
    client.emitLive('s1', '旧会话又推了一批');
    await Future<void>.delayed(Duration.zero);
    expect(app.liveTail.value, isNull, reason: '切走的会话不许再往新会话页写流式正文');
  });
}

extension on _LiveClient {
  /// 一条持久的 `assistant/message`（清空流式槽位的那条路）。
  void emitPersisted(String sid) {
    _streamOf(sid).add(
      SessionDelta(
        sid: sid,
        events: <SessionEvent>[
          const SessionEvent(
            itemId: 'm:1',
            type: 'assistant/message',
            seq: 1,
            time: 1,
            data: <String, Object?>{
              'messageId': '1',
              'content': <Object?>[
                <String, Object?>{'type': 'text', 'text': '正文'},
              ],
            },
          ),
        ],
        transient: const {},
      ),
    );
  }
}
