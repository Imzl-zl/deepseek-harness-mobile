/// Agent Teams 共享任务板（`agentTeam` 投影）的解析回归。
///
/// ## 这组守什么
///
/// 任务板**整块都是宿主的判断**：`ready` 是 DAG 推导（`task-view.ts`）、
/// `writeScopeWarnings` 是宿主算好的、`ownerName` 历史数据可能没有
/// （`projection.ts:203-207` 写明 v7 检查点不回填）。手机唯一能做错的事就是
/// **自己再算一遍**或**把缺席编成值** —— 所以这里钉的是：
///
/// 1. 键名只有一处（`values['agentTeam']`，走真入口 `readSessionProjections`）；
/// 2. 缺席的 `ownerName` 按 DSH 的链回落（`ownerName ?? ownerId ?? 未分配`）；
/// 3. 被阻塞 = `pending && !ready`，`in_progress` 即使 `ready` 假也不算阻塞；
/// 4. 单条任务坏掉只丢那一条，顶层坏掉才是 `null`（两者后果完全不同）。
library;

import 'package:dsh_mobile/model/team_board.dart';
import 'package:dsh_mobile/wire/reading.dart';
import 'package:dsh_mobile/wire/rpc/projections.dart'
    show readSessionProjections;
import 'package:flutter_test/flutter_test.dart';

/// 一条任务的**线上形状**（逐字照 `teamTaskViewSchema`，
/// `packages/team/agent-team/src/projection.ts:154-168`）。
///
/// 用逐字段赋值而不是字面量里的 `if (...)`：**map 里绝不能用 null-aware element
/// `?key: value`** —— 它的键取**值的**字符串形式（`tools.md` 记过这个坑，
/// `app_model.dart` 里那条 ignore 同一条）。所以"可选的键"只能这样加。
Map<String, Object?> _task({
  String id = 'task-1',
  int revision = 1,
  String subject = '写解析器',
  String description = '',
  String status = 'pending',
  List<String> blockedBy = const [],
  List<String> writeScopes = const [],
  String? ownerId,
  String? ownerName,
  bool ready = true,
  List<String> writeScopeWarnings = const [],
}) {
  final task = <String, Object?>{
    'id': id,
    'revision': revision,
    'subject': subject,
    'description': description,
    'status': status,
    'blockedBy': blockedBy,
    'writeScopes': writeScopes,
    'ready': ready,
    'writeScopeWarnings': writeScopeWarnings,
  };
  if (ownerId != null) task['ownerId'] = ownerId;
  if (ownerName != null) task['ownerName'] = ownerName;
  return task;
}

/// 整块板的线上形状（`teamProjectionSchema`，`projection.ts:185-190`）。
Map<String, Object?> _board({
  bool enabled = true,
  List<Map<String, Object?>> tasks = const [],
  String? failure,
}) {
  final board = <String, Object?>{'enabled': enabled, 'tasks': tasks};
  if (failure != null) board['failure'] = failure;
  return board;
}

