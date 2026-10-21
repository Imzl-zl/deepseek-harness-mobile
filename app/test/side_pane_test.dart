/// 右抽屉（`ui/side_pane.dart` + `ui/dsh_diff.dart`）的回归。
///
/// 照 `mock/proto` 的 `section.page--side`：**一个抽屉三个面板**
/// （文件 / 任务 / 子智能体），竖屏手机上它是全屏页。
///
/// 这组守三件事：
/// 1. 三个面板都在，tab 上的计数徽标**只在 >0 时显示**；
/// 2. 任务行区分"进行中（两行）"与"已结束（一行）"，停止**两步确认**；
/// 3. diff 的行号槽底色与正文不同（那是 diff 的读法，少了它长 diff 是一堵墙）。
library;

import 'package:dsh_mobile/theme/dsh_colors.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/dsh_diff.dart';
import 'package:dsh_mobile/ui/side_pane.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(body: child),
);

const _header = SideHeader(
  title: 'chat_page.dart',
  subtitle: 'app/lib/ui/chat_page.dart',
  added: 128,
  removed: 46,
);

SidePane _pane({
  SidePanel panel = SidePanel.file,
  Widget? fileBody,
  Widget? subsBody,
  List<SideJob> jobs = const [],
  int runningJobs = 0,
  int runningSubs = 0,
  ValueChanged<SidePanel>? onPanelChanged,
  void Function(SideJob)? onToggleJob,
  void Function(SideJob)? onStopJob,
  Set<String> openIds = const {},
  VoidCallback? onToggleFullscreen,
  bool fullscreen = false,
}) => SidePane(
  header: _header,
  panel: panel,
  onPanelChanged: onPanelChanged ?? (_) {},
  onClose: () {},
  fileBody: fileBody,
  jobs: jobs,
  subsBody: subsBody,
  runningJobs: runningJobs,
  runningSubs: runningSubs,
  onToggleJob: onToggleJob,
  onStopJob: onStopJob,
  openJobIds: openIds,
  onToggleFullscreen: onToggleFullscreen,
  fullscreen: fullscreen,
);

