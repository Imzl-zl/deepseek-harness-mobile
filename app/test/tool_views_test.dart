/// 每步视图：解析（`model/tool_view.dart`）+ diff（`model/diff.dart`）+ 渲染。
///
/// ## 这一组守什么
///
/// 1. **解析要按真日志的形状**：`read` 用 `app/test/fixtures/real-session-events.json`
///    里那一帧真事件（`data.meta = {path, offset, lines[], totalLines}`）；
///    `bash` 按 `packages/shell/tool-bash/src/render.ts:52-61` 写出来的标记解析；
///    `edit/write` 按 `packages/fs/tool-fs/src/edit.ts:113-117` 的 `{path, diffs}`。
/// 2. **`+N −M` 按折出来的 diff 算**，不是按两段文本的总行数（`{a,b}`→`{a,c}` 是 +1 −1）。
/// 3. 三个视图都能画出来（`ToolCard` 展开后是专用正文，不是原文）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/model/diff.dart';
import 'package:dsh_mobile/model/tool_view.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_turns.dart';
import 'package:dsh_mobile/ui/dsh_diff.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真机落盘的一帧 `tool/result`（read）。
Map<String, Object?> _realReadResult() {
  final raw = File('test/fixtures/real-session-events.json').readAsStringSync();
  final fixture = jsonDecode(raw) as Map<String, Object?>;
  final result = fixture['toolResult'] as Map<String, Object?>;
  return result['data'] as Map<String, Object?>;
}

