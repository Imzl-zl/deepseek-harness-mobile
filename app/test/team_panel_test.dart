/// 右抽屉「任务板」这一枚：可见性三态 + 面板主体。
///
/// ## 可见性判据只有一处
///
/// `visibleSidePanels(teamAvailable, childSession)` —— tab 条、计数徽标、面板主体
/// 三处都读它（`ui/side_pane.dart`）。所以这组测试不测"某个 widget 里有没有那个字"，
/// 而是直接钉那条函数的三态，再各配一条渲染证据：
///
/// | 场景 | 期望 |
/// |---|---|
/// | 老宿主（`caps.team == false`） | **整枚 tab 不出现**，不摆空板 |
/// | 子会话（照抄 DSH：`TeamModeToggle.tsx:30-32` 对子会话 `return null`） | 不出现 |
/// | 根会话 + 有服务 | 出现，且主体是共享任务 |
/// | 选中的那枚已经不在集合里 | 就地回落到第一枚，不留空主体 |
///
/// 取舍与证据见 `.agents/notes/implemented/2026-11-14-agent-team-readonly.md`。
library;

import 'package:dsh_mobile/model/team_board.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/side_pane.dart';
import 'package:dsh_mobile/ui/side_panel_visibility.dart';
import 'package:dsh_mobile/ui/team_board_view.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(body: child),
);

TeamTask _task({
  String id = 'task-1',
  String subject = '写实现',
  TeamTaskStatus status = TeamTaskStatus.pending,
  bool ready = true,
  String? ownerId,
  String? ownerName,
  String description = '',
}) => TeamTask(
  id: id,
  revision: 1,
  subject: subject,
  description: description,
  status: status,
  ready: ready,
  ownerId: ownerId,
  ownerName: ownerName,
);

SidePane _pane({
  required SidePanel panel,
  required List<SidePanel> panels,
  Widget? teamBody,
  Widget? fileBody,
  int runningTeam = 0,
  ValueChanged<SidePanel>? onPanelChanged,
}) => SidePane(
  header: const SideHeader(title: '共享任务'),
  panel: panel,
  panels: panels,
  onPanelChanged: onPanelChanged ?? (_) {},
  onClose: () {},
  fileBody: fileBody,
  teamBody: teamBody,
  runningTeam: runningTeam,
);

