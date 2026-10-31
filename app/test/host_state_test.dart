/// 宿主状态同步的**机械保证**（契约 §5.9 / `app-channel-client.md` §2.3）。
///
/// ## 这一组守什么
///
/// P1 的根不是某一处 bug，而是"宿主状态有一批，却只有在四个时机才重取"——
/// 于是**每冒出一个新状态就又是一条同样的症状**，而没人会记得把它接上。
/// 所以这里的判据全是**结构性的**，不是行为样例：
///
/// 1. **key 清单两端一致**：Dart 的 [HostStateKey] 与连接器
///    `connector/src/protocol/host-state.ts` 的 `HOST_STATE_KEYS` 必须逐字相等
///    （两边各写一份就必然漂移，而漂移的表现是"某一类变更永远不推"）；
/// 2. **登记表没有漏配**：每个 key 都有一条登记，且**至少一个触发点**；
/// 3. **登记表的 `fetch` 真的调到那个方法**：用真 `AppModel` + 记账替身跑一遍，
///    断言线上方法名就是 key 本身（拷错一行的那类错误在这里会红）；
/// 4. **合并与丢弃**：同 key 在窗口内只发一次、不同 key 各发一次、断连清空待发桶。
library;

import 'dart:async';
import 'dart:io';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/host_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

/// 记账替身：`call` 的方法名落进 [called]，并按方法名给一个"空但合法"的应答。
///
/// 连接态与 `host` 帧各是一条可控流 —— 走的是产品同一条路（`AppModel.start()`
/// 订阅它们），不是给 `AppModel` 开后门。
class _RecordingClient extends FakeSyncClient {
  final List<String> called = <String>[];
  final StreamController<ConnectionState> connectionState =
      StreamController<ConnectionState>.broadcast();
  final StreamController<HostStateChanged> hostStates =
      StreamController<HostStateChanged>.broadcast();

  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => connectionState.stream;
  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();
  @override
  Stream<HostStateChanged> get hostStateChanges => hostStates.stream;
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
    called.add(method);
    final Object answer = switch (method) {
      'session.list' => <String, Object?>{'sessions': <Object?>[]},
      'settings.describe' => <String, Object?>{'sections': <Object?>[]},
      'session.projections' => <String, Object?>{},
      'job.list' => <String, Object?>{'jobs': <Object?>[]},
      // 其余目录面（模型 / 权限 / 工作区 / 预设 / 版本）不在本组判据里：
      // 返回空对象让它们各自走"读不到"的既有分支。
      _ => <String, Object?>{},
    };
    return answer as T;
  }
}

/// 从当前目录往上找到仓库根（含 `connector/src` 的那一层）。
///
/// **不硬编码盘符**：仓库从 `C:\sudy` 搬到 `D:\sudy` 时，11 个写死路径的脚本
/// 静默全红过（见 `tools.md` 的 Pitfalls）。判据与 `fixtures_test.dart` 同一套。
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i += 1) {
    if (Directory('${dir.path}/connector/src/protocol').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    '找不到仓库根（含 connector/src 的那一层），当前目录 ${Directory.current.path}',
  );
}

/// 把连接器那边的 key 清单读出来（**跨端的唯一来源检查**）。
///
/// 解析口径与 `connector/tests/frame-list-single-source.test.ts` 同一条思路：
/// 从源码里抽字符串字面量，而不是另抄一份清单。
List<String> _connectorKeys() {
  final source = File(
    '${_repoRoot().path}/connector/src/protocol/host-state.ts',
  ).readAsStringSync();
  final block = RegExp(
    r'export const HOST_STATE_KEYS = \[([\s\S]*?)\] as const',
  ).firstMatch(source);
  expect(block, isNotNull, reason: '没能在连接器里找到 HOST_STATE_KEYS —— 先检查解析口径');
  return RegExp(
    r"'([^']+)'",
  ).allMatches(block!.group(1)!).map((m) => m.group(1)!).toList();
}

/// 起一个装配好、已 `start()` 的 `AppModel` + 那个替身。
Future<(AppModel, _RecordingClient)> _running({
  Duration window = const Duration(milliseconds: 40),
}) async {
  final client = _RecordingClient();
  final app = AppModel(client: client, hostStateMergeWindow: window);
  await app.start();
  return (app, client);
}

