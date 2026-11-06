/// 前后台态上报者的用例（`lib/platform/app_state_reporter.dart`）与**每台各报各的**
/// 那条判据（`AppModel.reportToClient`）。
///
/// ## 为什么前者必须是 widget 测试
///
/// 生命周期事件只从 `WidgetsBinding` 来，而 `tester.binding.handleAppLifecycleStateChanged`
/// 正是驱动它的缝 —— 纯单测里没有绑定，`didChangeAppLifecycleState` 永远不会被调到，
/// 于是"映射写错了"这类问题在单测里看不出来。绑定对观察者是**无条件派发**的
/// （`flutter/packages/flutter/lib/src/widgets/binding.dart:1102-1104`：遍历
/// `_observers` 逐个调，不比较态是否变化），所以这里可以把五个态逐个喂进去。
///
/// ## 为什么还要一条"每台各报各的"
///
/// 池化之后一台手机同时连着几台电脑（`docs/subsystems/app-channel-client.md` §6.4），
/// 观察者只有一个、扇出在装配层，而**每一台报给连接层的值可以不同**：
/// 保活生效时后台也报 `foreground`（`AppModel.connectionForeground`），
/// 而"保活生效"取决于那台自己的连接态。所以这里钉住"同一个态、两台得到不同的值"。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/app_services.dart';
import 'package:dsh_mobile/platform/app_state_reporter.dart';
import 'package:dsh_mobile/platform/notify_memory.dart';
// **`hide ConnectionState`**：`widgets.dart` 也导出 `ConnectionState`
// （`AsyncSnapshot` 的 none/waiting/active/done），与我们的**连接状态机**同名
// 但毫无关系。隐藏它，让本文件里 `ConnectionState` 只有一个意思
// （同 `widget_test.dart` 的处理）。
import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 记账用的假客户端：只记 [SyncClient.setAppState] 被调过什么。
///
/// 其余成员一律 `UnimplementedError`：这些用例里它们**不该被调到**，真被调到了
/// 要立刻红，而不是安静地返回一个空实现把问题掩盖过去。
class _RecordingClient extends FakeSyncClient {
  _RecordingClient({this.current = ConnectionState.idle});

  /// 这台此刻的连接态（`connectionForeground` 的判据之一）。
  final ConnectionState current;

  final List<AppState> states = <AppState>[];

  @override
  ConnectionState get state => current;

  @override
  Future<void> setAppState(AppState state) async {
    states.add(state);
  }

  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();
}

/// 让 `_syncKeepAlive` 的 `await` 链跑完。
Future<void> pump() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('生命周期态 → 前台/后台', () {
    testWidgets('五个态逐个喂进去：只有 resumed 算前台', (tester) async {
      final seen = <bool>[];
      final reporter = AppStateReporter(seen.add);
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

      expect(seen, <bool>[true, false, false, false, false, true]);
    });

    testWidgets('摘掉 observer 之后不再派发', (tester) async {
      final seen = <bool>[];
      final reporter = AppStateReporter(seen.add);
      WidgetsBinding.instance.addObserver(reporter);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      WidgetsBinding.instance.removeObserver(reporter);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(seen, <bool>[false], reason: 'dispose 摘掉之后不能再往已死的客户端上写');
    });
  });

  group('每台各报各的（扇出在装配层，判据在各台）', () {
    test('同一个"退到后台"：在服务态那台报 foreground，掉线那台报 background', () async {
      final port = MemoryNotify(); // granted = true
      final services = AppServices(notify: port);
      final serving = _RecordingClient(current: ConnectionState.serving);
      final idle = _RecordingClient();
      final a = AppModel(
        client: serving,
        services: services,
        hostIdOf: () => 'hostA',
      );
      final b = AppModel(
        client: idle,
        services: services,
        hostIdOf: () => 'hostB',
      );
      addTearDown(() {
        a.dispose();
        b.dispose();
      });

      // 装配层的扇出就是这个形状：同一个态交给每一台。
      a.setAppForeground(false);
      b.setAppForeground(false);
      await pump();
      expect(port.keepAliveCount, 1, reason: '只要还有一台在要，服务就留着');

      a.reportToClient(false);
      b.reportToClient(false);
      expect(serving.states, <AppState>[
        AppState.foreground,
      ], reason: '保活生效的那台，后台也照报 foreground（连接要活着，通知上就能答）');
      expect(idle.states, <AppState>[
        AppState.background,
      ], reason: '没保活的那台照旧断开 —— 不能因为别的台在保活就连着');
      expect(port.keepAliveCount, 1, reason: '掉线那台报"不要"不该把另一台的保活撤掉');
    });
  });
}
