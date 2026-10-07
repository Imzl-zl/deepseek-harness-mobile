/// 轨迹页（`ui/trajectory_page.dart`）的回归。
///
/// 照 `mock/proto/index.html` 的第二个 `.pg` 与 `styles.css` 的
/// `.gantt` / `.ledger`。
///
/// ## 这一组守三件事
///
/// 1. **色条是语义不是装饰**：四类（上下文/助手/工具/错误）的色条颜色
///    与消息流里的角色色**同一套** —— 于是"这一行是什么"不读文字也能看出来。
/// 2. **甘特固定 640px 宽**（原型 `.gantt-in { width:640px }`）：
///    时间轴要有稳定刻度，跟着屏宽变会让两张截图没法对比。
/// 3. **账本条目点得动**（弹 `sheet-traj`）：甘特给"形状"，账本给"明细"，
///    而明细要能展开 —— 否则"那 84 毫秒干了啥"没人答得上。
library;

import 'package:dsh_mobile/theme/dsh_colors.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/trajectory_page.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('甘特四行都在（输入 / 模型 / 工具 / 错误）', (tester) async {
    await tester.pumpWidget(_wrap(const TrajectoryTab()));
    await tester.pumpAndSettle();

    for (final label in ['输入', '模型', '工具', '错误']) {
      expect(find.text(label), findsWidgets, reason: '甘特缺「$label」那一行');
    }
    // 横滑提示（照原型那句原文）。
    expect(find.text('← 横滑查看完整时间轴 →'), findsOneWidget);
  });

  testWidgets('甘特的时间轴是**固定 640px**（不是跟屏宽）', (tester) async {
    // 原型 `.gantt-in { width:640px }`：刻度要稳定。
    await tester.pumpWidget(_wrap(const TrajectoryTab()));
    await tester.pumpAndSettle();

    final track = tester
        .widgetList<SizedBox>(find.byType(SizedBox))
        .where((s) => s.width == 640);
    expect(track, isNotEmpty, reason: '甘特内层该是固定 640px 宽');
  });

  testWidgets('账本四类条目都在，且**色条是语义色**', (tester) async {
    await tester.pumpWidget(_wrap(const TrajectoryTab()));
    await tester.pumpAndSettle();

    // 四类的名字都在。
    //
    // **「错误」会出现两次**：甘特有一行是它、账本里还有一条也是它 ——
    // 那是数据的真实重复（同一个东西在"形状"与"明细"里各出现一次），
    // 不是 bug。第一版写成 `findsOneWidget` 就红了。
    expect(find.text('上下文'), findsOneWidget);
    expect(find.text('助手'), findsOneWidget);
    expect(find.text('工具 · read'), findsOneWidget);
    expect(find.text('错误'), findsNWidgets(2));

    // 色条颜色与角色色同一套 —— 收集所有 3px 宽的容器，看颜色齐不齐。
    final barColors = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) => c.constraints?.maxWidth == 3)
        .map((c) => (c.decoration as BoxDecoration?)?.color)
        .toSet();
    expect(barColors.contains(DshColors.roleContext), isTrue, reason: '上下文色条');
    expect(barColors.contains(DshColors.roleAssistant), isTrue, reason: '助手色条');
    expect(barColors.contains(DshColors.roleTool), isTrue, reason: '工具色条');
    expect(barColors.contains(DshColors.error), isTrue, reason: '错误色条');
  });

  testWidgets('点账本条目回调（接线到 sheet-traj）', (tester) async {
    TraceEntry? tapped;
    await tester.pumpWidget(
      _wrap(TrajectoryTab(onTapEntry: (e) => tapped = e)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('工具 · read'));
    await tester.pumpAndSettle();
    expect(tapped?.name, '工具 · read');
  });

  testWidgets('工具那一类的摘要用等宽（它是路径/命令）', (tester) async {
    await tester.pumpWidget(_wrap(const TrajectoryTab()));
    await tester.pumpAndSettle();

    final summary = tester.widget<Text>(
      find.text('rikkahub/…/ChatPage.kt → 741 行'),
    );
    expect(summary.style?.fontFamily, 'monospace');
  });

  testWidgets('长摘要最多两行（`.lg .r2 { line-clamp:2 }`）', (tester) async {
    await tester.pumpWidget(_wrap(const TrajectoryTab()));
    await tester.pumpAndSettle();

    final summary = tester.widget<Text>(
      find.text('系统提示词 + 工具定义注入，含 4 个 MCP server'),
    );
    expect(summary.maxLines, 2);
  });

  testWidgets('可以传自己的数据（不是只用示例）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const TrajectoryTab(
          rows: [
            GanttRow(label: '输入', color: DshColors.businessBlue, spans: []),
          ],
          entries: [
            TraceEntry(
              kind: TraceKind.assistant,
              name: '只有一条',
              took: '1 s',
              summary: '摘要',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('只有一条'), findsOneWidget);
    // 示例数据不该出现。
    expect(find.text('工具 · read'), findsNothing);
  });
}
