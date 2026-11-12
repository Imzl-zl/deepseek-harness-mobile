/// 会话流里那几行"能折 / 能点"的语义角色（`ui/chat_turns.dart`）。
///
/// ## 为什么是这六处
///
/// `chat_turns.dart` 是 AI 生成对话的正文区，这几行每天被点几十次，
/// 而它们都是**手写 `InkWell`**：只装点击动作，不装 `SemanticsFlag.isButton`
/// （`RawGestureDetector` 的 `_GestureSemantics.assignSemantics` 只装 `onTap`，
/// `packages/flutter/lib/src/widgets/gesture_detector.dart:1591`）。
/// 朗读器念完文字就停，用户不知道能点。
///
/// 逐个判过"这一下点了会发生什么"（判据同
/// `implemented/2026-11-11-fake-affordances.md` 的反面）：
///
/// | 行 | 有去处时 | 没有去处时 |
/// |---|---|---|
/// | `ToolCard` 标题行 | 展开 / 收起 `.tool-body` | 没详情 ⇒ 纯展示 |
/// | `RetryRow` | 展开重试原因 / 延迟 / 错误码 | 三者都空 ⇒ 纯展示 |
/// | `CompactionRow` 标题行 | 展开压缩摘要 | 没摘要 ⇒ 纯展示 |
/// | `TurnProcessRow` 组头 | 收起 / 展开这一轮的过程 | `onToggle == null` ⇒ 纯展示 |
/// | `_DisclosureHeader`（命令卡 / 思考 / 系统提示） | 展开正文 | 单行文本 ⇒ 纯展示 |
/// | `_Pill`（用量 / 复制 / 分支） | 弹明细 / 复制 / 分支 | 恒有去处 |
///
/// 六处的**条件**都由各自的数据决定，所以每一处都同时钉"有去处 ⇒ 按钮"与
/// "没去处 ⇒ 不是按钮" —— 只钉前者的话，把 `button: true` 写死也不会红。
///
/// 另一条纪律：**只加角色，不合并子节点**（不加 `MergeSemantics` /
/// `excludeSemantics`），行内文字仍读得到 —— 理由见
/// `implemented/2026-11-10-tappable-semantics.md`。
library;

import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_turns.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按朗读器听到的**标签**找节点（`Semantics` 把行内文字合并成这一条）。
SemanticsNode _byLabel(Pattern label) =>
    find.semantics.byLabel(label).evaluate().single;

Widget _host(Widget child) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('工具卡：有详情 ⇒ 按钮，点一下真的展开；没详情 ⇒ 不是按钮', (tester) async {
    await tester.pumpWidget(
      _host(
        const ToolCard(
          name: 'bash',
          status: ToolCallStatus.completed,
          argument: 'ls -la',
          detail: '总用量 12',
        ),
      ),
    );

    final row = _byLabel(RegExp('bash'));
    expect(
      row,
      isSemantics(isButton: true, hasTapAction: true),
      reason: '有详情时这一行是"展开正文"的按钮',
    );
    expect(
      row.getSemanticsData().label,
      contains('ls -la'),
      reason: '行内文字不能被吞',
    );

    tester.semantics.performAction(
      find.semantics.byLabel(RegExp('bash')),
      SemanticsAction.tap,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('总用量 12'), findsOneWidget);

    // 没有详情：这一行只是标题，不该被念成按钮。
    await tester.pumpWidget(
      _host(
        const ToolCard(
          name: 'bash',
          status: ToolCallStatus.completed,
          argument: 'ls -la',
        ),
      ),
    );
    expect(_byLabel(RegExp('bash')), isNot(isSemantics(isButton: true)));
  });

  testWidgets('重试行：能展开 ⇒ 按钮；三者都空 ⇒ 不是按钮', (tester) async {
    await tester.pumpWidget(
      _host(
        const RetryRow(
          title: '重试 2/10',
          message: '连接超时',
          started: false,
          code: 'TIMEOUT',
        ),
      ),
    );
    final row = _byLabel(RegExp('重试'));
    expect(row, isSemantics(isButton: true, hasTapAction: true));

    await tester.pumpWidget(
      _host(const RetryRow(title: '重试 2/10', message: '', started: true)),
    );
    expect(
      _byLabel(RegExp('重试')),
      isNot(isSemantics(isButton: true)),
      reason: '没有原因 / 延迟 / 错误码时展开是空的，不该报按钮',
    );
  });

  testWidgets('压缩行：有摘要 ⇒ 按钮；没摘要 ⇒ 不是按钮', (tester) async {
    await tester.pumpWidget(
      _host(const CompactionRow(summary: '前面聊过的都压掉了', stats: '')),
    );
    expect(
      _byLabel(RegExp('压缩')),
      isSemantics(isButton: true, hasTapAction: true),
    );

    await tester.pumpWidget(_host(const CompactionRow(summary: '', stats: '')));
    expect(_byLabel(RegExp('压缩')), isNot(isSemantics(isButton: true)));
  });

  testWidgets('轮组头：可折叠 ⇒ 按钮；不可折叠 ⇒ 不是按钮', (tester) async {
    await tester.pumpWidget(
      _host(
        TurnProcessRow(
          title: '第 3 轮',
          stats: '2 分 36 秒',
          expanded: true,
          onToggle: () {},
        ),
      ),
    );
    expect(
      _byLabel(RegExp('第 3 轮')),
      isSemantics(isButton: true, hasTapAction: true),
    );

    await tester.pumpWidget(
      _host(
        const TurnProcessRow(title: '第 3 轮', stats: '2 分 36 秒', expanded: true),
      ),
    );
    expect(
      _byLabel(RegExp('第 3 轮')),
      isNot(isSemantics(isButton: true)),
      reason: '不可折叠的组头只有文字，没有去处',
    );
  });

  testWidgets('操作胶囊（复制）：是按钮，名字来自可见文字', (tester) async {
    await tester.pumpWidget(
      _host(
        TurnProcessRow(
          title: '第 3 轮',
          stats: '2 分 36 秒',
          copyText: '你好',
          expanded: true,
          onToggle: () {},
        ),
      ),
    );

    final pill = _byLabel('复制');
    expect(pill, isSemantics(isButton: true, hasTapAction: true));
  });

  testWidgets('命令卡（折叠行）：多行 ⇒ 按钮；单行 ⇒ 不是按钮', (tester) async {
    await tester.pumpWidget(
      _host(
        const CommandCard(
          name: '/goal',
          status: ToolCallStatus.completed,
          summary: '已设定目标',
          detail: '第一行\n第二行',
        ),
      ),
    );
    expect(
      _byLabel(RegExp('/goal')),
      isSemantics(isButton: true, hasTapAction: true),
    );

    // 单行文本已经在摘要里了：DSH 的 `text.includes('\n') ? text : null`，
    // 再给一个箭头是骗人点。
    await tester.pumpWidget(
      _host(
        const CommandCard(
          name: '/goal',
          status: ToolCallStatus.completed,
          summary: '已设定目标',
          detail: '第一行',
        ),
      ),
    );
    expect(_byLabel(RegExp('/goal')), isNot(isSemantics(isButton: true)));
  });
}
