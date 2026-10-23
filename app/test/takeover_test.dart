/// 输入栏接管（`ui/takeover.dart`）的回归。
///
/// 照 `mock/proto/interactions.js` 的 `Takeovers`。
///
/// ## 三条语义是**从原型抄的**，不是我自己定的
///
/// 1. **"允许一次" = `allowed-once`**，不是权限变更。原型里
///    `settleApproval(item, 'allowed-once')` 与 `'rejected'` 是两个结果值，
///    而权限档位（`perm`）是另一套东西。**混起来会让"点了一次允许"变成永久放权**。
/// 2. **`fullAccess` 下审批不入队**（原型 `enqueue` 的第一条分支）——
///    那是"已授权"的结果，不是绕过。
/// 3. **队列是瀑布**：一次只处理队首（原型注释
///    `const queue = [] // 待处理队列(瀑布:一次只处理队首)`）。
///    不铺成列表是因为审批要**逐个看** —— 一次批准五件事等于没看。
/// 4. **一个会话一队**（2026-10-13 起，对齐 DSH 原生）：待处理带 `sid`，
///    切到哪个会话就看哪个会话的队；另一个会话的待处理不插到眼前，
///    由"其他会话还有待处理"的一行提示照应（见文件末尾那个组）。
library;

import 'dart:async';

import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/takeover.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

InteractionItem approval(
  String key, {
  String tool = 'bash',
  String sid = 'sid-1',
}) => InteractionItem(
  itemId: key,
  sid: sid,
  callId: 'call-$key',
  kind: InteractionKind.approval,
  toolName: tool,
  title: '工具 $tool 请求越权执行',
);

InteractionItem question(String key, {String sid = 'sid-1'}) => InteractionItem(
  itemId: key,
  sid: sid,
  callId: 'call-$key',
  kind: InteractionKind.question,
  title: '选哪个？',
  questions: const [
    InteractionQuestion(
      id: 'q1',
      question: '选哪个？',
      options: [
        InteractionOption(label: '甲'),
        InteractionOption(label: '乙', description: '乙的说明'),
      ],
    ),
  ],
);

/// 计划审查（优先级 2，队首）。**真实事件里不会出现这一类** —— 见
/// `InteractionKind.plan` 的说明；这里只为钉优先级而造。
InteractionItem plan(String key, {String sid = 'sid-1'}) => InteractionItem(
  itemId: key,
  sid: sid,
  callId: 'call-$key',
  kind: InteractionKind.plan,
  title: '计划：迁移到 v2',
  approveLabel: '同意执行',
);

/// 回归用的控制器：**设好当前会话**。
///
/// 2026-10-13 起队列按 sid 分桶（对齐 DSH 的 per-session 待处理），
/// 不设当前会话就一个桶都看不见。这些回归用例判的是"一队之内的行为"
/// （瀑布、允许一次、多题向导……），所以统一在这条口子上设成 'sid-1'，
/// 判据一行不用改。多会话的新判据在文件末尾那个组里。
TakeoverController _controllerFor([String sid = 'sid-1']) {
  final c = TakeoverController();
  c.setCurrentSid(sid);
  return c;
}

Widget _wrap(TakeoverController c) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: TakeoverPanel(controller: c),
    ),
  ),
);

