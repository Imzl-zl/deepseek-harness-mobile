/// 计划审查卡：**卡来自请求**（`exit_plan_mode` 的 `tool/call`），不在投影里等一个锚点。
///
/// ## 这一组守什么
///
/// 1. `exit_plan_mode` 的 `tool/call` 事件要造出一张 `InteractionKind.plan` 卡：
///    身份 `t:<callId>`（与连接器 claim 的 `intent.callId` 同一个值）、
///    正文 = 参数里的整份计划、标题 = 计划第一个 markdown 标题。
/// 2. 「同意执行」发出的答复是 `{itemId: 't:call-plan', answers: [{id: 't:call-plan',
///    selected: ['plan-approve']}]}` —— 这里只是**标记**：宿主的题 id 与标签在请求里，
///    由连接器按请求重写（`kPlanApproveMark` 的注释、契约 §6.3.1）。
library;

import 'package:dsh_mobile/data/projection.dart';
import 'package:dsh_mobile/model/interaction.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/takeover.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

/// 一条 `exit_plan_mode` 的 `tool/call`（形状照 `plan-mode/src/index.ts:283-284`）。
Map<String, Object?> planCall(String callId, String plan) => {
  'name': 'exit_plan_mode',
  'callId': callId,
  'arguments': {'plan': plan},
};

const _plan = '# 重构输入栏\n\n1. 把候选抽成一层\n2. 收口三态\n';

/// 一张真形状的计划卡（投影造出来的就是这一份）。
InteractionItem _planItem() => const InteractionItem(
  itemId: 't:call-plan',
  sid: 'sid-1',
  callId: 'call-plan',
  kind: InteractionKind.plan,
  title: '重构输入栏',
  detail: _plan,
  approveLabel: kPlanApproveMark,
);

void main() {
  group('投影：计划卡从 tool/call 造', () {
    test('认得出 exit_plan_mode ⇒ plan 卡，正文是整份计划、标题取第一个标题', () {
      final signal = interactionSignalOf(
        type: 'tool/call',
        seq: 1,
        data: planCall('call-plan', _plan),
      );
      expect(signal, isA<InteractionOpened>());
      final item = (signal as InteractionOpened).item;
      expect(item.kind, InteractionKind.plan);
      expect(
        item.itemId,
        't:call-plan',
        reason: '与连接器 claim 的 intent.callId 同一个身份',
      );
      expect(item.detail, _plan, reason: '正文就是参数里的整份计划，一个字都不改');
      expect(item.title, '重构输入栏');
      expect(item.approveLabel, kPlanApproveMark);
    });

    test('没有 plan 参数 / 没有 callId ⇒ 不开卡（宁可留给工具行，不造半张卡）', () {
      expect(
        interactionSignalOf(
          type: 'tool/call',
          seq: 1,
          data: const {
            'name': 'exit_plan_mode',
            'callId': 'call-1',
            'arguments': {},
          },
        ),
        isNull,
      );
      expect(
        interactionSignalOf(
          type: 'tool/call',
          seq: 1,
          data: const {
            'name': 'exit_plan_mode',
            'arguments': {'plan': '# 计划'},
          },
        ),
        isNull,
      );
    });

    test('第一个标题的读法与宿主一致（1–6 个 #，取正文）；没有标题就 null', () {
      expect(firstHeadingOf('前言\n## 第二步：改投影\n正文'), '第二步：改投影');
      expect(firstHeadingOf('   \n# 一\n'), '一');
      expect(firstHeadingOf('没有标题的计划'), isNull);
    });
  });

  group('答复载荷', () {
    test('「同意执行」⇒ selected 带标记；「要求修改」⇒ 空 selected', () async {
      // 一次决定撤一张卡，所以两种结局各起一个控制器（同一个 itemId 的形状）。
      Future<InteractionAnswer?> decide(bool approved) async {
        final out = <InteractionAnswer>[];
        final controller = TakeoverController()
          ..onAnswer = (answer) async => out.add(answer);
        addTearDown(controller.dispose);
        controller.setCurrentSid('sid-1');
        controller.enqueue(_planItem());
        await controller.settlePlan(approved: approved);
        return out.isEmpty ? null : out.single;
      }

      final approvedAnswer = await decide(true);
      expect(approvedAnswer, isNotNull);
      expect(approvedAnswer!.itemId, 't:call-plan');
      expect(approvedAnswer.answers.single.id, 't:call-plan');
      expect(approvedAnswer.answers.single.selected, [kPlanApproveMark]);
      expect(approvedAnswer.answers.single.custom, isNull);

      final declinedAnswer = await decide(false);
      expect(declinedAnswer, isNotNull);
      expect(declinedAnswer!.answers.single.selected, isEmpty);
    });

    testWidgets('卡上看得见计划正文与两个按钮（标签是手机上那两句）', (tester) async {
      final controller = TakeoverController()..onAnswer = (_) async {};
      addTearDown(controller.dispose);
      controller.setCurrentSid('sid-1');
      controller.enqueue(_planItem());
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: TakeoverPanel(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('等待确认计划'), findsOneWidget);
      expect(find.textContaining('把候选抽成一层'), findsOneWidget, reason: '正文要看得见');
      expect(find.text('同意执行'), findsOneWidget);
      expect(find.text('要求修改'), findsOneWidget);
    });
  });
}
