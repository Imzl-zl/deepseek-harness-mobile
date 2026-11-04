/// 粘顶（DSH 的 `position: sticky`）：展开的思考行标题钉在列表顶部。
///
/// 判据三条：
/// 1. 标题滚出视口顶、正文还在视口里 ⇒ 顶部多一份标题；
/// 2. 点顶部那份 ⇒ 折叠（正文消失、钉住的那份也消失）；
/// 3. 标题还在视口里 ⇒ **不**多画一份（否则同一行出现两次）。
///
/// Note: 为什么不是 sliver 重构 —— 见 `ui/sticky_note.dart` 的文件头。
library;

import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_turns.dart';
import 'package:dsh_mobile/ui/dsh_markdown.dart';
import 'package:dsh_mobile/ui/sticky_note.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _stickyKey = ValueKey('sticky-note-header');

/// 够长的思考正文（25 行，超过 600 的测试视口）。
const _long =
    '第一行思考\n第二行\n第三行\n第四行\n第五行\n第六行\n第七行\n第八行\n'
    '第九行\n第十行\n第十一行\n第十二行\n第十三行\n第十四行\n第十五行\n'
    '第十六行\n第十七行\n第十八行\n第十九行\n第二十行\n第二十一行\n'
    '第二十二行\n第二十三行\n第二十四行\n第二十五行';

Widget _host(Widget child) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(body: StickyNoteHost(child: child)),
);

Widget _list() => ListView(
  children: const [
    SizedBox(height: 120),
    ReasoningRow(text: _long),
    SizedBox(height: 2000),
  ],
);

void main() {
  testWidgets('滚过标题后，标题钉在顶部；点它折叠', (tester) async {
    await tester.pumpWidget(_host(_list()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();
    expect(find.byType(DshMarkdown), findsOneWidget, reason: '展开后正文在');

    // 往上滚 200：标题（原本 y=120）滚出视口顶，正文还在视口里。
    await tester.dragFrom(const Offset(400, 40), const Offset(0, -200));
    await tester.pumpAndSettle();

    expect(find.byKey(_stickyKey), findsOneWidget, reason: '该钉住了');
    expect(find.text('思考过程'), findsNWidgets(2), reason: '行里一份 + 顶部一份');

    // 点钉住的那一份 ⇒ 折叠。
    await tester.tap(find.byKey(_stickyKey));
    await tester.pumpAndSettle();
    expect(find.byType(DshMarkdown), findsNothing, reason: '正文要收起');
    expect(find.byKey(_stickyKey), findsNothing, reason: '收起后不该还钉着');
  });

  testWidgets('标题还在视口里时不钉（不多画一行）', (tester) async {
    await tester.pumpWidget(_host(_list()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();

    // 还没滚：标题就在眼前，钉一份等于同一行出现两次。
    expect(find.byKey(_stickyKey), findsNothing);
    expect(find.text('思考过程'), findsOneWidget);
  });

  testWidgets('收起之后不再钉（登记随收起注销）', (tester) async {
    await tester.pumpWidget(_host(_list()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(400, 40), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(find.byKey(_stickyKey), findsOneWidget);

    // 滚回顶部再点行标题收起。
    await tester.dragFrom(const Offset(400, 40), const Offset(0, 200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();

    expect(find.byKey(_stickyKey), findsNothing);
    expect(find.byType(DshMarkdown), findsNothing);
  });
}