void main() {
  group('parseTeamBoard', () {
    test('完整板：三态任务、依赖、写作用域都按原样解出来', () {
      final board = parseTeamBoard(
        _board(
          tasks: [
            _task(id: 'task-1', status: 'completed', subject: '定方案'),
            _task(
              id: 'task-2',
              revision: 3,
              status: 'in_progress',
              subject: '写实现',
              writeScopes: ['connector/src/dsh'],
              ownerId: 'session-abc',
              ownerName: 'lead/writer',
              writeScopeWarnings: ['write scopes overlap with task-1'],
            ),
            _task(
              id: 'task-3',
              status: 'pending',
              subject: '写测试',
              blockedBy: ['task-2'],
              ready: false,
            ),
          ],
        ),
      );
      expect(board, isNotNull);
      expect(board!.enabled, isTrue);
      expect(board.tasks, hasLength(3));
      expect(board.failure, isNull);

      final inProgress = board.tasks[1];
      expect(inProgress.status, TeamTaskStatus.inProgress);
      expect(inProgress.revision, 3);
      expect(inProgress.ownerText, 'lead/writer');
      expect(inProgress.writeScopes, ['connector/src/dsh']);
      expect(inProgress.writeScopeWarnings, [
        'write scopes overlap with task-1',
      ]);
      expect(inProgress.blocked, isFalse);

      final blocked = board.tasks[2];
      expect(blocked.blocked, isTrue, reason: 'pending 且 !ready 才是被阻塞');
      expect(blocked.blockedBy, ['task-2']);
      expect(blocked.stateLabel, '被依赖阻塞');
    });

    test('ownerName 缺席回落 ownerId；两者都缺席回落「未分配」', () {
      final board = parseTeamBoard(
        _board(
          tasks: [
            _task(id: 'task-1', ownerId: 'session-abc'),
            _task(id: 'task-2'),
          ],
        ),
      )!;
      expect(board.tasks[0].ownerText, 'session-abc');
      expect(board.tasks[1].ownerText, '未分配');
    });

    test('in_progress 即使 ready 为假也不算「被依赖阻塞」', () {
      final board = parseTeamBoard(
        _board(tasks: [_task(status: 'in_progress', ready: false)]),
      )!;
      expect(board.tasks.single.blocked, isFalse);
      expect(board.tasks.single.stateLabel, '进行中');
    });

    test('failure 原样保留（宿主说「记录无效」，不是「加载失败」）', () {
      final board = parseTeamBoard(
        _board(failure: 'unsupported Agent Teams event version 3'),
      )!;
      expect(board.failure, 'unsupported Agent Teams event version 3');
      expect(board.tasks, isEmpty);
    });

    test('deleted 不出现在可见任务里（线上宿主已滤掉，这里是第二道）', () {
      final board = parseTeamBoard(
        _board(
          tasks: [
            _task(id: 'task-1', status: 'completed'),
            _task(id: 'task-2', status: 'deleted'),
          ],
        ),
      )!;
      expect(board.visibleTasks.map((t) => t.id), ['task-1']);
      expect(board.countOf(TeamTaskStatus.deleted), 0);
    });

    test('状态不认识的任务整条丢掉，不降级成「待处理」', () {
      final board = parseTeamBoard(
        _board(
          tasks: [
            _task(id: 'task-1'),
            _task(id: 'task-2', status: 'paused'),
          ],
        ),
      )!;
      expect(board.tasks.map((t) => t.id), ['task-1']);
    });

    test('缺 revision / subject / id 的任务逐条丢掉', () {
      final board = parseTeamBoard(
        _board(
          tasks: [
            _task(id: 'task-1'),
            {
              'id': 'task-2',
              'subject': 'x',
              'status': 'pending',
              'ready': true,
            },
            _task(id: 'task-3', revision: 0),
          ],
        ),
      )!;
      expect(board.tasks.map((t) => t.id), ['task-1']);
    });

    test('顶层形状坏了 ⇒ null（enabled 不是布尔 / tasks 不是数组 / 不是对象）', () {
      expect(parseTeamBoard(null), isNull);
      expect(parseTeamBoard('x'), isNull);
      expect(parseTeamBoard({'tasks': <Object?>[]}), isNull);
      expect(parseTeamBoard({'enabled': 'true', 'tasks': []}), isNull);
      expect(parseTeamBoard({'enabled': true, 'tasks': 'nope'}), isNull);
    });

    test('空板（子会话 / 关着的根会话同形）解析得出来，不是 null', () {
      final board = parseTeamBoard(_board(enabled: false))!;
      expect(board.enabled, isFalse);
      expect(board.visibleTasks, isEmpty);
      expect(board.progressText, '');
    });
  });

  group('progressText', () {
    test('零的那段不出现，分隔符与顺序照 DSH', () {
      final board = parseTeamBoard(
        _board(
          tasks: [
            _task(id: 'task-1', status: 'completed'),
            _task(id: 'task-2', status: 'completed'),
            _task(id: 'task-3', status: 'in_progress'),
            _task(id: 'task-4', status: 'pending'),
            _task(id: 'task-5', status: 'pending'),
            _task(id: 'task-6', status: 'pending'),
          ],
        ),
      )!;
      expect(board.progressText, '2 已完成\u2002·\u20021 进行中\u2002·\u20023 待处理');
      expect(board.activeCount, 1);
    });

    test('只有一种状态时不带分隔符', () {
      final board = parseTeamBoard(_board(tasks: [_task(status: 'pending')]))!;
      expect(board.progressText, '1 待处理');
    });
  });

  group('wire 入口', () {
    test('键名是 values.agentTeam：真入口能把整块板解出来', () {
      WireDiagnostics.reset();
      final value = valueOrReport(
        readSessionProjections({
          'agentTeam': _board(
            tasks: [
              _task(
                id: 'task-1',
                ownerName: 'lead/worker',
                status: 'completed',
              ),
            ],
          ),
        }),
        'session.projections',
      );
      final board = value!.team;
      expect(board, isNotNull);
      expect(board!.enabled, isTrue);
      expect(board.tasks.single.ownerText, 'lead/worker');
      expect(WireDiagnostics.badCount, 0);
    });

    test('键缺席（老宿主）= null，不是空板，且不计数', () {
      WireDiagnostics.reset();
      final value = valueOrReport(
        readSessionProjections({'title': 'x'}),
        'session.projections',
      );
      expect(value!.team, isNull);
      expect(value.title, 'x', reason: '整包照收，只有这一格缺席');
      expect(WireDiagnostics.badCount, 0, reason: '缺席是如实的降级，不是漂移');
    });

    test('键在但形状坏了 ⇒ 字段 null、整包照收、计一次数', () {
      WireDiagnostics.reset();
      final value = valueOrReport(
        readSessionProjections({
          'agentTeam': {'enabled': 'yes', 'tasks': <Object?>[]},
          'title': '标题还在',
        }),
        'session.projections',
      );
      expect(value!.team, isNull);
      expect(value.title, '标题还在');
      expect(WireDiagnostics.badCount, 1, reason: '形状漂了要留声');
      WireDiagnostics.reset();
    });
  });
}
