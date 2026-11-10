/// 新建会话落进哪个工作区（照 DSH 的 `startSession` 链）。
///
/// ## 这一组守什么
///
/// 2026-10-22 真机反馈：**手机上新建的会话永远进「未分组」**。
/// 根因不是分组算法，而是 `session.create` **没带 `workspaceId`** ——
/// 宿主只在给了它的时候才 `workspace.attachSession`
/// （`packages/api/session-controller/src/commands.ts:116-148`），
/// 而分组只认 `workspace.list` 的 `sessionIds`。
///
/// 判据两条：
/// 1. 纯函数 [newSessionWorkspaceId] 的链与并列规则（DSH `navigation.ts:320-334`、
///    `:553-572`）；
/// 2. `AppModel.createSession` 真的把解析结果放进了请求体，
///    而一个工作区都没有时**不塞**（那时"未分组"是事实）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 记录 `session.create` 请求体、按方法给固定应答的替身。
class _CreateClient extends FakeSyncClient {
  _CreateClient({required this.rows, required this.workspacesReply, this.gate});

  final List<Map<String, Object?>> rows;

  /// 名字不叫 `workspaces`：`FakeSyncClient` 实现了 `HostRpc`，那个能力的成员
  /// 就叫 `workspaces`（端口的方法名），同名会变成"用字段覆盖方法"。
  final Map<String, Object?> workspacesReply;

  /// 每次 `session.create` 的请求体（断言"到底带没带 workspaceId"）。
  final List<Map<String, Object?>> createParams = <Map<String, Object?>>[];

  /// `session.list` 被拉了几次（"建完重读清单"的判据）。
  int listCalls = 0;

  /// 让 `session.create` 停在半路（在途合并那条用）。
  final Completer<void>? gate;

  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();
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

  /// 某个工作区的目录（建出来的会话要落在这个 cwd 上，`findBlankSession` 才认）。
  String _pathOf(Object? workspaceId) {
    for (final group in (workspacesReply['workspaces'] as List? ?? const [])) {
      if (group is Map && group['workspaceId'] == workspaceId) {
        return group['path'] as String? ?? '';
      }
    }
    return '';
  }

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    switch (method) {
      case 'session.list':
        listCalls += 1;
        return <String, Object?>{'sessions': rows} as T;
      case 'workspace.list':
        return workspacesReply as T;
      case 'session.create':
        createParams.add(params);
        // 在途闸门：先挂在这里，让第二次点击确实落在"还没回来"的窗口里。
        await (gate?.future ?? Future<void>.value());
        final wid = params['workspaceId'];
        // **宿主的行为**：给了 `workspaceId` 就把它记进该工作区的账本
        // （`session-controller/src/commands.ts:138-148`），并且清单里
        // 立刻多出一条 **blank: true** 的会话。替身照做，否则"建完重读清单"
        // 与"本地行不撒谎"两条断言都测不到真东西。
        if (wid is String) {
          for (final group
              in (workspacesReply['workspaces'] as List? ?? const [])) {
            if (group is Map && group['workspaceId'] == wid) {
              (group['sessionIds'] as List).add('new-1');
            }
          }
        }
        rows.add(_row('new-1', cwd: _pathOf(wid), updatedAt: 1, blank: true));
        return <String, Object?>{'sid': 'new-1'} as T;
      default:
        return <String, Object?>{} as T;
    }
  }
}

Map<String, Object?> _row(
  String sid, {
  required String cwd,
  required int updatedAt,
  bool blank = false,
}) => <String, Object?>{
  'sid': sid,
  'cwd': cwd,
  'updatedAt': updatedAt,
  'blank': blank,
  // 恒发键：连接器对每一行**无条件**写出它们（`connector/src/handlers.ts:740-744`），
  // 解码层据此把它们当必填 —— 假行也必须是线上形状。
  'running': false,
  'subagent': false,
};

