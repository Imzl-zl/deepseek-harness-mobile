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
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/ui/frame_coalesced.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

/// 能推 `live` 帧的替身（`SessionDelta.liveText`）。
class _LiveClient extends FakeSyncClient {
  final _sessions = StreamController<SessionDelta>.broadcast();

  void emitLive(String sid, String text) {
    _sessions.add(
      SessionDelta(
        sid: sid,
        events: const [],
        transient: const {},
        liveText: text,
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
  Stream<SessionDelta> sessionUpdates(String sid) => _sessions.stream;

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

  final ValueListenable<String?> tail;
  final void Function(String? text) onBuild;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
    valueListenable: tail,
    builder: (context, text, child) {
      onBuild(text);
      return Text(text ?? '', textDirection: TextDirection.ltr);
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
    String? tailText;
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: <Widget>[
            _CountedPage(app: app, onBuild: () => pageBuilds += 1),
            _CountedTail(
              tail: app.liveTail,
              onBuild: (text) {
                tailBuilds += 1;
                tailText = text;
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
    expect(app.liveText, '第一');
    expect(tailText, '第一');
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
    expect(tailText, '第6');
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
    expect(app.liveTail.value, '正文');

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
    expect(app.liveText, '正文');
  });
}

extension on _LiveClient {
  /// 一条持久的 `assistant/message`（清空流式槽位的那条路）。
  void emitPersisted(String sid) {
    _sessions.add(
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
