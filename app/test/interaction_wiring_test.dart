/// **跨层**：会话事件 → 交互信号 → `interaction.respond` 这条链（契约 §6）。
///
/// 为什么需要这一组：待处理项是**会话事件的投影**，于是"手机上有没有那张卡"
/// 与"答出去长什么样"分别由投影层与答复层决定，中间还隔着一个 `AppModel`。
/// 三层各自自洽不等于接得上 —— 而接不上的症状是"电脑上明明在等审批，手机上什么都没有"。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/interaction.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

class _FakeClient extends FakeSyncClient {
  /// 每会话一条更新流：测试往里面推，走的正是 `AppModel` 订阅的那条真路
  /// （不给自己加测试专用入口 —— 那会验不到"真的接上了"）。
  final Map<String, StreamController<SessionDelta>> _updates = {};

  final List<String> called = [];

  /// `session.list` 的返回值（测试给；不给就回空）。
  Object? onList;

  /// 最后一次调用的参数（钉**载荷形状**）。
  Map<String, Object?>? lastParams;

  /// 最后一次调用的幂等键。
  String? lastRequestId;

  StreamController<SessionDelta> updatesOf(String sid) => _updates.putIfAbsent(
    sid,
    () => StreamController<SessionDelta>.broadcast(),
  );

  @override
  ConnectionState get state => ConnectionState.serving;

  @override
  Stream<ConnectionState> get connection => const Stream.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> reconnect() => start();

  @override
  Future<void> setAppState(AppState state) async {}

  @override
  Future<void> close() async {}

  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();

  @override
  Future<void> unsubscribe(String sid) async {}

  @override
  Stream<SessionDelta> sessionUpdates(String sid) => updatesOf(sid).stream;

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    called.add(method);
    lastParams = params;
    lastRequestId = requestId;
    if (method == 'session.list') return onList as T;
    return null as T;
  }
}

/// 推一条事件进 `AppModel` 订阅的那条流，并等它投影出交互信号。
Future<InteractionSignal> _emit(
  AppModel app,
  _FakeClient client,
  String sid, {
  required String type,
  required int seq,
  required Object? data,
}) {
  final first = Completer<InteractionSignal>();
  late final StreamSubscription<InteractionSignal> sub;
  sub = app.interactions.listen((signal) {
    if (!first.isCompleted) {
      first.complete(signal);
      unawaited(sub.cancel());
    }
  });
  client
      .updatesOf(sid)
      .add(
        SessionDelta(
          sid: sid,
          events: [
            SessionEvent(
              itemId: 'x',
              type: type,
              seq: seq,
              time: seq,
              data: data,
            ),
          ],
          transient: const <String, Object?>{},
        ),
      );
  return first.future;
}

void main() {
  test('approval/asked → 开一个带 sid 的待处理项', () async {
    final client = _FakeClient();
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.openSession('sid-1');

    final signal = await _emit(
      app,
      client,
      'sid-1',
      type: 'approval/asked',
      seq: 3,
      data: const {
        'id': 'ap-1',
        'toolName': 'bash',
        'callId': 'call-1',
        'reason': '要删文件',
      },
    );
    expect(signal, isA<InteractionOpened>());
    final item = (signal as InteractionOpened).item;
    // **sid 由 AppModel 补**（投影层不认识会话别名）—— 答复要带回它。
    expect(item.sid, 'sid-1');
    expect(item.callId, 'call-1');
    expect(item.title, '要删文件');
  });

  test('答复的载荷逐字段符合契约 §5.7，幂等键是 i:<callId>', () async {
    final client = _FakeClient();
    final app = AppModel(client: client);
    addTearDown(app.dispose);

    await app.respondInteraction(
      const InteractionAnswer(
        sid: 'sid-1',
        itemId: 'i:ap-1',
        callId: 'call-1',
        answers: [
          InteractionAnswerItem(id: 'call-1', selected: ['allowed-once']),
        ],
      ),
    );

    expect(client.called, ['interaction.respond']);
    expect(client.lastRequestId, 'i:call-1');
    expect(client.lastParams, {
      'sid': 'sid-1',
      'callId': 'call-1',
      'answers': [
        {
          'id': 'call-1',
          'selected': ['allowed-once'],
        },
      ],
    });
  });

  test('没有 custom 时不写这个字段（空字符串会被 DSH 读成一个自定义答案）', () async {
    final client = _FakeClient();
    final app = AppModel(client: client);
    addTearDown(app.dispose);

    await app.respondInteraction(
      const InteractionAnswer(
        sid: 'sid-1',
        itemId: 't:call-q',
        callId: 'call-q',
        answers: [InteractionAnswerItem(id: 'q1', selected: [])],
      ),
    );

    final answers = client.lastParams!['answers'] as List;
    expect(answers.single, {'id': 'q1', 'selected': <String>[]});
  });

  test('会话行的待处理数从本地投影算（多会话时靠它知道切去哪）', () async {
    // 2026-10-13：待处理改成 per-session（对齐 DSH），于是"别的会话还有几个
    // 在等"必须能在列表里看见 —— 否则用户没有理由知道要切。
    // 这个数**本地算**（不指望 session.list 带），判据就是推一条
    // approval/asked 进去、拉一次列表，看那一行的 pendingCount。
    final client = _FakeClient();
    final app = AppModel(client: client);
    addTearDown(app.dispose);

    // session.list 先给出两行。
    client.onList = const {
      'sessions': [
        {'sid': 'sid-A', 'updatedAt': 2, 'running': false, 'blank': true},
        {'sid': 'sid-B', 'updatedAt': 1, 'running': false, 'blank': true},
      ],
    };
    await app.refreshSessions();
    expect(app.sessions.map((s) => s.pendingCount), [
      0,
      0,
    ], reason: '还没有任何事件时两个会话都是 0');

    // 只往 sid-B 推一条审批。
    await app.openSession('sid-B');
    await _emit(
      app,
      client,
      'sid-B',
      type: 'approval/asked',
      seq: 5,
      data: const {
        'id': 'ap-9',
        'toolName': 'bash',
        'callId': 'call-9',
        'reason': '要删文件',
      },
    );
    await app.refreshSessions();
    final byId = {for (final s in app.sessions) s.sid: s};
    expect(byId['sid-B']!.pendingCount, 1, reason: 'B 有一个未决审批');
    expect(byId['sid-A']!.pendingCount, 0, reason: 'A 不该被 B 的事件影响');
  });
}
