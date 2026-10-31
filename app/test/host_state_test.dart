/// 宿主状态同步的**机械保证**（契约 §5.9 / `app-channel-client.md` §2.3）。
///
/// ## 这一组守什么
///
/// P1 的根不是某一处 bug，而是"宿主状态有一批，却只有在几个时机才重取"——
/// 于是**每冒出一个新状态就又是一条同样的症状**，而没人会记得把它接上。
/// 所以这里的判据全是**结构性的**，不是行为样例：
///
/// 1. **key 清单两端一致**：Dart 的 [HostStateKey] 与连接器
///    `connector/src/protocol/host-state.ts` 的 `HOST_STATE_KEYS` 必须逐字相等
///    （两边各写一份就必然漂移，而漂移的表现是"某一类变更永远不推"）；
/// 2. **登记表没有漏配**：每个 key 都有一条登记，且**至少一个触发点**；
///    `notification` 可用的 key 恰好是显式列出的六个（口径见下）；
/// 3. **登记表的 `fetch` 真的调到那个方法**：用真 `AppModel` + 记账替身跑一遍，
///    断言线上方法名就是 key 本身（拷错一行的那类错误在这里会红）；
/// 4. **合并与丢弃**：同 key 在窗口内只发一次、不同 key 各发一次、断连清空待发桶；
/// 5. **一条通知只花它那一个往返**、**首屏九项并行发起**、**目录失败不拦落点**、
///    **一批只通知一次**、**自己的写立即执行**（`connectLanding` / `ownWrite` 两列）。
///
/// ## 为什么"每条登记都要能收到通知"这条旧口径不成立
///
/// 上一版是"一条通知 = 一次 `refreshSessions()`"，那个函数把行 + 六个目录捆在一起，
/// 所以"每个 key 都响应通知"等于"每个 key 都能被顺带刷新"。捆拆掉之后，
/// `agentPresets.list` / `workspace.list` / `repo.info` **没有宿主事件**
/// （见 `remote-channel.md` §5.9 规则 6 的三条判据），把它们接上通知就只能靠编一个
/// 触发源 —— 那是替宿主做决定。所以口径改成两条：`notification` 的集合**恰好**
/// 等于有生产者的那六个；其余三个必须有 `connectLanding`（重连兜底）。
library;

import 'dart:async';
import 'dart:io';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/host_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

/// 记账替身：`call` 的方法名落进 [called]（发起顺序），应答后进 [finished]。
///
/// 连接态与 `host` 帧各是一条可控流 —— 走的是产品同一条路（`AppModel.start()`
/// 订阅它们），不是给 `AppModel` 开后门。
class _RecordingClient extends FakeSyncClient {
  _RecordingClient({
    this.rows = const <Map<String, Object?>>[],
    this.failFor = const <String>{},
  });

  /// `session.list` 回的会话行（落点用例要它）。
  final List<Map<String, Object?>> rows;

  /// 这些方法**抛错**（模拟"目录挂了"）。
  final Set<String> failFor;

  /// 装上去之后所有应答都压在这里 —— 用来断言"第一个请求返回前其余八个已发出"。
  Completer<void>? gate;

  /// 已发起（发起顺序）。
  final List<String> called = <String>[];

  /// 已应答（应答顺序）。
  final List<String> finished = <String>[];

  void reset() {
    called.clear();
    finished.clear();
  }

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
    if (failFor.contains(method)) {
      throw const ProtocolException(ErrorCode.internal, '目录挂了（用例）');
    }
    await gate?.future;
    final Object answer = switch (method) {
      'session.list' => <String, Object?>{'sessions': rows},
      'settings.describe' => <String, Object?>{'sections': <Object?>[]},
      'session.projections' => <String, Object?>{'values': <String, Object?>{}},
      'job.list' => <String, Object?>{'jobs': <Object?>[]},
      'session.modelCatalog' => <String, Object?>{'available': false},
      'permission.catalog' => <String, Object?>{
        'available': true,
        'catalog': <String, Object?>{
          'options': <Object?>[
            <String, Object?>{'value': 'read-only', 'name': 'read-only'},
          ],
          'defaultOptions': <Object?>[],
        },
      },
      'agentPresets.list' => <String, Object?>{'presets': <Object?>[]},
      'workspace.list' => <String, Object?>{
        'workspaces': <Object?>[],
        'archivedSessionIds': <Object?>[],
        'pinnedSessionIds': <Object?>[],
      },
      // `repo.info`：空对象是"读不出来"的既有分支（它会留一声并通知）。
      _ => <String, Object?>{},
    };
    finished.add(method);
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
  List<Map<String, Object?>> rows = const <Map<String, Object?>>[],
  Set<String> failFor = const <String>{},
}) async {
  final client = _RecordingClient(rows: rows, failFor: failFor);
  final app = AppModel(client: client, hostStateMergeWindow: window);
  await app.start();
  return (app, client);
}