Map<String, Object?> _workspaces(
  List<Map<String, Object?>> groups, {
  List<String> archived = const [],
}) => <String, Object?>{
  'workspaces': groups,
  'archivedSessionIds': archived,
  'pinnedSessionIds': const <String>[],
};

Map<String, Object?> _group(
  String id,
  String path,
  List<String> sessionIds, {
  String createdAt = '',
}) => <String, Object?>{
  'workspaceId': id,
  'title': id.toUpperCase(),
  'path': path,
  'sessionIds': sessionIds,
  // 连接器无条件写这个键（`handlers.ts:997-1010`）：假行也一样，
  // 空串是"不知道创建时间"，不是"没有这个键"。
  'createdAt': createdAt,
};

void main() {
  group('newSessionWorkspaceId（纯函数，照 DSH 的链）', () {
    final groups = <WorkspaceGroup>[
      const WorkspaceGroup(
        workspaceId: 'w1',
        title: 'W1',
        path: r'D:\w1',
        sessionIds: ['s2'],
      ),
      const WorkspaceGroup(
        workspaceId: 'w2',
        title: 'W2',
        path: r'D:\w2',
        sessionIds: ['s1'],
      ),
    ];

    test('显式给的最优先', () {
      expect(
        newSessionWorkspaceId(
          explicit: 'w9',
          currentWorkspaceId: 'w2',
          groups: groups,
          updatedAtOf: (_) => 0,
        ),
        'w9',
      );
    });

    test('其次：当前会话所在的工作区（哪怕它不是最近的）', () {
      expect(
        newSessionWorkspaceId(
          currentWorkspaceId: 'w2',
          groups: groups,
          // w1 里那条比 w2 里的新 —— 当前会话仍优先。
          updatedAtOf: (sid) => sid == 's2' ? 999 : 1,
        ),
        'w2',
      );
    });

    test('再次：最近的工作区（按组内会话的最大 updatedAt）', () {
      expect(
        newSessionWorkspaceId(
          groups: groups,
          updatedAtOf: (sid) => sid == 's2' ? 999 : 1,
        ),
        'w1',
      );
    });

    test('一个工作区都没有：null（不猜）', () {
      expect(
        newSessionWorkspaceId(groups: const [], updatedAtOf: (_) => 0),
        isNull,
      );
    });

    test('全都空着 / 并列：按宿主行序取第一个', () {
      expect(
        newSessionWorkspaceId(groups: groups, updatedAtOf: (_) => 0),
        'w1',
      );
      final empty = <WorkspaceGroup>[
        const WorkspaceGroup(
          workspaceId: 'a',
          title: 'A',
          path: r'D:\a',
          sessionIds: [],
        ),
        const WorkspaceGroup(
          workspaceId: 'b',
          title: 'B',
          path: r'D:\b',
          sessionIds: [],
        ),
      ];
      expect(newSessionWorkspaceId(groups: empty, updatedAtOf: (_) => 0), 'a');
    });

    test('空工作区靠 createdAt 参与比较：刚建的空工作区赢过老会话', () {
      // DSH 的 `recentWorkspace` 对没有会话的工作区用 `Date.parse(createdAt)`
      //（`navigation.ts:565`）—— 手机侧现在也照这条比。
      final mixed = <WorkspaceGroup>[
        const WorkspaceGroup(
          workspaceId: 'used',
          title: 'U',
          path: r'D:\u',
          sessionIds: ['s'],
        ),
        const WorkspaceGroup(
          workspaceId: 'fresh',
          title: 'F',
          path: r'D:\f',
          sessionIds: [],
          // 比那条会话的 updatedAt 更新。
          createdAt: '2026-10-22T10:00:00.000Z',
        ),
      ];
      final sessionAt = DateTime.parse(
        '2026-10-21T10:00:00.000Z',
      ).millisecondsSinceEpoch;
      expect(
        newSessionWorkspaceId(groups: mixed, updatedAtOf: (_) => sessionAt),
        'fresh',
      );
    });

    test('电脑侧没给 createdAt（老连接器）⇒ 空工作区仍然赢不了（不猜时间）', () {
      final mixed = <WorkspaceGroup>[
        const WorkspaceGroup(
          workspaceId: 'empty',
          title: 'E',
          path: r'D:\e',
          sessionIds: [],
        ),
        const WorkspaceGroup(
          workspaceId: 'used',
          title: 'U',
          path: r'D:\u',
          sessionIds: ['s'],
        ),
      ];
      expect(
        newSessionWorkspaceId(groups: mixed, updatedAtOf: (_) => 5),
        'used',
      );
    });
  });

  group('AppModel.createSession 带对 workspaceId', () {
    Future<AppModel> open(_CreateClient client) async {
      final app = AppModel(client: client);
      addTearDown(app.dispose);
      await app.start();
      await app.refreshSessionRows();
      // 分组只认 `workspace.list` 的那一份快照（登记表里的 `workspace.list`）：
      // 行不再顺带把它拉回来。
      await app.refreshWorkspaces();
      return app;
    }

    test('当前会话在某工作区 ⇒ 请求体带它', () async {
      final client = _CreateClient(
        rows: [
          _row('s1', cwd: r'D:\w2', updatedAt: 10),
          _row('s2', cwd: r'D:\w1', updatedAt: 99),
        ],
        workspacesReply: _workspaces([
          _group('w1', r'D:\w1', ['s2']),
          _group('w2', r'D:\w2', ['s1']),
        ]),
      );
      final app = await open(client);
      await app.openSession('s1');

      expect(app.currentWorkspace?.workspaceId, 'w2');
      await app.createSession();

      expect(client.createParams.single['workspaceId'], 'w2');
      // **建完会重读一次工作区清单**：新会话立刻归到那个分组，
      // 而不是在抽屉里先落「未分组」、等下次刷新才归位
      //（2026-10-22 真机：不重读的话要杀 App 重开才对）。
      expect(app.currentWorkspace?.workspaceId, 'w2');
      expect(
        app.workspaces.firstWhere((g) => g.workspaceId == 'w2').sessionIds,
        contains('new-1'),
      );
    });

    test('没有当前会话 ⇒ 取最近工作区（不是行序第一个）', () async {
      final client = _CreateClient(
        rows: [
          _row('s1', cwd: r'D:\w2', updatedAt: 10),
          _row('s2', cwd: r'D:\w1', updatedAt: 99),
        ],
        workspacesReply: _workspaces([
          _group('w1', r'D:\w1', ['s2']),
          _group('w2', r'D:\w2', ['s1']),
        ]),
      );
      final app = await open(client);

      await app.createSession();

      expect(
        client.createParams.single['workspaceId'],
        'w1',
        reason: 'w1 里的会话 updatedAt 更大 ⇒ 它更近',
      );
    });

    test('一个工作区都没有 ⇒ **不塞** workspaceId（未分组是事实）', () async {
      final client = _CreateClient(
        rows: [_row('s1', cwd: r'D:\w', updatedAt: 10)],
        workspacesReply: _workspaces(const []),
      );
      final app = await open(client);

      await app.createSession();

      expect(client.createParams.single.containsKey('workspaceId'), isFalse);
      // 会话仍然建出来了（不是"没有工作区就不建"）。
      expect(app.currentSid, 'new-1');
    });

    test('显式给的工作区压过链（hero 的 chip 走这条）', () async {
      final client = _CreateClient(
        rows: [_row('s1', cwd: r'D:\w2', updatedAt: 10)],
        workspacesReply: _workspaces([
          _group('w1', r'D:\w1', ['s9']),
          _group('w2', r'D:\w2', ['s1']),
        ]),
      );
      final app = await open(client);
      await app.openSession('s1');

      await app.createSession(workspaceId: 'w1');

      expect(client.createParams.single['workspaceId'], 'w1');
    });
  });

  group('findBlankSession 只复用这个工作区里的 blank', () {
    test('别的工作区的 blank 不拿来复用', () async {
      final client = _CreateClient(
        rows: [
          _row('b1', cwd: r'D:\w2', updatedAt: 5, blank: true),
          _row('b2', cwd: r'D:\w1', updatedAt: 4, blank: true),
        ],
        workspacesReply: _workspaces([
          _group('w1', r'D:\w1', ['b2']),
          _group('w2', r'D:\w2', ['b1']),
        ]),
      );
      final app = AppModel(client: client);
      addTearDown(app.dispose);
      await app.start();
      await app.refreshSessionRows();
      await app.refreshWorkspaces();

      // 照 DSH `createInWorkspace`：blank && cwd == workspace.path &&
      // workspace.sessionIds.includes(id)（`navigation.ts:220-233`）。
      expect(await app.findBlankSession(workspaceId: 'w1'), 'b2');
      // 不给工作区时保持原行为（第一个 blank），供"启动时落到 blank"用。
      expect(await app.findBlankSession(), 'b1');
    });
  });

  group('createSession 的在途合并与本地行（2026-11-07 真机：一秒内 3 个空会话）', () {
    Future<AppModel> open(_CreateClient client) async {
      final app = AppModel(client: client);
      addTearDown(app.dispose);
      await app.start();
      await app.refreshSessionRows();
      await app.refreshWorkspaces();
      await app.openSession('s1');
      return app;
    }

    _CreateClient clientWith({Completer<void>? gate}) => _CreateClient(
      rows: [_row('s1', cwd: r'D:\w2', updatedAt: 10)],
      workspacesReply: _workspaces([
        _group('w2', r'D:\w2', ['s1']),
      ]),
      gate: gate,
    );

    test('同一工作区连点两次 ⇒ 只发一次 session.create', () async {
      final gate = Completer<void>();
      final client = clientWith(gate: gate);
      final app = await open(client);

      final first = app.createSession();
      final second = app.createSession();
      expect(app.creatingNewSession, isTrue, reason: '界面据此只说一次"正在新建"');

      gate.complete();
      await Future.wait([first, second]);

      expect(
        client.createParams.length,
        1,
        reason: '第二次点击合流到第一次（DSH 的 connecting 表）',
      );
      expect(app.creatingNewSession, isFalse, reason: '回来之后要能再建下一个');
      expect(app.currentSid, 'new-1');
    });

    test('本地那一行**自称 blank**：既是真值，也让下次复用找得到它', () async {
      final app = await open(clientWith());

      // 抓"清单刷新之前"的那一帧：`createSession` 先把本地行摆上、再重读清单，
      // 而重读之后这一行就归电脑侧的真值管了。被钉住的正是**本地那一行**。
      bool? seenBlank;
      String? seenCwd;
      app.addListener(() {
        if (seenBlank != null) return;
        final row = app.sessionOf('new-1');
        if (row != null) {
          seenBlank = row.blank;
          seenCwd = row.cwd;
        }
      });

      await app.createSession();

      expect(seenBlank, isTrue, reason: '宿主刚建的会话一定是空会话；本地行自称非空就是撒谎');
      // **cwd 是复用判据的一半**（`navigation.ts:238-244` 比 `cwd == workspace.path`）：
      // 少了它，清单刷新失败时下一次「新建会话」会再建一个。
      expect(seenCwd, r'D:\w2');
      final row = app.sessionOf('new-1');
      expect(row, isNotNull);
      expect(row!.blank, isTrue, reason: '刷新之后由电脑侧的真值接管，仍然是 blank');
      expect(
        await app.findBlankSession(workspaceId: 'w2'),
        'new-1',
        reason: '下一次「新建会话」要能复用它 —— 否则又会建出第二个',
      );
    });

    test('建完重读一次会话清单（真值以电脑侧为准）', () async {
      final client = clientWith();
      final app = await open(client);
      final before = client.listCalls;

      await app.createSession();

      expect(client.listCalls, before + 1, reason: '标题 / 更新时间 / blank 都在电脑侧');
    });
  });

  group('跑过一轮之后这一行不再算 blank（2026-11-10 真机："点了新建会话没用"）', () {
    test('turn/start 到达 ⇒ blank 立刻翻 false，findBlankSession 不再把它当新会话', () async {
      final client = _StreamingClient(
        rows: [_row('s1', cwd: r'D:\w2', updatedAt: 10, blank: true)],
        workspacesReply: _workspaces([
          _group('w2', r'D:\w2', ['s1']),
        ]),
      );
      addTearDown(client.close);
      final app = AppModel(client: client);
      addTearDown(app.dispose);
      await app.start();
      await app.refreshSessionRows();
      await app.refreshWorkspaces();
      await app.openSession('s1');
      expect(app.sessionOf('s1')!.blank, isTrue, reason: '刚建出来、还没开轮次');
      expect(await app.findBlankSession(), 's1');

      // 真机上的那条路：**自己发了一句**（不重读清单），宿主起了轮次。
      client.push('s1', 'turn/start', seq: 3);
      await Future<void>.delayed(Duration.zero);

      expect(
        app.sessionOf('s1')!.blank,
        isFalse,
        reason:
            '宿主同一条规则：blank = blank && type !== turn/start'
            '（packages/api/session-controller/src/list.ts:51）',
      );
      expect(
        await app.findBlankSession(),
        isNull,
        reason:
            '还有内容却自称 blank ⇒ 下一次「新建会话」复用的就是它自己，'
            'openSession(当前) 什么都不换 —— 真机表现就是"点了没用"',
      );
    });
  });

  group('workspace.list 的 createdAt', () {
    test('原样落到 WorkspaceGroup.createdAt（空工作区当"最近"要靠它）', () async {
      final client = _CreateClient(
        rows: const [],
        workspacesReply: _workspaces([
          _group(
            'empty',
            r'D:\e',
            const [],
            createdAt: '2026-10-22T08:00:00.000Z',
          ),
          // 老连接器不带这个字段 ⇒ 解析成空串（不猜）。
          _group('old', r'D:\o', const []),
        ]),
      );
      final app = AppModel(client: client);
      addTearDown(app.dispose);
      await app.start();
      await app.refreshSessionRows();
      await app.refreshWorkspaces();

      expect(
        app.workspaces.firstWhere((g) => g.workspaceId == 'empty').createdAt,
        '2026-10-22T08:00:00.000Z',
      );
      expect(
        app.workspaces.firstWhere((g) => g.workspaceId == 'old').createdAt,
        '',
      );
      // 于是"最近的工作区"是刚建的那个空工作区。
      expect(
        newSessionWorkspaceId(groups: app.workspaces, updatedAtOf: (_) => -1),
        'empty',
      );
    });
  });
}

/// 能往某条会话的 delta 流里塞事件的替身（`turn/start` 那条用）。
///
/// 放在文件末尾而不是中间：替身是工具，读它的人先要看到用例在断言什么。
class _StreamingClient extends _CreateClient {
  _StreamingClient({required super.rows, required super.workspacesReply});

  final Map<String, StreamController<SessionDelta>> _streams =
      <String, StreamController<SessionDelta>>{};

  StreamController<SessionDelta> _streamOf(String sid) => _streams.putIfAbsent(
    sid,
    () => StreamController<SessionDelta>.broadcast(),
  );

  @override
  Stream<SessionDelta> sessionUpdates(String sid) => _streamOf(sid).stream;

  void push(String sid, String type, {required int seq, int time = 1}) {
    _streamOf(sid).add(
      SessionDelta(
        sid: sid,
        transient: const <String, Object?>{},
        events: [
          SessionEvent(
            itemId: '$type-$seq',
            type: type,
            seq: seq,
            time: time,
            data: const <String, Object?>{},
          ),
        ],
      ),
    );
  }

  @override
  Future<void> close() async {
    for (final stream in _streams.values) {
      await stream.close();
    }
  }
}