void main() {
  // ---------------------------------------------------------------------------
  // 宽度：三个面板同一个值（2026-10-19 用户："子智能体还变化大小多割裂啊"）
  // ---------------------------------------------------------------------------

  group('sidePaneWidth', () {
    test('抽屉态：DSH 的最小可用宽 300，窄屏按 86% 兜住', () {
      // **300 是 DSH 的 RIGHTBAR_MIN**（columns.ts:25）。
      // **不取 45%**：那是桌面比例，390dp 的 45% = 175dp 低于 DSH 自己的下限。
      expect(sidePaneWidth(screenWidth: 390, fullscreen: false), 300);
      expect(sidePaneWidth(screenWidth: 430, fullscreen: false), 300);
      // 窄屏（320）上 86% = 275 < 300 ⇒ 用比例，保证右侧露一条缝。
      expect(
        sidePaneWidth(screenWidth: 320, fullscreen: false),
        closeTo(275.2, 0.01),
      );
      // 平板（800）上仍是 300（37%）—— 内容面板不需要铺满。
      expect(sidePaneWidth(screenWidth: 800, fullscreen: false), 300);
    });

    test('全屏态：就是屏宽', () {
      expect(sidePaneWidth(screenWidth: 390, fullscreen: true), 390);
      expect(sidePaneWidth(screenWidth: 800, fullscreen: true), 800);
    });

    test('**签名里没有"哪个面板"** —— 宽度不随面板变', () {
      // 这条守的是 2026-10-19 修掉的那个跳变：原来
      // `_sidePanel == SidePanel.file ? 0.92 : 0.78`，切面板时整块横向跳一下。
      // 现在算术只认屏宽与全屏态 —— 面板不在入参里，**想按面板分叉都做不到**。
      //
      // 这不是"测了个恒等式"：如果谁把面板重新引进宽度计算，
      // 就得改这个签名，而这条用例会先红。
      final file = sidePaneWidth(screenWidth: 390, fullscreen: false);
      final jobs = sidePaneWidth(screenWidth: 390, fullscreen: false);
      final subs = sidePaneWidth(screenWidth: 390, fullscreen: false);
      expect(file, jobs);
      expect(jobs, subs);
    });
  });

  group('右抽屉', () {
    testWidgets('三个面板 tab 都在（文件 / 任务 / 子智能体）', (tester) async {
      await tester.pumpWidget(_wrap(_pane()));
      await tester.pumpAndSettle();
      expect(find.text('文件'), findsOneWidget);
      expect(find.text('任务'), findsOneWidget);
      expect(find.text('子智能体'), findsOneWidget);
    });

    testWidgets('计数徽标**只在 >0 时显示**（原型 `hidden` 逻辑）', (tester) async {
      // 0 个在跑：不显示徽标。
      await tester.pumpWidget(_wrap(_pane()));
      await tester.pumpAndSettle();
      expect(find.text('0'), findsNothing);

      // 2 个在跑：显示 `2`。
      await tester.pumpWidget(_wrap(_pane(runningJobs: 2, runningSubs: 1)));
      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('切面板回调被调到，且带对的枚举', (tester) async {
      SidePanel? picked;
      await tester.pumpWidget(_wrap(_pane(onPanelChanged: (p) => picked = p)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('任务'));
      await tester.pumpAndSettle();
      expect(picked, SidePanel.jobs);
    });

    testWidgets('顶部显示文件名 + 完整路径 + 变更统计', (tester) async {
      await tester.pumpWidget(_wrap(_pane()));
      await tester.pumpAndSettle();
      expect(find.text('chat_page.dart'), findsOneWidget);
      expect(find.text('app/lib/ui/chat_page.dart'), findsOneWidget);
      expect(find.text('+128'), findsOneWidget);
      expect(find.text('−46'), findsOneWidget);
    });
  });

  group('任务面板', () {
    const job = SideJob(
      id: 'j1',
      label: 'flutter build apk --debug',
      kind: 'pwsh',
      state: 'running',
      statusText: '构建中',
      durationText: '02:14',
      output: 'Running Gradle task...',
    );
    const settled = SideJob(
      id: 'j5',
      label: 'node verify.mjs',
      kind: 'pwsh',
      state: 'completed',
      statusText: '已完成',
      durationText: '00:03',
    );

    testWidgets('分组照原型：进行中 / 已结束 N', (tester) async {
      await tester.pumpWidget(
        _wrap(_pane(panel: SidePanel.jobs, jobs: [job, settled])),
      );
      await tester.pumpAndSettle();
      expect(find.text('进行中'), findsOneWidget);
      expect(find.text('已结束 1'), findsOneWidget);
    });

    testWidgets('空列表说"没有后台任务。"', (tester) async {
      await tester.pumpWidget(_wrap(_pane(panel: SidePanel.jobs)));
      await tester.pumpAndSettle();
      expect(find.text('没有后台任务。'), findsOneWidget);
    });

    testWidgets('展开的行显示输出（含 gapBefore 提示）', (tester) async {
      await tester.pumpWidget(
        _wrap(
          _pane(
            panel: SidePanel.jobs,
            jobs: const [
              SideJob(
                id: 'j1',
                label: 'cmd',
                kind: 'pwsh',
                state: 'running',
                statusText: '跑着',
                output: '第一行',
                gapNote: '较早输出已丢弃',
              ),
            ],
            openIds: const {'j1'},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('第一行'), findsOneWidget);
      // **`gapBefore` 必须显式渲染** —— 静默拼接会让用户以为输出是连续的。
      expect(find.text('较早输出已丢弃'), findsOneWidget);
    });

    testWidgets('停止是**两步**：第一次点变"确认停止"，第二次才回调', (tester) async {
      // 停止运行中的任务不可逆，误触的代价是丢掉半天的构建。
      var stopped = 0;
      await tester.pumpWidget(
        _wrap(
          _pane(
            panel: SidePanel.jobs,
            jobs: const [job],
            onStopJob: (_) => stopped += 1,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 第一次点：出现"确认停止"，但**没有**回调。
      //
      // 用 `find.byTooltip` 精确定位停止按钮 —— 那一行里有好几个 `DshIcon`
      //（状态点、chevron 等），`find.byType(DshIcon).first` 会点错那个
      //（第一版两次都栽在"找错了 widget"上）。
      await tester.tap(find.byTooltip('停止'));
      await tester.pumpAndSettle();
      expect(find.text('确认停止'), findsOneWidget);
      expect(stopped, 0, reason: '第一次点不该真停');

      // 第二次点：真回调。
      await tester.tap(find.text('确认停止'));
      await tester.pumpAndSettle();
      expect(stopped, 1);
    });

    testWidgets('armed **3 秒后自己解除**（DSH 的 KILL_ARM_MS）', (tester) async {
      // 少了这一步会有一个真危险：第一下点成 armed，然后去做别的事 ——
      // 回来随手一点（以为在点别的）就把任务杀了。
      // armed 是"我正在确认"，而这个意图有保质期。
      // DSH 同一条：`ui-jobs/.../JobListAction.tsx:64` 的 KILL_ARM_MS = 3000。
      var stopped = 0;
      await tester.pumpWidget(
        _wrap(
          _pane(
            panel: SidePanel.jobs,
            jobs: const [job],
            onStopJob: (_) => stopped += 1,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('停止'));
      await tester.pumpAndSettle();
      expect(find.text('确认停止'), findsOneWidget);

      // 还没到期：仍是 armed。
      await tester.pump(kStopArmWindow - const Duration(milliseconds: 200));
      expect(find.text('确认停止'), findsOneWidget, reason: '窗口内不该提前解除');

      // 到期：自己回到"停止"。
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('确认停止'), findsNothing, reason: '窗口过了要自己解除');
      expect(find.byTooltip('停止'), findsOneWidget);
      expect(stopped, 0, reason: '解除不是"停止"—— 一个任务都不该被杀');
    });
  });

  group('子智能体面板：目录树由调用方给', () {
    testWidgets('面板体就是传进来的那棵树（不是任务行、不是平铺列表）', (tester) async {
      // 子智能体的行结构与手势（活动点 / disclosure / 两行指标 / 点行进入）
      // 在 `subagent_tree_test.dart` 里按目录树自己的判据钉住。
      // 这里只钉**装配**：右抽屉的子智能体面板渲染的是调用方给的树。
      await tester.pumpWidget(
        _wrap(_pane(panel: SidePanel.subs, subsBody: const Text('目录树占位'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('目录树占位'), findsOneWidget);
      // 任务面板那套分组不该出现在子智能体面板里。
      expect(find.text('进行中'), findsNothing);
    });

    testWidgets('给了任务清单也不会串进子智能体面板（两个面板各读各的）', (tester) async {
      await tester.pumpWidget(
        _wrap(
          _pane(
            panel: SidePanel.subs,
            jobs: const [
              SideJob(
                id: 'j1',
                label: 'flutter build apk',
                kind: 'pwsh',
                state: 'running',
                statusText: '构建中',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('flutter build apk'), findsNothing);
      expect(find.text('进行中'), findsNothing);
    });
  });

  group('全屏切换（用户："点击全屏，点击缩回"）', () {
    testWidgets('给了回调才有那枚钮，tooltip 说清当前动作', (tester) async {
      // **不给回调就不摆那枚钮** —— 一个按不动的图标是骗人。
      await tester.pumpWidget(_wrap(_pane(panel: SidePanel.jobs)));
      await tester.pumpAndSettle();
      expect(find.byTooltip('全屏'), findsNothing);
      expect(find.byTooltip('退出全屏'), findsNothing);

      // 抽屉态 ⇒ "全屏"。
      await tester.pumpWidget(
        _wrap(
          _pane(
            panel: SidePanel.jobs,
            onToggleFullscreen: () {},
            fullscreen: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('全屏'), findsOneWidget);
      expect(find.byTooltip('退出全屏'), findsNothing);

      // 全屏态 ⇒ "退出全屏"（**同一枚字形，动作靠 tooltip 说**）。
      await tester.pumpWidget(
        _wrap(
          _pane(
            panel: SidePanel.jobs,
            onToggleFullscreen: () {},
            fullscreen: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('退出全屏'), findsOneWidget);
      expect(find.byTooltip('全屏'), findsNothing);
    });

    testWidgets('点它真的回调', (tester) async {
      var toggled = 0;
      await tester.pumpWidget(
        _wrap(
          _pane(
            panel: SidePanel.jobs,
            onToggleFullscreen: () => toggled += 1,
            fullscreen: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      expect(toggled, 1);
    });
  });

  group('diff 渲染', () {
    testWidgets('三种行都在，且新增/删除有不同的行号槽底色', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const DshDiff([
            DiffLine.hunk('@@ -1,3 +1,3 @@'),
            DiffLine(kind: DiffKind.context, oldLine: 1, newLine: 1, text: 'a'),
            DiffLine(kind: DiffKind.del, oldLine: 2, text: 'b'),
            DiffLine(kind: DiffKind.add, newLine: 2, text: 'c'),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      // 内容与标记都在。
      expect(find.text('a'), findsOneWidget);
      expect(find.text('b'), findsOneWidget);
      expect(find.text('c'), findsOneWidget);
      expect(find.text('+'), findsOneWidget);
      expect(find.text('−'), findsOneWidget);

      // **行号槽的底色与正文不同**：那是 diff 的读法（沿左边缘扫就能定位增删）。
      final containers = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) => c.color != null)
          .map((c) => c.color)
          .toSet();
      expect(
        containers.contains(DshColors.fileDiffAddGutter),
        isTrue,
        reason: '新增行的行号槽该有自己的底色',
      );
      expect(
        containers.contains(DshColors.fileDiffDelGutter),
        isTrue,
        reason: '删除行的行号槽该有自己的底色',
      );
    });

    testWidgets('空 diff 说"没有可显示的差异"（不是空白）', (tester) async {
      await tester.pumpWidget(_wrap(const DshDiff([])));
      await tester.pumpAndSettle();
      expect(find.text('没有可显示的差异'), findsOneWidget);
    });

    testWidgets('文件内容显示行号', (tester) async {
      await tester.pumpWidget(_wrap(const DshCodeLines(['第一行', '第二行'])));
      await tester.pumpAndSettle();
      expect(find.text('第一行'), findsOneWidget);
      expect(find.text('第二行'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('空内容说"没有内容"', (tester) async {
      await tester.pumpWidget(_wrap(const DshCodeLines([])));
      await tester.pumpAndSettle();
      expect(find.text('没有内容'), findsOneWidget);
    });
  });
}