/// 让已经排队的微任务 / 零延时 future 跑完（纯 `test()` 里没有 `pump`）。
Future<void> _settle() async {
  for (var i = 0; i < 4; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 有生产者的六个 key（契约 §5.9 的触发点表）—— **口径变了就在这六项里改**。
const Set<String> _notifiable = <String>{
  HostStateKey.sessionList,
  HostStateKey.sessionProjections,
  HostStateKey.settingsDescribe,
  HostStateKey.jobList,
  HostStateKey.sessionModelCatalog,
  HostStateKey.permissionCatalog,
};

/// 一个"在跑的会话"的线上行形状（落点用例要它）。
Map<String, Object?> _row(String sid, {required int updatedAt}) => {
  'sid': sid,
  'updatedAt': updatedAt,
  'running': false,
  'blank': false,
  'subagent': false,
};

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

    test('notification 可用的 key 恰好是那六个（有生产者的那六个）', () {
      // 旧口径是"每条登记都要能收到通知"，它成立的前提是"一条通知 = 一次
      // `refreshSessions()`"那个捆。捆拆掉之后，三个没有宿主事件的目录
      // （预设 / 工作区 / `repo.info`）若也响应通知，就只能靠编一个触发源。
      expect(
        hostStateRegistry
            .where((f) => f.triggers.contains(HostStateTrigger.notification))
            .map((f) => f.key)
            .toSet(),
        _notifiable,
      );
      // 剩下的三个只能靠"连上重取"（它们的变化没有事件可听）。
      for (final fetch in hostStateRegistry.where(
        (f) => !_notifiable.contains(f.key),
      )) {
        expect(
          fetch.triggers,
          contains(HostStateTrigger.connectLanding),
          reason: '${fetch.key} 既不响应通知，也不在连上重取 —— 它永远不会变',
        );
      }
    });

    test('connectLanding 覆盖全部九项（重连是漏收的唯一兜底）', () {
      expect(
        hostStateRegistry
            .where((f) => f.triggers.contains(HostStateTrigger.connectLanding))
            .map((f) => f.key)
            .toSet(),
        HostStateKey.all.toSet(),
      );
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
          client.finished,
          contains(fetch.key),
          reason:
              '${fetch.key} 的重取函数没有发出 ${fetch.key} 请求'
              '（实际发了 ${client.called}）',
        );
      }
    });
  });

  group('一条通知只花它那一个往返', () {
    test(
      '{keys:[session.list]} ⇒ 恰好一次 client.call，方法名就是 session.list',
      () async {
        // 上一版这里是 **7 次**（一行通知把六个目录顺带给问了）。
        final (app, client) = await _running();
        addTearDown(app.dispose);

        client.hostStates.add(
          const HostStateChanged(keys: <String>[HostStateKey.sessionList]),
        );
        await Future<void>.delayed(const Duration(milliseconds: 90));

        expect(client.called, <String>[
          HostStateKey.sessionList,
        ], reason: '一条通知只该拉它说的那一份快照（实际 ${client.called}）');
      },
    );

    test('没有生产者的三个 key 写进通知 ⇒ 零请求', () async {
      final (app, client) = await _running();
      addTearDown(app.dispose);

      client.hostStates.add(
        const HostStateChanged(
          keys: <String>[
            HostStateKey.agentPresetsList,
            HostStateKey.workspaceList,
            HostStateKey.repoInfo,
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(client.called, isEmpty, reason: '宿主没有"这张表变了"的事件，这三个 key 不该被通知驱动');
      expect(
        app.unknownHostStateKeys,
        0,
        reason: '它们在登记表里，只是不接受 notification（不是"不认识"）',
      );
    });

    test('有生产者的另外两个（模型目录 / 权限目录）接受通知', () async {
      final (app, client) = await _running();
      addTearDown(app.dispose);

      client.hostStates.add(
        const HostStateChanged(
          keys: <String>[
            HostStateKey.sessionModelCatalog,
            HostStateKey.permissionCatalog,
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(client.called, <String>[
        HostStateKey.sessionModelCatalog,
        HostStateKey.permissionCatalog,
      ]);
    });
  });

  group('自己的写（ownWrite 列）', () {
    test('立即执行（不压合并窗口），且只重拉行', () async {
      final (app, client) = await _running(
        window: const Duration(milliseconds: 200),
      );
      addTearDown(app.dispose);

      await app.refreshAfterOwnWrite();
      // **没有等 200 ms**：这个时机不是高频事件，压窗口只让界面白等一帧。
      expect(client.called, <String>[HostStateKey.sessionList]);
    });

    test('切模型走登记表：写完之后重拉行（不是拉全套）', () async {
      final (app, client) = await _running(
        rows: <Map<String, Object?>>[_row('sid_A', updatedAt: 1)],
      );
      addTearDown(app.dispose);
      await app.openSession('sid_A');
      client.reset();

      await app.selectModel(provider: 'p', model: 'm');

      expect(
        client.called,
        contains(HostStateKey.sessionList),
        reason: '切完必须重拉行 —— 输入栏的模型名读的是行里的 `model`',
      );
      expect(
        client.called.where((m) => m == 'session.modelCatalog'),
        isEmpty,
        reason: '切模型不该把模型目录也拉一遍',
      );
      expect(
        client.called.where((m) => m == 'settings.describe'),
        isEmpty,
        reason: '切模型不该把设置面也拉一遍',
      );
    });
  });

  group('首屏（connectLanding 一列）', () {
    test('九项各一次，且**并行发起**（第一个返回前其余八个已发出）', () async {
      final (app, client) = await _running();
      addTearDown(app.dispose);
      // 会话级两个 key 要先有一个当前会话（首屏的真实形态：重连时正开着会话）。
      await app.openSession('sid_A');
      client.reset();
      client.gate = Completer<void>();

      final landing = app.landAfterConnect();
      await _settle();

      expect(
        client.called.toSet(),
        HostStateKey.all.toSet(),
        reason: '九项都该发起（实际 ${client.called}）',
      );
      expect(
        client.called,
        hasLength(HostStateKey.all.length),
        reason: '每项各一次',
      );
      expect(
        client.finished,
        isEmpty,
        reason: '第一个请求还没返回，其余八个就已经发出去了 —— 这才是并行',
      );

      client.gate!.complete();
      await landing;
      expect(client.finished, hasLength(HostStateKey.all.length));
    });

    test('九项里任何一项抛错都不拦落点', () async {
      // 拆开之后最容易出现的退化：某个目录失败 ⇒ 批次抛 ⇒ 首屏卡在加载态。
      final (app, client) = await _running(
        rows: <Map<String, Object?>>[_row('sid_A', updatedAt: 5)],
        failFor: <String>{
          HostStateKey.sessionModelCatalog,
          HostStateKey.agentPresetsList,
          HostStateKey.repoInfo,
        },
      );
      addTearDown(app.dispose);

      await app.landAfterConnect();

      expect(app.currentSid, 'sid_A', reason: '目录挂了也要落到会话上');
      expect(app.landingDone, isTrue, reason: '界面不该停在加载态');
    });

    test('到达的六次通知合并成一次（整棵树只重建一次）', () async {
      final (app, client) = await _running();
      addTearDown(app.dispose);
      await app.openSession('sid_A');

      var notifies = 0;
      app.addListener(() => notifies += 1);

      await app.landAfterConnect();

      expect(
        notifies,
        1,
        reason:
            '行 / 投影 / 设置 / 任务表 / 三个目录各自都要通知，'
            '不合并的话首屏整棵树重建六次以上',
      );

      // 闸不许关死：批次之外的通知照旧即时。
      await app.refreshSessionRows();
      expect(notifies, 2, reason: '批次结束后通知要恢复即时');
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
      expect(client.called, hasLength(2), reason: '切模型 = 行 + 投影两个往返（上一版是八个）');
    });

    test('设置面单独来一条通知：只拉一次（不牵动会话清单）', () async {
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