void main() {
  group('key 清单两端一致', () {
    test('Dart 的 HostStateKey.all 与连接器的 HOST_STATE_KEYS 逐字相等', () {
      expect(HostStateKey.all, _connectorKeys());
    });

    test('会话级 / 宿主级的划分与连接器的判据一致', () {
      // 会话级 = 那个方法要一个会话参数。两端必须落在同一批 key 上，
      // 否则一边认为"可以不带 sid"，另一边就永远重取不到。
      expect(
        HostStateKey.all.where(HostStateKey.isSessionScoped).toList(),
        <String>[HostStateKey.sessionProjections, HostStateKey.jobList],
      );
    });
  });

  group('登记表', () {
    test('每个 key 都有一条登记', () {
      for (final key in HostStateKey.all) {
        expect(hostStateFetchOf(key), isNotNull, reason: '$key 没有登记');
      }
    });

    test('每个 key 至少有一个触发点（新增状态漏配就红）', () {
      for (final fetch in hostStateRegistry) {
        expect(
          fetch.triggers,
          isNotEmpty,
          reason: '${fetch.key} 一个触发点都没有 —— 它永远不会自己刷新',
        );
      }
    });

    test('每条登记都要能收到通知（这条通道存在的唯一理由）', () {
      // `notification` 缺了，这个 key 就只在"连上 / 开会话"时才刷新，
      // 而 P1 要消灭的正是"桌面改了、手机没动静"。
      for (final fetch in hostStateRegistry) {
        expect(
          fetch.triggers,
          contains(HostStateTrigger.notification),
          reason: '${fetch.key} 不响应通知',
        );
      }
    });

    test('登记表里没有多余的 key（清单外的拼写永远匹配不上）', () {
      for (final fetch in hostStateRegistry) {
        expect(
          HostStateKey.all,
          contains(fetch.key),
          reason: '${fetch.key} 不在封闭清单里（拼错了？）',
        );
      }
      expect(
        hostStateRegistry.map((f) => f.key).toSet().length,
        hostStateRegistry.length,
        reason: '同一个 key 登记了两次',
      );
    });

    test('登记表的 fetch 真的调到 key 指向的那个方法', () async {
      // 用**真** `AppModel` 跑：fetch → AppModel.refreshX → 线上方法名。
      // 把 `_refetchJobs` 拷给 `session.list` 这类错误在这里会红。
      for (final fetch in hostStateRegistry) {
        final client = _RecordingClient();
        final app = AppModel(client: client);
        addTearDown(app.dispose);
        await fetch.fetch(app, 'sid_A');
        expect(
          client.called,
          contains(fetch.key),
          reason:
              '${fetch.key} 的重取函数没有发出 ${fetch.key} 请求'
              '（实际发了 ${client.called}）',
        );
      }
    });
  });

  group('合并与丢弃', () {
    test('同 key 在窗口内合并成一次', () async {
      final (app, client) = await _running();
      addTearDown(app.dispose);

      // 三条通知连着来（同一个 key）：只该发一次。
      for (var i = 0; i < 3; i += 1) {
        client.hostStates.add(
          const HostStateChanged(keys: <String>[HostStateKey.sessionList]),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(
        client.called.where((m) => m == HostStateKey.sessionList).length,
        1,
        reason: '同 key 应当合并成一次（实际 ${client.called}）',
      );
    });

    test('不同 key 各发一次（不互相等）', () async {
      final (app, client) = await _running();
      addTearDown(app.dispose);

      // 真实的那一对：切模型会同时改清单行与投影包（契约 §5.9 的触发点表）。
      client.hostStates.add(
        const HostStateChanged(
          keys: <String>[
            HostStateKey.sessionList,
            HostStateKey.sessionProjections,
          ],
          sid: 'sid_A',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(
        client.called.where((m) => m == HostStateKey.sessionList).length,
        1,
      );
      expect(
        client.called.where((m) => m == HostStateKey.sessionProjections).length,
        1,
      );
    });

    test('设置面单独来一条通知：只拉一次（不牵动会话清单）', () async {
      // **不与 `session.list` 同批**：`refreshSessions()` 末尾本来就会拉一次设置面，
      // 两条捆在一起就是两次 `settings.describe`。连接器的触发点表里它们也确实从不同批
      // （`settings.update` 只发 `settings.describe`）。
      final (app, client) = await _running();
      addTearDown(app.dispose);

      client.hostStates.add(
        const HostStateChanged(keys: <String>[HostStateKey.settingsDescribe]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(
        client.called.where((m) => m == HostStateKey.settingsDescribe).length,
        1,
      );
      expect(
        client.called.where((m) => m == HostStateKey.sessionList),
        isEmpty,
        reason: '改设置不该牵动整份会话清单',
      );
    });

    test('窗口没到就不发（100–300ms 的判据）', () async {
      final (app, client) = await _running(
        window: const Duration(milliseconds: 200),
      );
      addTearDown(app.dispose);

      client.hostStates.add(
        const HostStateChanged(keys: <String>[HostStateKey.sessionList]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(client.called, isEmpty, reason: '还在合并窗口里就发了请求');
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(client.called, contains(HostStateKey.sessionList));
    });

    test('断连清空待发桶（重连由落点兜底，不排队）', () async {
      final (app, client) = await _running();
      addTearDown(app.dispose);

      client.hostStates.add(
        const HostStateChanged(keys: <String>[HostStateKey.sessionList]),
      );
      // 还没到窗口就断了（`connecting` = 不在服务态）。
      client.connectionState.add(ConnectionState.connecting);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(
        client.called.where((m) => m == HostStateKey.sessionList),
        isEmpty,
        reason: '断连后不该还有排队中的快照请求',
      );
    });

    test('登记表不认识的 key：忽略并计数（不是静默）', () async {
      final (app, client) = await _running();
      addTearDown(app.dispose);

      client.hostStates.add(
        const HostStateChanged(keys: <String>['future.snapshot']),
      );
      await Future<void>.delayed(Duration.zero);
      expect(app.unknownHostStateKeys, 1);
      expect(app.lastError, isNull, reason: '未知 key 不是失败，只是不认识');
    });

    test('会话级 key 少了 sid：不发请求，也不算未知', () async {
      final (app, client) = await _running();
      addTearDown(app.dispose);

      client.hostStates.add(
        const HostStateChanged(keys: <String>[HostStateKey.sessionProjections]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(client.called, isEmpty);
      expect(app.unknownHostStateKeys, 0, reason: '这是连接器少带了路由字段，不是我们不认识');
    });

    test('会话级 key 带 sid：按那个 sid 重取', () async {
      final (app, client) = await _running();
      addTearDown(app.dispose);

      client.hostStates.add(
        const HostStateChanged(
          keys: <String>[HostStateKey.sessionProjections],
          sid: 'sid_A',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(client.called, contains(HostStateKey.sessionProjections));
    });
  });
}
