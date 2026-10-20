/// 斜杠命令卡（`command/run` + `command/done`）的回归。
///
/// ## 这一组守什么
///
/// 2026-10-19 摸到的"没有输出"之一：`command/run` / `command/done` 在投影里
/// **没有 case**，一路落到 `OtherItem`（只计数、不渲染）。于是 `/goal`、
/// `/compact`、`/permission` 这些在 DSH Web 上有"命令名 + 结果文本"卡片的
/// 东西，在手机上**一条都没有**。
///
/// ## 判据从哪来
///
/// **真日志**：`~/.dsh/sessions/--D-sudy-myproject-dsh-mobile--/
/// session-1f80f156-…/session.v4.jsonl.zstd` 里那条 `/goal`（本会话自己的
/// goal 创建命令）。形状是：
///
/// ```json
/// {"type":"command/run","seq":3,"data":{
///    "commandId":"cmd-532bbefe-1","name":"goal","args":" 首先我要睡觉了…",
///    "source":{"kind":"user"}}}
/// {"type":"command/done","seq":8,"data":{
///    "commandId":"cmd-532bbefe-1","kind":"success","text":"Goal created\n…"}}
/// ```
///
/// DSH 的格式不变量（`session-format-v3-to-v4/README.md:244`）原话：
/// "Run ids are unique; completion has a prior run" —— 配对靠 `commandId`。
library;

import 'package:dsh_mobile/core/items.dart';
import 'package:dsh_mobile/data/projection.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/theme/dsh_icons.dart';
import 'package:dsh_mobile/ui/chat_turns.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真日志里的 `command/run`（本会话的 goal 创建命令；args 截断显示）。
const _runEvent = <String, Object?>{
  'type': 'command/run',
  'seq': 3,
  'time': 1792342400869,
  'data': <String, Object?>{
    'commandId': 'cmd-532bbefe-1',
    'name': 'goal',
    'args': ' 首先我要睡觉了，有问题你自行结合项目综合分析判断',
    'source': <String, Object?>{'kind': 'user'},
  },
};

/// 真日志里的 `command/done`（`text` 是多段：摘要取第一行，明细取全文）。
const _doneEvent = <String, Object?>{
  'type': 'command/done',
  'seq': 8,
  'time': 1792342400892,
  'data': <String, Object?>{
    'commandId': 'cmd-532bbefe-1',
    'kind': 'success',
    'text': 'Goal created\nStatus: active\nObjective: 首先我要睡觉了…',
  },
};