void main() {
  group('read：用真日志那一帧', () {
    test('解析出 path / 行号 / 总行数', () {
      final view = toolResultViewOf(name: 'read', data: _realReadResult());
      expect(view, isA<ReadResultView>());
      final read = view! as ReadResultView;
      expect(read.path, endsWith('memory.md'));
      expect(read.lines, isNotEmpty);
      expect(read.lines.first.number, 1);
      expect(read.lines.first.text, startsWith('# dsh-mobile'));
      expect(read.totalLines, greaterThan(100));
      expect(read.offset, 1);
    });

    test('没有结构化窗口 ⇒ 不装作有行号（退回通用卡）', () {
      expect(toolResultViewOf(name: 'read', data: const {}), isNull);
    });
  });

  group('bash：状态在文本末尾的标记里', () {
    BashResultView parse(String text) =>
        toolResultViewOf(
              name: 'bash',
              data: <String, Object?>{
                'meta': <String, Object?>{'cwd': '/w'},
                'message': <String, Object?>{
                  'content': [
                    {'type': 'text', 'text': text},
                  ],
                },
              },
            )!
            as BashResultView;

    test('正常退出：没有标记就是 exit 0', () {
      final view = parse('done');
      expect(view.output, 'done');
      expect(view.exitCode, 0);
      expect(view.ok, isTrue);
    });

    test('非零退出：标记被剥掉、码进 pill', () {
      final view = parse('boom\n[exit code: 3]');
      expect(view.output, 'boom');
      expect(view.exitCode, 3);
      expect(view.ok, isFalse);
    });

    test('stderr 段切出来（`render.ts:36-40` 的 `[stderr]` 分隔）', () {
      final view = parse('out\n[stderr]\nwarn: x');
      expect(view.output, 'out');
      expect(view.stderr, 'warn: x');
    });

    test('被杀 / 超时：保留原文，不当成 exit 0', () {
      final killed = parse('x\n[killed by signal: SIGTERM]');
      expect(killed.signal, 'SIGTERM');
      expect(killed.ok, isFalse);
      final timedOut = parse('x\n[timed out after 1000ms]\n[exit code: 1]');
      expect(timedOut.marker, '[timed out after 1000ms]');
      expect(timedOut.exitCode, 1);
    });
  });

  group('edit / write：+N −M 按折出来的 diff 算', () {
    test('一增一删不是两增两删', () {
      final view =
          toolResultViewOf(
                name: 'edit',
                data: <String, Object?>{
                  'meta': <String, Object?>{
                    'path': 'a.txt',
                    'diffs': [
                      {'path': 'a.txt', 'oldText': 'a\nb', 'newText': 'a\nc'},
                    ],
                  },
                  'message': <String, Object?>{
                    'content': [
                      {'type': 'text', 'text': 'ok'},
                    ],
                  },
                },
              )!
              as DiffResultView;
      expect(view.path, 'a.txt');
      expect(view.added, 1);
      expect(view.removed, 1);
      expect(view.operation, isNull, reason: 'edit 没有 operation');
    });

    test('write 带 operation', () {
      final view =
          toolResultViewOf(
                name: 'write',
                data: <String, Object?>{
                  'meta': <String, Object?>{
                    'operation': 'create',
                    'path': 'b.txt',
                    'diffs': [
                      {'path': 'b.txt', 'oldText': '', 'newText': 'x\ny'},
                    ],
                  },
                },
              )!
              as DiffResultView;
      expect(view.operation, 'create');
      expect(view.added, 2);
      expect(view.removed, 0);
    });
  });

  group('diff：先剥公共前后缀，再按 LCS 配对', () {
    test('中间一行改动：前缀与后缀都是上下文，行号两列都在', () {
      final lines = diffLinesOf('a\nb\nc', 'a\nB\nc');
      expect(lines.map((l) => l.kind), [
        DiffKind.context,
        DiffKind.del,
        DiffKind.add,
        DiffKind.context,
      ]);
      final del = lines[1];
      expect(del.text, 'b');
      expect(del.oldLine, 2);
      expect(del.newLine, isNull);
      final add = lines[2];
      expect(add.text, 'B');
      expect(add.newLine, 2);
    });

    test('纯插入：只多一行 add，上下文行号对齐', () {
      final lines = diffLinesOf('a\nc', 'a\nb\nc');
      expect(lines.map((l) => l.kind), [
        DiffKind.context,
        DiffKind.add,
        DiffKind.context,
      ]);
      expect(lines[1].text, 'b');
      expect(lines[1].newLine, 2);
      expect(lines[2].newLine, 3);
    });

    test('两边都空 ⇒ 没有行（不是一行空串）', () {
      expect(diffLinesOf('', ''), isEmpty);
    });
  });

  group('渲染：ToolCard 展开后是专用正文', () {
    Widget host(Widget child) => MaterialApp(
      theme: DshTheme.dark(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

    testWidgets('bash：输出 + exit pill', (tester) async {
      final view = toolResultViewOf(
        name: 'bash',
        data: <String, Object?>{
          'message': <String, Object?>{
            'content': [
              {'type': 'text', 'text': 'boom\n[exit code: 3]'},
            ],
          },
        },
      )!;
      await tester.pumpWidget(
        host(
          ToolCard(
            name: 'bash',
            status: ToolCallStatus.completed,
            argument: 'run it',
            view: view,
            initiallyOpen: true,
          ),
        ),
      );
      expect(find.text('boom'), findsOneWidget);
      expect(find.text('exit 3'), findsOneWidget);
    });

    testWidgets('read：行号 + 文本', (tester) async {
      final view = toolResultViewOf(name: 'read', data: _realReadResult())!;
      await tester.pumpWidget(
        host(
          ToolCard(
            name: 'read',
            status: ToolCallStatus.completed,
            argument: 'memory.md',
            view: view,
            initiallyOpen: true,
          ),
        ),
      );
      expect(find.text('1'), findsOneWidget, reason: '第一行的行号');
      expect(
        find.textContaining('# dsh-mobile'),
        findsWidgets,
        reason: '第一行的文本',
      );
    });

    testWidgets('edit：+N −M 与 diff 行', (tester) async {
      final view = toolResultViewOf(
        name: 'edit',
        data: <String, Object?>{
          'meta': <String, Object?>{
            'path': 'a.txt',
            'diffs': [
              {'path': 'a.txt', 'oldText': 'a\nb', 'newText': 'a\nc'},
            ],
          },
        },
      )!;
      await tester.pumpWidget(
        host(
          ToolCard(
            name: 'edit',
            status: ToolCallStatus.completed,
            argument: 'a.txt',
            view: view,
            initiallyOpen: true,
          ),
        ),
      );
      expect(find.text('+1'), findsOneWidget);
      expect(find.text('−1'), findsOneWidget);
      expect(find.text('b'), findsOneWidget);
      expect(find.text('c'), findsOneWidget);
    });
  });
}