void main() {
  group('队列（瀑布：一次只处理队首）', () {
    test('入队两个审批，`active` 是第一个', () {
      final c = _controllerFor();
      c.enqueue(approval('a1'));
      c.enqueue(approval('a2'));
      expect(c.active?.itemId, 'a1');
      expect(c.queue.length, 2);
    });

    test('答完队首，下一个自动成为 active', () async {
      final c = _controllerFor();
      c.enqueue(approval('a1'));
      c.enqueue(approval('a2'));
      await c.allowOnce();
      expect(c.active?.itemId, 'a2');
      expect(c.queue.length, 1);
    });

    test('同一个 key 不重复入队（收起后重开走 restore 而不是再入一次）', () {
      final c = _controllerFor();
      c.enqueue(approval('a1'));
      c.minimize();
      c.enqueue(approval('a1'));
      expect(c.queue.length, 1);
      expect(c.phase, TakeoverPhase.active, reason: '重入同一个 key 应顺带恢复显示');
    });
    test('空队列时 phase 是 idle（输入栏正常）', () {
      expect(_controllerFor().phase, TakeoverPhase.idle);
    });
  });

  group('「允许一次」的语义（不能变成永久放权）', () {
    test('allowOnce 的回执写的是 `allowed-once`，不是权限档位', () async {
      final c = _controllerFor();
      c.enqueue(approval('a1'));
      await c.allowOnce();
      expect(c.receipts.single.text, contains('allowed-once'));
      expect(
        c.receipts.single.text,
        contains('允许一次'),
        reason: '文案要写"允许一次" —— 用户看到的必须是这个',
      );
      // **没有改任何权限档**：控制器里唯一与权限有关的是 `fullAccess`，
      // 而它不该被这次点击动到。
      expect(c.fullAccess, isFalse, reason: '允许一次不该把权限改成完全权限');
    });

    test('拒绝的回执是 `rejected`', () async {
      final c = _controllerFor();
      c.enqueue(approval('a1'));
      await c.reject();
      expect(c.receipts.single.text, contains('rejected'));
    });

    test('下一次审批仍然要授权（一次就是一次）', () async {
      final c = _controllerFor();
      c.enqueue(approval('a1'));
      await c.allowOnce();
      c.enqueue(approval('a2'));
      expect(c.active?.itemId, 'a2', reason: '第二次仍要排队等授权');
      expect(c.phase, TakeoverPhase.active);
    });
  });

  group('fullAccess 下审批不入队（原型 enqueue 的第一条分支）', () {
    test('完全权限：审批返回 false、队列不变', () {
      final c = _controllerFor()..fullAccess = true;
      final queued = c.enqueue(approval('a1'));
      expect(queued, isFalse, reason: '未入队要如实返回 false');
      expect(c.queue, isEmpty);
      expect(c.phase, TakeoverPhase.idle);
    });

    test('完全权限**只影响审批** —— 提问与计划照常入队', () {
      final c = _controllerFor()..fullAccess = true;
      expect(c.enqueue(question('q1')), isTrue);
      expect(
        c.enqueue(
          const InteractionItem(
            itemId: 'p1',
            sid: 'sid-1',
            callId: 'call-p1',
            kind: InteractionKind.plan,
            title: '计划',
          ),
        ),
        isTrue,
      );
    });
  });

  group('提问', () {
    test('未回答时 `answered` 为假（提交键据此禁用）', () {
      final c = _controllerFor()..enqueue(question('q1'));
      expect(c.answered, isFalse);
    });

    test('选了选项 → answered 为真；单选再点同一个是取消', () {
      final c = _controllerFor()..enqueue(question('q1'));
      c.toggleOption('甲');
      expect(c.answered, isTrue);
      c.toggleOption('甲');
      expect(c.selected, isEmpty, reason: '单选再点同一个该退回"未选"（否则选错了没法退）');
      expect(c.answered, isFalse);
    });

    test('自定义答案也算回答', () {
      final c = _controllerFor()..enqueue(question('q1'));
      c.setCustom('我自己写一个');
      expect(c.answered, isTrue);
    });

    test('多选可以同时选两个', () {
      final c = _controllerFor();
      c.enqueue(
        const InteractionItem(
          itemId: 'q1',
          sid: 'sid-1',
          callId: 'call-q1',
          kind: InteractionKind.question,
          title: '多选',
          questions: [
            InteractionQuestion(
              id: 'q1',
              question: '多选',
              multiSelect: true,
              options: [
                InteractionOption(label: '甲'),
                InteractionOption(label: '乙'),
              ],
            ),
          ],
        ),
      );
      c.toggleOption('甲');
      c.toggleOption('乙');
      expect(c.selected, {'甲', '乙'});
    });

    test('未回答时提交是**无操作**（不推进队列）', () async {
      final c = _controllerFor()..enqueue(question('q1'));
      await c.submitQuestion();
      expect(c.queue.length, 1, reason: '没答就不能提交 —— 队列不减');
      expect(c.receipts, isEmpty);
    });

    test('答了才提交，且回执带答案', () async {
      final c = _controllerFor()..enqueue(question('q1'));
      c.toggleOption('乙');
      await c.submitQuestion();
      expect(c.receipts.single.text, contains('乙'));
      expect(c.queue, isEmpty);
    });
  });

  group('在途状态（原型 `item.busy`）', () {
    test('提交期间 phase 是 busy（按钮据此禁用）', () async {
      final c = _controllerFor()..enqueue(approval('a1'));
      final pending = c.allowOnce();
      expect(c.phase, TakeoverPhase.busy);
      await pending;
      expect(c.phase, TakeoverPhase.idle);
    });

    test('busy 期间重复点无效（只出一条回执）', () async {
      final c = _controllerFor()..enqueue(approval('a1'));
      final first = c.allowOnce();
      unawaited(c.reject()); // 在途时的第二次点击
      await first;
      expect(c.receipts.length, 1, reason: '在途期间只该有一次应答');
    });

    test('提交失败：不写成功回执、不撤卡、busy 复位（传输失败要能重试）', () async {
      final c = _controllerFor();
      c.onAnswer = (answer) async => throw Exception('断了');
      c.enqueue(approval('a1'));
      await c.allowOnce();
      expect(c.receipts, isEmpty, reason: '没发出去就不能写「已拒绝」回执');
      expect(c.queue.length, 1, reason: '卡还在：传输失败不是"这一项没了"');
      expect(c.phase, TakeoverPhase.active, reason: 'busy 必须复位，否则卡片永远点不了');
    });
  });

  group('收起与恢复', () {
    test('收起后 phase 是 minimized（对话流里留一行提示）', () {
      final c = _controllerFor()..enqueue(approval('a1'));
      c.minimize();
      expect(c.phase, TakeoverPhase.minimized);
      expect(c.queue.length, 1, reason: '收起**不等于**回答 —— 它还在队列里');
    });

    test('恢复后回到 active', () {
      final c = _controllerFor()..enqueue(approval('a1'));
      c.minimize();
      c.restore();
      expect(c.phase, TakeoverPhase.active);
    });
  });

  group('答复出口（`interaction.respond`，契约 §5.7）', () {
    test('审批"允许一次"发的是 `allowed-once` 标签；"拒绝"发空 selected', () async {
      // 标签本身用**字面值**断（下面那条），这里断的是行为。
      expect(approvalAllowLabel, 'allowed-once', reason: '跨端契约的那个字符串');
      final sent = <InteractionAnswer>[];
      final c = _controllerFor()..onAnswer = (answer) async => sent.add(answer);

      c.enqueue(approval('a1'));
      await c.allowOnce();
      expect(
        sent.single.itemId,
        'a1',
        reason: '答复的键是卡自己的 itemId（连接器的 claim 也以它为准）',
      );
      expect(
        sent.single.answers.single.id,
        'a1',
        reason: '审批的答案项 id 只要非空；身份已经在 itemId 上',
      );
      expect(
        sent.single.answers.single.selected,
        // **字面值，不 import 常量**：这条断言钉的是"跨端契约的那个字符串"，
        // 用同一个常量来断等于恒真（改常量两边一起改，红不了）。
        const ['allowed-once'],
        reason: 'DSH 的 outcome 词汇表里唯一授权值是 allowed-once',
      );

      c.enqueue(approval('a2'));
      await c.reject();
      expect(
        sent.last.answers.single.selected,
        isEmpty,
        reason: '空 selected 且无 custom 是合法的「显式跳过」，对审批就是拒绝',
      );
    });

    test('提问的答案批次**原样转发**：每个问题恰好一项', () async {
      final sent = <InteractionAnswer>[];
      final c = _controllerFor()..onAnswer = (answer) async => sent.add(answer);
      c.enqueue(
        const InteractionItem(
          itemId: 'q1',
          sid: 'sid-1',
          callId: 'call-q1',
          kind: InteractionKind.question,
          title: '两题',
          questions: [
            InteractionQuestion(
              id: 'scope',
              question: '选范围',
              multiSelect: true,
              options: [
                InteractionOption(label: '全部'),
                InteractionOption(label: '只读'),
              ],
            ),
            InteractionQuestion(id: 'note', question: '补充'),
          ],
        ),
      );

      // 第一题：多选两个。
      c.toggleOption('全部');
      c.toggleOption('只读');
      await c.submitQuestion();
      expect(c.questionIndex, 1, reason: '还有一题：提交键在这一题上是"下一题"');

      // 第二题：自定义答案。
      c.setCustom('  别碰生产库  ');
      await c.submitQuestion();

      expect(sent.length, 1, reason: '一批答案一次发出去，不是每题一发');
      final batch = sent.single;
      expect(batch.answers.length, 2, reason: '每个问题恰好一项（DSH 的 BAD_ANSWER 判据）');
      expect(batch.answers[0].id, 'scope');
      expect(batch.answers[0].selected, ['全部', '只读']);
      expect(batch.answers[1].id, 'note');
      // 自定义答案**去掉首尾空白**再发（否则电脑侧收到的是带空格的"答案"）。
      expect(batch.answers[1].custom, '别碰生产库');
      expect(c.queue, isEmpty);
    });

    test('显式跳过：空 selected 且无 custom 也照样提交', () async {
      final sent = <InteractionAnswer>[];
      final c = _controllerFor()..onAnswer = (answer) async => sent.add(answer);
      c.enqueue(question('q1'));

      c.skipQuestion();
      expect(c.answered, isTrue, reason: '跳过是合法的回答，不是"没答"');
      await c.submitQuestion();
      expect(sent.single.answers.single.selected, isEmpty);
      expect(sent.single.answers.single.custom, isNull);
    });

    test('计划：同意执行发的是 DSH 给的 approveLabel', () async {
      final sent = <InteractionAnswer>[];
      final c = _controllerFor()..onAnswer = (answer) async => sent.add(answer);
      c.enqueue(
        const InteractionItem(
          itemId: 'p1',
          sid: 'sid-1',
          callId: 'call-p1',
          kind: InteractionKind.plan,
          title: '一个计划',
          approveLabel: 'Approve plan',
          questions: [
            InteractionQuestion(
              id: 'plan-1',
              question: '一个计划',
              options: [
                InteractionOption(label: 'Approve plan'),
                InteractionOption(label: 'Keep planning'),
              ],
            ),
          ],
        ),
      );

      await c.settlePlan(approved: true);
      expect(sent.single.answers.single.selected, ['Approve plan']);

      c.enqueue(
        const InteractionItem(
          itemId: 'p2',
          sid: 'sid-1',
          callId: 'call-p2',
          kind: InteractionKind.plan,
          title: '又一个计划',
          approveLabel: 'Approve plan',
          questions: [
            InteractionQuestion(
              id: 'plan-2',
              question: '又一个计划',
              options: [
                InteractionOption(label: 'Approve plan'),
                InteractionOption(label: 'Keep planning'),
              ],
            ),
          ],
        ),
      );
      await c.settlePlan(approved: false);
      expect(sent.last.answers.single.selected, isEmpty, reason: '其余一律拒绝');
    });

    test('没有出口时不发也不崩（演示模式）', () async {
      final c = _controllerFor()..enqueue(approval('a1'));
      await c.allowOnce();
      expect(c.queue, isEmpty);
      expect(c.receipts.single.text, contains('allowed-once'));
    });

    test('`settle` 撤掉的可以不是队首（迟到的 decided 排在别的待处理项后面）', () {
      final c = _controllerFor()
        ..enqueue(approval('a1'))
        ..enqueue(approval('a2'));
      expect(c.settle('i:a2'), isFalse, reason: 'itemId 对不上就不动');
      expect(c.settle('a2'), isTrue);
      expect(c.active?.itemId, 'a1');
      expect(c.queue.length, 1);
    });
  });

  group('界面', () {
    testWidgets('审批卡显示标题、明细与两个按钮', (tester) async {
      final c = _controllerFor();
      c.enqueue(
        const InteractionItem(
          itemId: 'a1',
          sid: 'sid-1',
          callId: 'call-a1',
          kind: InteractionKind.approval,
          toolName: 'bash',
          title: '工具 bash 请求越权执行',
          detail: 'rm -rf build/',
        ),
      );
      await tester.pumpWidget(_wrap(c));
      await tester.pumpAndSettle();

      expect(find.text('等待审批'), findsOneWidget);
      expect(find.text('工具 bash 请求越权执行'), findsOneWidget);
      expect(find.text('rm -rf build/'), findsOneWidget);
      expect(find.text('拒绝'), findsOneWidget);
      expect(find.text('允许一次'), findsOneWidget);
    });

    testWidgets('点「允许一次」→ 卡片消失（队列空了，输入栏回来）', (tester) async {
      final c = _controllerFor()..enqueue(approval('a1'));
      await tester.pumpWidget(_wrap(c));
      await tester.pumpAndSettle();

      await tester.tap(find.text('允许一次'));
      await tester.pumpAndSettle();
      expect(find.text('等待审批'), findsNothing);
    });

    testWidgets('提问：未回答时提交键不可点（点了没反应）', (tester) async {
      final c = _controllerFor()..enqueue(question('q1'));
      await tester.pumpWidget(_wrap(c));
      await tester.pumpAndSettle();

      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      expect(c.queue.length, 1, reason: '未回答时提交不该生效');
      expect(find.text('选哪个？'), findsOneWidget, reason: '卡片该还在');
    });

    testWidgets('提问：选项的说明在标签**下面**（同行会挤掉标签）', (tester) async {
      final c = _controllerFor()..enqueue(question('q1'));
      await tester.pumpWidget(_wrap(c));
      await tester.pumpAndSettle();

      final label = tester.getRect(find.text('乙'));
      final desc = tester.getRect(find.text('乙的说明'));
      expect(
        desc.top,
        greaterThanOrEqualTo(label.bottom - 1),
        reason: '说明该在标签下面第二行',
      );
    });

    testWidgets('推荐是**徽标**且从标签里剥出来了', (tester) async {
      final c = _controllerFor();
      c.enqueue(
        const InteractionItem(
          itemId: 'q1',
          sid: 'sid-1',
          callId: 'call-q1',
          kind: InteractionKind.question,
          title: '选哪个？',
          questions: [
            InteractionQuestion(
              id: 'q1',
              question: '选哪个？',
              options: [InteractionOption(label: '一起拆', recommended: true)],
            ),
          ],
        ),
      );
      await tester.pumpWidget(_wrap(c));
      await tester.pumpAndSettle();

      // 标签本体**不含**"（推荐）"（原型 `label.replace(/（推荐）/g, '')`）。
      expect(find.text('一起拆'), findsOneWidget);
      expect(find.textContaining('（推荐）'), findsNothing);
      // 徽标单独一个。
      expect(find.text('推荐'), findsOneWidget);
    });

    testWidgets('计划：两个按钮是"要求修改 / 同意执行"', (tester) async {
      final c = _controllerFor();
      c.enqueue(
        const InteractionItem(
          itemId: 'p1',
          sid: 'sid-1',
          callId: 'call-p1',
          kind: InteractionKind.plan,
          title: '一个计划',
          approveLabel: '同意执行',
          questions: [
            InteractionQuestion(
              id: 'plan-1',
              question: '一个计划',
              options: [
                InteractionOption(label: '同意执行'),
                InteractionOption(label: '要求修改'),
              ],
            ),
          ],
        ),
      );
      await tester.pumpWidget(_wrap(c));
      await tester.pumpAndSettle();

      expect(find.text('等待确认计划'), findsOneWidget);
      expect(find.text('要求修改'), findsOneWidget);
      expect(find.text('同意执行'), findsOneWidget);
    });

    testWidgets('收起按钮把卡片收掉（队列不减）', (tester) async {
      final c = _controllerFor()..enqueue(approval('a1'));
      await tester.pumpWidget(_wrap(c));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('收起'));
      await tester.pumpAndSettle();
      expect(find.text('等待审批'), findsNothing);
      expect(c.queue.length, 1);
    });

    testWidgets('空队列时不渲染任何东西（输入栏位置不留空）', (tester) async {
      await tester.pumpWidget(_wrap(_controllerFor()));
      await tester.pumpAndSettle();
      expect(find.text('等待审批'), findsNothing);
      expect(find.text('等待回答'), findsNothing);
      expect(find.text('其他会话还有待处理，去会话列表切换'), findsNothing);
    });
  });

  // ## 多会话：一个会话一队（2026-10-13，对齐 DSH 原生）
  //
  // DSH 的待处理是 per-session 的：`PendingApproval` / `PendingQuestion` 都带
  // `sessionId`，注册进**那个会话**的 composer（`ui-session/src/client/index.ts:391`、
  // `ui-approval/src/client/contract/slots.ts:101`）。电脑上并行开着几个会话时，
  // 每个会话各有各的待处理，用户切到哪个会话就处理哪个。
  group('多会话：一会话一队', () {
    test('两个会话各一队，切到哪个看哪个', () {
      final c = _controllerFor('sid-A');
      expect(c.enqueue(approval('a1', sid: 'sid-A')), isTrue);
      expect(c.enqueue(approval('b1', sid: 'sid-B')), isTrue);

      expect(c.currentSid, 'sid-A');
      expect(c.active?.itemId, 'a1');
      expect(c.queue.length, 1, reason: 'A 的队里只有 A 的项');

      c.setCurrentSid('sid-B');
      expect(c.active?.itemId, 'b1', reason: '切到 B 就看见 B 的队首');
      expect(c.queue.length, 1);

      c.setCurrentSid('sid-A');
      expect(c.active?.itemId, 'a1', reason: '切回来还在（没丢）');
    });

    test('切走的会话不丢、也不插到眼前', () {
      final c = _controllerFor('sid-A');
      c.enqueue(approval('a1', sid: 'sid-A'));
      c.enqueue(approval('b1', sid: 'sid-B'));
      c.setCurrentSid('sid-B');

      expect(c.pendingCountOf('sid-A'), 1, reason: 'A 还在等，只是不在眼前');
      expect(c.pendingElsewhere(), 1, reason: '除当前会话外还有 1 个');
      expect(c.queue.length, 1, reason: '眼前的队不该被别的会话塞满');
    });

    test('没选会话时一个桶都看不见，但项不丢', () {
      final c = _controllerFor('sid-A');
      c.enqueue(approval('a1', sid: 'sid-A'));
      c.setCurrentSid(null);
      expect(c.active, isNull);
      expect(c.phase, TakeoverPhase.idle);
      c.setCurrentSid('sid-A');
      expect(c.active?.itemId, 'a1', reason: '项还在桶里');
    });

    test('同一会话多个待处理按 DSH 优先级：计划 2 > 提问 1 > 审批 0', () {
      // 照 DSH：`ui-user-questions/.../index.ts:372` 的 `plan-review ? 2 : 1`、
      // `ui-approval/.../index.ts:89` 的 `() => 0`，大的赢。
      // **不自己发明"审批最急"** —— 那是 DSH 已经定过的次序。
      final c = _controllerFor('sid-1');
      c.enqueue(approval('a1'));
      c.enqueue(question('q1'));
      c.enqueue(plan('p1'));

      expect(c.active?.itemId, 'p1', reason: '计划审查优先级最高');
      c.settle('p1', sid: 'sid-1');
      expect(c.active?.itemId, 'q1', reason: '剩下提问');
      c.settle('q1', sid: 'sid-1');
      expect(c.active?.itemId, 'a1', reason: '最后是审批');
    });

    test('迟到的收束不带 sid 也能撤掉（可能属于别的会话）', () {
      // 用户在 A 里的时候，B 的审批在电脑上被答了 —— 事件只带 itemId。
      // 限定当前桶会让 B 的卡片永远挂着。
      final c = _controllerFor('sid-A');
      c.enqueue(approval('a1', sid: 'sid-A'));
      c.enqueue(approval('b1', sid: 'sid-B'));

      expect(c.settle('b1'), isTrue, reason: '不带 sid：全桶找');
      expect(c.pendingCountOf('sid-B'), 0);
      expect(c.pendingCountOf('sid-A'), 1, reason: '不该顺手撤掉眼前这个');
    });

    testWidgets('本会话空着、别的会话有：显示一行提示', (tester) async {
      final c = _controllerFor('sid-A');
      c.enqueue(approval('b1', sid: 'sid-B'));
      await tester.pumpWidget(_wrap(c));
      await tester.pumpAndSettle();

      expect(find.text('其他会话还有待处理，去会话列表切换'), findsOneWidget);
      expect(find.text('等待审批'), findsNothing, reason: '不把别的会话的卡铺到眼前');
    });

    testWidgets('本会话有卡时不显示跨会话提示（卡更重要）', (tester) async {
      final c = _controllerFor('sid-A');
      c.enqueue(approval('a1', sid: 'sid-A'));
      c.enqueue(approval('b1', sid: 'sid-B'));
      await tester.pumpWidget(_wrap(c));
      await tester.pumpAndSettle();

      expect(find.text('等待审批'), findsOneWidget);
      expect(find.text('其他会话还有待处理，去会话列表切换'), findsNothing);
    });
  });
}
