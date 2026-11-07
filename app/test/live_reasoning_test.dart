/// 流式思考的渲染：折叠行 + 「最后完成段落首行」摘要 + 思考不进正文。
///
/// ## 这一组守什么
///
/// 2026-11-07 的真机症状：生成中满屏是**思考**，而且找不到可点的折叠行 ——
/// 因为宿主的 `reasoning-delta` 被当成正文累加进了同一条流
/// （`core/live_message.dart` 的文件头）。这一组钉三件事：
///
/// 1. 摘要取**最后一个已完成段落**的首行（DSH `ReasoningRow.tsx:17-33`）；
/// 2. 流式条目里思考与正文是**两段**，思考只在折叠行里；
/// 3. 两段都空时才说「正在生成…」。
library;

import 'package:dsh_mobile/core/live_message.dart';
import 'package:dsh_mobile/ui/chat_turns.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 带小数的 DSH 应用壳（`DshColors` / `DshType` 都要 theme）。
Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: child,
        ),
      ),
    ),
  );
}

void main() {
  group('latestCompletedParagraphFirstLine（DSH ReasoningRow.tsx:17-33）', () {
    test('取最后一个已完成段落的首行，而不是第一行', () {
      const reasoning = '开场先想想。\n\n第二段：查了 A 与 B。\n\n第三段还在写';
      expect(latestCompletedParagraphFirstLine(reasoning), '第三段还在写');
    });

    test('末尾段落也参与（流式时它通常还没写完）', () {
      expect(latestCompletedParagraphFirstLine('第一段\n\n第二段'), '第二段');
    });

    test('只含空白的段落不覆盖已有摘要', () {
      expect(
        latestCompletedParagraphFirstLine('有内容的段落\n\n   \n\n\n'),
        '有内容的段落',
      );
    });

    test('没有空行时就是首行', () {
      expect(latestCompletedParagraphFirstLine('一句话的思考'), '一句话的思考');
      expect(latestCompletedParagraphFirstLine('第一行\n第二行'), '第一行');
    });

    test('CRLF 与只含制表符的空行也算段落分隔', () {
      expect(latestCompletedParagraphFirstLine('第一段\r\n\r\n第二段\r\n'), '第二段');
      expect(latestCompletedParagraphFirstLine('第一段\n\t\n第二段'), '第二段');
    });
  });

  group('LiveAssistantTurn', () {
    testWidgets('只有思考：出现「思考过程」折叠行，不出现"正在生成…"', (tester) async {
      await _pump(
        tester,
        const LiveAssistantTurn(LiveMessage(reasoning: '第一段思考。\n\n第二段思考。')),
      );
      expect(find.text('思考过程'), findsOneWidget);
      expect(find.text('正在生成…'), findsNothing);
      // 收起态的摘要 = 最后完成段落的首行。
      expect(find.text('第二段思考。'), findsOneWidget);
    });

    testWidgets('思考与正文分两段：正文照常渲染', (tester) async {
      await _pump(
        tester,
        const LiveAssistantTurn(
          LiveMessage(reasoning: '想好了。', text: '这是回答正文。'),
        ),
      );
      expect(find.text('思考过程'), findsOneWidget);
      expect(find.textContaining('这是回答正文', findRichText: true), findsOneWidget);
    });

    testWidgets('两段都空：说「正在生成…」', (tester) async {
      await _pump(tester, const LiveAssistantTurn(LiveMessage()));
      expect(find.text('正在生成…'), findsOneWidget);
      expect(find.text('思考过程'), findsNothing);
    });

    testWidgets('点开思考行：完整思考才出现', (tester) async {
      const reasoning = '第一段：先看现状。\n\n第二段：再定方案。';
      await _pump(
        tester,
        const LiveAssistantTurn(LiveMessage(reasoning: reasoning)),
      );
      // 收起时正文一个字都不在树里。
      expect(find.textContaining('第一段', findRichText: true), findsNothing);

      await tester.tap(find.text('思考过程'));
      await tester.pumpAndSettle();

      expect(find.textContaining('第一段', findRichText: true), findsOneWidget);
      expect(find.textContaining('第二段', findRichText: true), findsOneWidget);
    });
  });
}
