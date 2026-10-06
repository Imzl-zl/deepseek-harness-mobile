/// 右抽屉（`ui/side_pane.dart` + `ui/dsh_diff.dart`）的回归。
///
/// 照 `mock/proto` 的 `section.page--side`：**一个抽屉三个面板**
/// （文件 / 任务 / 子代理），竖屏手机上它是全屏页。
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
  List<SideJob> jobs = const [],
  List<SideJob> subs = const [],
  int runningJobs = 0,
  int runningSubs = 0,
  ValueChanged<SidePanel>? onPanelChanged,
  void Function(SideJob)? onToggleJob,
  void Function(SideJob)? onStopJob,
  Set<String> openIds = const {},
}) => SidePane(
  header: _header,
  panel: panel,
  onPanelChanged: onPanelChanged ?? (_) {},
  onClose: () {},
  fileBody: fileBody,
  jobs: jobs,
  subs: subs,
  runningJobs: runningJobs,
  runningSubs: runningSubs,
  onToggleJob: onToggleJob,
  onStopJob: onStopJob,
  openJobIds: openIds,
);

void main() {
  group('右抽屉', () {
    testWidgets('三个面板 tab 都在（文件 / 任务 / 子代理）', (tester) async {
      await tester.pumpWidget(_wrap(_pane()));
      await tester.pumpAndSettle();
      expect(find.text('文件'), findsOneWidget);
      expect(find.text('任务'), findsOneWidget);
      expect(find.text('子代理'), findsOneWidget);
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