void main() {
  group('visibleSidePanels', () {
    test('老宿主没有 Team 服务 ⇒ 整枚 tab 不出现', () {
      final panels = visibleSidePanels(
        teamAvailable: false,
        childSession: false,
      );
      expect(panels, isNot(contains(SidePanel.team)));
      expect(panels, [SidePanel.file, SidePanel.jobs, SidePanel.subs]);
    });

    test('子会话 ⇒ 不出现（照抄 DSH：任务板与开关一起藏）', () {
      final panels = visibleSidePanels(teamAvailable: true, childSession: true);
      expect(panels, isNot(contains(SidePanel.team)));
    });

    test('根会话 + 有服务 ⇒ 出现，且排在子智能体之后', () {
      final panels = visibleSidePanels(
        teamAvailable: true,
        childSession: false,
      );
      expect(panels, [
        SidePanel.file,
        SidePanel.jobs,
        SidePanel.subs,
        SidePanel.team,
      ]);
    });
  });

  group('SidePane 里的任务板', () {
    testWidgets('集合里有 team 时才画出那枚 tab；点它切面板', (tester) async {
      SidePanel? tapped;
      await tester.pumpWidget(
        _wrap(
          _pane(
            panel: SidePanel.file,
            panels: const [
              SidePanel.file,
              SidePanel.jobs,
              SidePanel.subs,
              SidePanel.team,
            ],
            onPanelChanged: (p) => tapped = p,
          ),
        ),
      );
      expect(find.text('任务板'), findsOneWidget);
      await tester.tap(find.text('任务板'));
      expect(tapped, SidePanel.team);
    });

    testWidgets('集合里没有 team ⇒ 一个字都不出现', (tester) async {
      await tester.pumpWidget(
        _wrap(
          _pane(
            panel: SidePanel.file,
            panels: const [SidePanel.file, SidePanel.jobs, SidePanel.subs],
          ),
        ),
      );
      expect(find.text('任务板'), findsNothing);
    });

    testWidgets('选中的 team 已不在集合里 ⇒ 回落到第一枚，不留空主体', (tester) async {
      await tester.pumpWidget(
        _wrap(
          _pane(
            panel: SidePanel.team,
            panels: const [SidePanel.file, SidePanel.jobs, SidePanel.subs],
            fileBody: const Text('文件面板主体'),
            teamBody: const Text('不该出现'),
          ),
        ),
      );
      expect(find.text('文件面板主体'), findsOneWidget);
      expect(find.text('不该出现'), findsNothing);
      expect(find.text('任务板'), findsNothing);
    });

    testWidgets('进行中的任务数进徽标；0 时不显示', (tester) async {
      await tester.pumpWidget(
        _wrap(
          _pane(
            panel: SidePanel.file,
            panels: const [SidePanel.file, SidePanel.team],
            runningTeam: 2,
          ),
        ),
      );
      expect(find.text('2'), findsOneWidget);
      await tester.pumpWidget(
        _wrap(
          _pane(
            panel: SidePanel.file,
            panels: const [SidePanel.file, SidePanel.team],
          ),
        ),
      );
      expect(find.text('0'), findsNothing);
    });
  });

  group('TeamBoardView', () {
    testWidgets('还没读到投影 ⇒ 一句话，不是空板', (tester) async {
      await tester.pumpWidget(_wrap(const TeamBoardView(board: null)));
      expect(find.text('正在加载任务板…'), findsOneWidget);
    });

    testWidgets('标题行是「共享任务」+ 进度短语', (tester) async {
      final board = TeamBoard(
        enabled: true,
        tasks: [
          _task(id: 'task-1', status: TeamTaskStatus.completed),
          _task(id: 'task-2', status: TeamTaskStatus.inProgress),
        ],
      );
      await tester.pumpWidget(_wrap(TeamBoardView(board: board)));
      expect(find.text('共享任务'), findsOneWidget);
      expect(find.text('1 已完成\u2002·\u20021 进行中'), findsOneWidget);
    });

    testWidgets('点一行展开：说明 + 负责人（缺席时回落「未分配」）', (tester) async {
      final board = TeamBoard(
        enabled: true,
        tasks: [
          _task(
            id: 'task-1',
            subject: '写解析器',
            description: '按 zod schema 解，不重算 ready',
            status: TeamTaskStatus.inProgress,
            ownerId: 'session-abc',
            ownerName: 'lead/writer',
          ),
          _task(id: 'task-2', subject: '写测试'),
        ],
      );
      await tester.pumpWidget(_wrap(TeamBoardView(board: board)));
      expect(find.text('按 zod schema 解，不重算 ready'), findsNothing);
      await tester.tap(find.text('写解析器'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('按 zod schema 解，不重算 ready'), findsOneWidget);
      expect(find.text('负责人：lead/writer'), findsOneWidget);
      // 第二行仍收着
      await tester.tap(find.text('写测试'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('负责人：未分配'), findsOneWidget);
    });

    testWidgets('投影报的记录无效 ⇒ 原样显示，不翻译成「加载失败」', (tester) async {
      final board = TeamBoard(
        enabled: true,
        failure: 'unsupported Agent Teams event version 3',
        tasks: [_task(id: 'task-1', status: TeamTaskStatus.completed)],
      );
      await tester.pumpWidget(_wrap(TeamBoardView(board: board)));
      expect(
        find.text('任务记录无效：unsupported Agent Teams event version 3'),
        findsOneWidget,
      );
      // 失败时任务仍然画（宿主保留上一版有效任务，projection.ts:190-196）
      expect(find.text('写实现'), findsOneWidget);
    });

    testWidgets('写作用域冲突告警照样显示（那是宿主的告警，不是我们的锁）', (tester) async {
      const board = TeamBoard(
        enabled: true,
        tasks: [
          TeamTask(
            id: 'task-1',
            revision: 2,
            subject: '改连接器',
            description: '',
            status: TeamTaskStatus.inProgress,
            ready: true,
            writeScopeWarnings: ['write scopes overlap with task-2'],
          ),
        ],
      );
      await tester.pumpWidget(_wrap(const TeamBoardView(board: board)));
      await tester.tap(find.text('改连接器'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('write scopes overlap with task-2'), findsOneWidget);
    });
  });
}