void main() {
  group('command/run → CommandItem', () {
    test('名字补前导斜杠、状态 running、摘要带参数', () {
      final result = projectEvent(
        type: 'command/run',
        seq: 3,
        data: _runEvent['data'],
        time: 1792342400869,
      );
      final item = result.item;
      expect(item, isA<CommandItem>());
      final command = item as CommandItem;
      // 名字补斜杠：DSH 的 `name` 是用户在输入框敲的那串（`goal`），
      // 而卡片标题要读起来就是"一条命令"。
      expect(command.name, '/goal');
      expect(command.status, ToolCallStatus.running);
      // 摘要是参数（DSH 的卡片标题只有命令名，参数进摘要行）。
      expect(command.summary, '首先我要睡觉了，有问题你自行结合项目综合分析判断');
    });

    test('没有参数时摘要说"正在执行…"', () {
      final result = projectEvent(
        type: 'command/run',
        seq: 3,
        data: const <String, Object?>{
          'commandId': 'cmd-1',
          'name': 'compact',
          'args': '  ',
          'source': <String, Object?>{'kind': 'user'},
        },
      );
      expect((result.item as CommandItem).summary, kCommandRunningSummary);
    });
  });

  group('command/done 覆盖 command/run（同一 itemId）', () {
    test('名字从 run 继承、状态 completed、摘要取首行、明细取全文', () {
      final run = projectEvent(
        type: 'command/run',
        seq: 3,
        data: _runEvent['data'],
      );
      final done = projectEvent(
        type: 'command/done',
        seq: 8,
        data: _doneEvent['data'],
        previous: run.item,
      );
      final command = done.item as CommandItem;

      // **同一个 itemId**（配对靠 commandId，见 `core/items.dart`）——
      // 所以 done 是"更新"，不是新增一条。
      expect(command.itemId, run.item!.itemId);
      // 名字从 run 继承：`command/done` **不带 name**（真日志实测）。
      expect(command.name, '/goal');
      expect(command.status, ToolCallStatus.completed);
      // 摘要 = 结果文本第一行（手机上摘要只能一行）。
      expect(command.summary, 'Goal created');
      // 明细 = 全文（多行，展开才看得见）。
      expect(
        command.detail,
        'Goal created\nStatus: active\nObjective: 首先我要睡觉了…',
      );
    });

    test('kind 是 error 时状态 failed', () {
      final run = projectEvent(
        type: 'command/run',
        seq: 3,
        data: _runEvent['data'],
      );
      final done = projectEvent(
        type: 'command/done',
        seq: 8,
        data: const <String, Object?>{
          'commandId': 'cmd-532bbefe-1',
          'kind': 'error',
          'text': 'unknown command: /nope',
        },
        previous: run.item,
      );
      final command = done.item as CommandItem;
      expect(command.status, ToolCallStatus.failed);
      expect(command.summary, 'unknown command: /nope');
    });

    test('历史翻页只落到 done（run 在窗口外）：留"命令"，不编一个', () {
      final done = projectEvent(
        type: 'command/done',
        seq: 8,
        data: _doneEvent['data'],
        previous: null,
      );
      expect((done.item as CommandItem).name, kUnknownCommandName);
    });
  });

  group('itemId 配对', () {
    test('run 与 done 推导出同一个 id', () {
      final runId = itemIdOf(
        EventLike(type: 'command/run', seq: 3, data: _runEvent['data']),
      );
      final doneId = itemIdOf(
        EventLike(type: 'command/done', seq: 8, data: _doneEvent['data']),
      );
      expect(doneId, runId);
      expect(runId, 'c:cmd-532bbefe-1');
    });

    test('缺 commandId 时抛错（不静默退化成 <type>:<seq>）', () {
      expect(
        () => itemIdOf(
          const EventLike(
            type: 'command/done',
            seq: 8,
            data: <String, Object?>{'kind': 'success'},
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('真事件 → 投影 → 渲染（三段贯通）', () {
    testWidgets('命令名、摘要、明细都在卡片上；多行才给展开', (tester) async {
      // 真日志那一对事件先过投影，再把结果喂给卡片 —— 不是手搓一个
      // `CommandItem`（那只会复述实现的假设，见 memory.md 教训 1）。
      final run = projectEvent(
        type: 'command/run',
        seq: 3,
        data: _runEvent['data'],
      );
      final done = projectEvent(
        type: 'command/done',
        seq: 8,
        data: _doneEvent['data'],
        previous: run.item,
      );
      final command = done.item as CommandItem;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: CommandCard(
              name: command.name,
              status: command.status,
              summary: command.summary,
              detail: command.detail,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 命令名（补了斜杠）。
      expect(find.text('/goal'), findsOneWidget);
      // 摘要 = 结果文本第一行。
      expect(find.text('Goal created'), findsOneWidget);
      // 多行明细才给展开箭头（DSH `GenericCommandCard.tsx:40`）。
      expect(
        tester.widgetList<DshIcon>(find.byType(DshIcon)).map((w) => w.name),
        contains('chevronRight'),
      );
      // 点开才看得见全文。
      await tester.tap(find.text('Goal created'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Status: active'), findsOneWidget);
      // 展开后摘要**仍在**（DSH 的 `keepContentWhenOpen`）。
      expect(find.text('Goal created'), findsOneWidget);

      // 正文照 `.body`（`GenericCommandCard.module.css:38-49`）：
      // 11/16 等宽、上限 260、`label-primary`（不是 layer1 卡片 + 12.5 等宽）。
      final body = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(body.style!.fontSize, 11);
      expect(body.style!.height, closeTo(16 / 11, 1e-9));
      final box = tester.widget<ConstrainedBox>(
        find
            .ancestor(
              of: find.byType(SelectableText),
              matching: find.byType(ConstrainedBox),
            )
            .first,
      );
      expect(box.constraints.maxHeight, 260);
    });

    testWidgets('单行结果不给展开（DSH 的 includes(\\n) 判据）', (tester) async {
      final done = projectEvent(
        type: 'command/done',
        seq: 8,
        data: const <String, Object?>{
          'commandId': 'cmd-532bbefe-1',
          'kind': 'success',
          'text': 'unknown command: /nope',
        },
      );
      final command = done.item as CommandItem;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: CommandCard(
              name: command.name,
              status: command.status,
              summary: command.summary,
              detail: command.detail,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 单行 ⇒ 没有展开箭头 ⇒ 点行什么都不发生（不是"展开了但空的"）。
      expect(find.text('unknown command: /nope'), findsOneWidget);
      expect(
        tester.widgetList<DshIcon>(find.byType(DshIcon)).map((w) => w.name),
        isNot(contains('chevronRight')),
        reason: '单行结果不该摆一个骗人点的箭头',
      );
    });
  });
}
