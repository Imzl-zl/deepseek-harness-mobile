/// 前后台态上报者的用例（`lib/platform/app_state_reporter.dart`）。
///
/// ## 为什么必须是 widget 测试
///
/// 生命周期事件只从 `WidgetsBinding` 来，而 `tester.binding.handleAppLifecycleStateChanged`
/// 正是驱动它的缝 —— 纯单测里没有绑定，`didChangeAppLifecycleState` 永远不会被调到，
/// 于是"映射写错了"这类问题在单测里看不出来。绑定对观察者是**无条件派发**的
/// （`flutter/packages/flutter/lib/src/widgets/binding.dart` 的
/// `handleAppLifecycleStateChanged`：遍历 `_observers` 逐个调，不比较态是否变化），
/// 所以这里可以把五个态逐个喂进去。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/platform/app_state_reporter.dart';
// **`hide ConnectionState`**：`widgets.dart` 也导出 `ConnectionState`
// （`AsyncSnapshot` 的 none/waiting/active/done），与我们的**连接状态机**同名
// 但毫无关系。隐藏它，让本文件里 `ConnectionState` 只有一个意思
// （同 `widget_test.dart` 的处理）。
import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

/// 记账用的假客户端：只记 [SyncClient.setAppState] 被调过几次、各是什么。
///
/// 其余成员一律 `UnimplementedError`：这个用例里它们**不该被调到**，
/// 真被调到了要立刻红，而不是安静地返回一个空实现把问题掩盖过去。
class _RecordingClient implements SyncClient {
  final List<AppState> states = <AppState>[];

  @override
  Future<void> setAppState(AppState state) async {
    states.add(state);
  }

  @override
  Future<void> start() async => throw UnimplementedError('本用例只该调 setAppState');

  @override
  ConnectionState get state => throw UnimplementedError('本用例只该调 setAppState');

  @override
  Stream<ConnectionState> get connection =>
      throw UnimplementedError('本用例只该调 setAppState');

  @override
  Stream<SessionDelta> sessionUpdates(String sid) =>
      throw UnimplementedError('本用例只该调 setAppState');

  @override
  Future<void> subscribe(String sid, {required int since}) async =>
      throw UnimplementedError('本用例只该调 setAppState');

  @override
  Future<void> unsubscribe(String sid) async =>
      throw UnimplementedError('本用例只该调 setAppState');

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => throw UnimplementedError('本用例只该调 setAppState');

  @override
  Future<void> close() async => throw UnimplementedError('本用例只该调 setAppState');

  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();
}

void main() {
  group('生命周期态 → 协议的 AppState', () {
    testWidgets('五个态逐个喂进去：只有 resumed 算前台', (tester) async {
      final client = _RecordingClient();
      final reporter = AppStateReporter(() => client);
      WidgetsBinding.instance.addObserver(reporter);
      addTearDown(() => WidgetsBinding.instance.removeObserver(reporter));

      // 顺序刻意乱序：resumed → inactive → paused → hidden → detached → resumed。
      // 只有 resumed 是前台，其余一律后台（fail-closed，理由见映射处的文档注释）。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(client.states, <AppState>[
        AppState.foreground,
        AppState.background,
        AppState.background,
        AppState.background,
        AppState.background,
        AppState.foreground,
      ]);
    });

    testWidgets('摘掉 observer 之后不再上报', (tester) async {
      final client = _RecordingClient();
      final reporter = AppStateReporter(() => client);
      WidgetsBinding.instance.addObserver(reporter);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      WidgetsBinding.instance.removeObserver(reporter);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(client.states, <AppState>[
        AppState.background,
      ], reason: 'dispose 摘掉之后不能再往一个已经 close 的客户端上写');
    });
  });

  group('客户端是现取的，不是持着的', () {
    testWidgets('启动过程里没有客户端：跳过，不抛', (tester) async {
      // 装配点的 `_app` 在 `_boot` 完成前是 null。客户端自己的初相就是
      // foreground，而移动端冷启动必然在前台，所以跳过与"报 foreground"等价。
      final reporter = AppStateReporter(() => null);
      WidgetsBinding.instance.addObserver(reporter);
      addTearDown(() => WidgetsBinding.instance.removeObserver(reporter));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('客户端被换掉之后，报的是新的那个', (tester) async {
      // 重新配对 / 清凭据都会重建 AppModel。持着一个客户端不放的写法，
      // 会在换掉之后继续往旧的（已 close 的）上报 —— 无声的空转。
      final first = _RecordingClient();
      final second = _RecordingClient();
      SyncClient? current = first;
      final reporter = AppStateReporter(() => current);
      WidgetsBinding.instance.addObserver(reporter);
      addTearDown(() => WidgetsBinding.instance.removeObserver(reporter));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      current = second;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(first.states, <AppState>[AppState.background]);
      expect(second.states, <AppState>[AppState.foreground]);
    });
  });
}
