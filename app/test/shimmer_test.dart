/// 运行中动效：扫光（`DshShimmer`）与流末尾运行条（`RunningBar`）。
///
/// 守四件事：
///
/// 1. **静止的行不许闪**：`active: false` 时连叠层都不建。
/// 2. **全 App 只有一个 ticker**：N 条在跑的行 = 1 个瞬时回调
///    （`packages/flutter/lib/src/scheduler/binding.dart:574` 的 `transientCallbackCount`）；
///    一行都不跑时**归零**（不留空转的定时器）。
/// 3. `MediaQuery.disableAnimations`（= `prefers-reduced-motion`）时整层不画。
/// 4. 运行条的秒数**从电脑侧给的起点算**、每秒走一格；没有起点就只说「深度求索中」。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/ui/chat_turns.dart';
import 'package:dsh_mobile/ui/dsh_shimmer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 能推**持久事件**的替身（运行条要 `turn/start` / `turn/end`）。
class _EventClient extends FakeSyncClient {
  final _sessions = StreamController<SessionDelta>.broadcast();

  void emit(String sid, List<SessionEvent> events) {
    _sessions.add(SessionDelta(sid: sid, events: events, transient: const {}));
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

SessionEvent _ev(String type, int seq, int time) => SessionEvent(
  itemId: '$type-$seq',
  type: type,
  seq: seq,
  time: time,
  data: const <String, Object?>{},
);

Widget host(Widget child, {bool disableAnimations = false}) => MaterialApp(
  theme: DshTheme.dark(),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(
      body: Center(child: DshShimmerHost(child: child)),
    ),
  ),
);

void main() {
  testWidgets('静止的行：不建叠层，也不占 ticker', (tester) async {
    await tester.pumpWidget(
      host(const DshShimmer(active: false, child: Text('bash'))),
    );
    expect(find.byKey(shimmerMaskKey), findsNothing);
    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: '没人跑就不该有空转的 ticker',
    );
  });

  testWidgets('三条在跑的行只挂一个 ticker（全 App 共用一个控制器）', (tester) async {
    await tester.pumpWidget(
      host(
        Column(
          children: [
            for (var i = 0; i < 3; i += 1)
              DshShimmer(active: true, child: Text('tool-$i')),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(shimmerMaskKey), findsNWidgets(3));
    expect(
      tester.binding.transientCallbackCount,
      1,
      reason: '每行各建一个控制器会在这儿变成 3 —— 那正是 dsh_state_dot 踩过的坑',
    );

    // 全部跑完：控制器必须停（长会话里不空转烧电）。
    await tester.pumpWidget(
      host(
        Column(
          children: [
            for (var i = 0; i < 3; i += 1)
              DshShimmer(active: false, child: Text('tool-$i')),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(shimmerMaskKey), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('disableAnimations（prefers-reduced-motion）时整层不画', (tester) async {
    await tester.pumpWidget(
      host(
        const DshShimmer(active: true, child: Text('bash')),
        disableAnimations: true,
      ),
    );
    expect(find.byKey(shimmerMaskKey), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('工具行：running 才扫光，完成/失败都不闪', (tester) async {
    Future<void> pumpWith(ToolCallStatus status) => tester.pumpWidget(
      host(ToolCard(name: 'bash', status: status, argument: 'ls')),
    );

    await pumpWith(ToolCallStatus.running);
    await tester.pump();
    expect(find.byKey(shimmerMaskKey), findsOneWidget);

    await pumpWith(ToolCallStatus.completed);
    await tester.pump();
    expect(find.byKey(shimmerMaskKey), findsNothing, reason: '跑完的行不许继续闪');

    await pumpWith(ToolCallStatus.failed);
    await tester.pump();
    expect(find.byKey(shimmerMaskKey), findsNothing);
  });

  testWidgets('运行条：秒数从电脑侧起点算，每秒走一格', (tester) async {
    final base = DateTime(2026, 10, 22, 12).millisecondsSinceEpoch;
    runningBarClock = () => base + 12000;
    addTearDown(
      () => runningBarClock = () => DateTime.now().millisecondsSinceEpoch,
    );

    await tester.pumpWidget(host(RunningBar(startTime: base)));
    await tester.pump();
    // **两份**：真实文字 + 扫光叠层里那份装饰副本（DSH 也是两份，`aria-hidden`）。
    expect(find.textContaining('深度求索中，用时 12 秒'), findsNWidgets(2));
    // 文案本身也在扫光（DSH 给运行条的 label 套的就是 TextShimmer active）。
    expect(find.byKey(shimmerMaskKey), findsOneWidget);

    runningBarClock = () => base + 15000;
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('用时 15 秒'), findsNWidgets(2));

    // 收掉：1 秒定时器不能留给下一个用例。
    await tester.pumpWidget(host(const SizedBox()));
  });

  testWidgets('运行条：没有起点就只说「深度求索中」，不编秒数', (tester) async {
    await tester.pumpWidget(host(const RunningBar()));
    await tester.pump();
    expect(find.textContaining('深度求索中'), findsNWidgets(2));
    expect(find.textContaining('用时'), findsNothing);

    await tester.pumpWidget(host(const SizedBox()));
  });

  // ---- 运行条的**数据源**：为什么不能用 `session.list` 的 running ----
  //
  // 真机实测（2026-10-22）：一轮跑了 40 秒，运行条**整轮没出现** —— 那张表只在
  // 连上/收口时重读，轮次进行中它是旧值。所以判据改成事件流
  // （`turn/start` 起、`turn/end` 收，起点就是事件里的 `time`）。
  test('runningOf / turnStartedAtOf：turn/start 起、turn/end 收', () async {
    final client = _EventClient();
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.start();
    await app.openSession('s1');

    expect(app.runningOf('s1'), isFalse, reason: '还没起轮次');
    expect(app.turnStartedAtOf('s1'), isNull);

    client.emit('s1', [_ev('turn/start', 1, 1700000000000)]);
    await Future<void>.delayed(Duration.zero);
    expect(app.runningOf('s1'), isTrue);
    expect(app.turnStartedAtOf('s1'), 1700000000000, reason: '起点来自事件的 time');

    client.emit('s1', [_ev('turn/end', 2, 1700000040000)]);
    await Future<void>.delayed(Duration.zero);
    expect(app.runningOf('s1'), isFalse);
    expect(app.turnStartedAtOf('s1'), isNull);
  });
}
