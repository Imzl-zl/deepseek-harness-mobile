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
library;

import 'dart:async';

import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/takeover.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

TakeoverItem approval(String key, {String tool = 'bash'}) => TakeoverItem(
  key: key,
  kind: TakeoverKind.approval,
  toolName: tool,
  title: '工具 $tool 请求越权执行',
);

TakeoverItem question(String key) => TakeoverItem(
  key: key,
  kind: TakeoverKind.question,
  title: '选哪个？',
  options: const [
    TakeoverOption(label: '甲'),
    TakeoverOption(label: '乙', description: '乙的说明'),
  ],
);

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
      final c = TakeoverController();
      c.enqueue(approval('a1'));
      c.enqueue(approval('a2'));
      expect(c.active?.key, 'a1');
      expect(c.queue.length, 2);
    });

    test('答完队首，下一个自动成为 active', () async {
      final c = TakeoverController();
      c.enqueue(approval('a1'));
      c.enqueue(approval('a2'));
      await c.allowOnce();
      expect(c.active?.key, 'a2');
      expect(c.queue.length, 1);
    });

    test('同一个 key 不重复入队（收起后重开走 restore 而不是再入一次）', () {
      final c = TakeoverController();
      c.enqueue(approval('a1'));
      c.minimize();
      c.enqueue(approval('a1'));
      expect(c.queue.length, 1);
      expect(c.phase, TakeoverPhase.active, reason: '重入同一个 key 应顺带恢复显示');
    });

    test('空队列时 phase 是 idle（输入栏正常）', () {
      expect(TakeoverController().phase, TakeoverPhase.idle);
    });
  });

  group('「允许一次」的语义（不能变成永久放权）', () {
    test('allowOnce 的回执写的是 `allowed-once`，不是权限档位', () async {
      final c = TakeoverController();
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
      final c = TakeoverController();
      c.enqueue(approval('a1'));
      await c.reject();
      expect(c.receipts.single.text, contains('rejected'));
    });

    test('下一次审批仍然要授权（一次就是一次）', () async {
      final c = TakeoverController();
      c.enqueue(approval('a1'));
      await c.allowOnce();
      c.enqueue(approval('a2'));
      expect(c.active?.key, 'a2', reason: '第二次仍要排队等授权');
      expect(c.phase, TakeoverPhase.active);
    });
  });

  group('fullAccess 下审批不入队（原型 enqueue 的第一条分支）', () {
    test('完全权限：审批返回 false、队列不变', () {
      final c = TakeoverController()..fullAccess = true;
      final queued = c.enqueue(approval('a1'));
      expect(queued, isFalse, reason: '未入队要如实返回 false');
      expect(c.queue, isEmpty);
      expect(c.phase, TakeoverPhase.idle);
    });

    test('完全权限**只影响审批** —— 提问与计划照常入队', () {
      final c = TakeoverController()..fullAccess = true;
      expect(c.enqueue(question('q1')), isTrue);
      expect(
        c.enqueue(
          const TakeoverItem(key: 'p1', kind: TakeoverKind.plan, title: '计划'),
        ),
        isTrue,
      );
    });
  });

  group('提问', () {
    test('未回答时 `answered` 为假（提交键据此禁用）', () {
      final c = TakeoverController()..enqueue(question('q1'));
      expect(c.answered, isFalse);
    });

    test('选了选项 → answered 为真；单选再点同一个是取消', () {
      final c = TakeoverController()..enqueue(question('q1'));
      c.toggleOption('甲');
      expect(c.answered, isTrue);
      c.toggleOption('甲');
      expect(c.selected, isEmpty, reason: '单选再点同一个该退回"未选"（否则选错了没法退）');
      expect(c.answered, isFalse);
    });

    test('自定义答案也算回答', () {
      final c = TakeoverController()..enqueue(question('q1'));
      c.setCustom('我自己写一个');
      expect(c.answered, isTrue);
    });

    test('多选可以同时选两个', () {
      final c = TakeoverController();
      c.enqueue(
        const TakeoverItem(
          key: 'q1',
          kind: TakeoverKind.question,
          title: '多选',
          multiSelect: true,
          options: [
            TakeoverOption(label: '甲'),
            TakeoverOption(label: '乙'),
          ],
        ),
      );
      c.toggleOption('甲');
      c.toggleOption('乙');
      expect(c.selected, {'甲', '乙'});
    });

    test('未回答时提交是**无操作**（不推进队列）', () async {
      final c = TakeoverController()..enqueue(question('q1'));
      await c.submitQuestion();
      expect(c.queue.length, 1, reason: '没答就不能提交 —— 队列不减');
      expect(c.receipts, isEmpty);
    });

    test('答了才提交，且回执带答案', () async {
      final c = TakeoverController()..enqueue(question('q1'));
      c.toggleOption('乙');
      await c.submitQuestion();
      expect(c.receipts.single.text, contains('乙'));
      expect(c.queue, isEmpty);
    });
  });

  group('在途状态（原型 `item.busy`）', () {
    test('提交期间 phase 是 busy（按钮据此禁用）', () async {
      final c = TakeoverController()..enqueue(approval('a1'));
      final pending = c.allowOnce();
      expect(c.phase, TakeoverPhase.busy);
      await pending;
      expect(c.phase, TakeoverPhase.idle);
    });

    test('busy 期间重复点无效（只出一条回执）', () async {
      final c = TakeoverController()..enqueue(approval('a1'));
      final first = c.allowOnce();
      unawaited(c.reject()); // 在途时的第二次点击
      await first;
      expect(c.receipts.length, 1, reason: '在途期间只该有一次应答');
    });
  });

  group('收起与恢复', () {
    test('收起后 phase 是 minimized（对话流里留一行提示）', () {
      final c = TakeoverController()..enqueue(approval('a1'));
      c.minimize();
      expect(c.phase, TakeoverPhase.minimized);
      expect(c.queue.length, 1, reason: '收起**不等于**回答 —— 它还在队列里');
    });

    test('恢复后回到 active', () {
      final c = TakeoverController()..enqueue(approval('a1'));
      c.minimize();
      c.restore();
      expect(c.phase, TakeoverPhase.active);
    });
  });

  group('界面', () {
    testWidgets('审批卡显示标题、明细与两个按钮', (tester) async {
      final c = TakeoverController();
      c.enqueue(
        const TakeoverItem(
          key: 'a1',
          kind: TakeoverKind.approval,
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
      final c = TakeoverController()..enqueue(approval('a1'));
      await tester.pumpWidget(_wrap(c));
      await tester.pumpAndSettle();

      await tester.tap(find.text('允许一次'));
      await tester.pumpAndSettle();
      expect(find.text('等待审批'), findsNothing);
    });

    testWidgets('提问：未回答时提交键不可点（点了没反应）', (tester) async {
      final c = TakeoverController()..enqueue(question('q1'));
      await tester.pumpWidget(_wrap(c));
      await tester.pumpAndSettle();

      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      expect(c.queue.length, 1, reason: '未回答时提交不该生效');
      expect(find.text('选哪个？'), findsOneWidget, reason: '卡片该还在');
    });

    testWidgets('提问：选项的说明在标签**下面**（同行会挤掉标签）', (tester) async {
      final c = TakeoverController()..enqueue(question('q1'));
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
      final c = TakeoverController();
      c.enqueue(
        const TakeoverItem(
          key: 'q1',
          kind: TakeoverKind.question,
          title: '选哪个？',
          options: [TakeoverOption(label: '一起拆', recommended: true)],
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
      final c = TakeoverController();
      c.enqueue(
        const TakeoverItem(key: 'p1', kind: TakeoverKind.plan, title: '一个计划'),
      );
      await tester.pumpWidget(_wrap(c));
      await tester.pumpAndSettle();

      expect(find.text('等待确认计划'), findsOneWidget);
      expect(find.text('要求修改'), findsOneWidget);
      expect(find.text('同意执行'), findsOneWidget);
    });

    testWidgets('收起按钮把卡片收掉（队列不减）', (tester) async {
      final c = TakeoverController()..enqueue(approval('a1'));
      await tester.pumpWidget(_wrap(c));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('收起'));
      await tester.pumpAndSettle();
      expect(find.text('等待审批'), findsNothing);
      expect(c.queue.length, 1);
    });

    testWidgets('空队列时不渲染任何东西（输入栏位置不留空）', (tester) async {
      await tester.pumpWidget(_wrap(TakeoverController()));
      await tester.pumpAndSettle();
      expect(find.text('等待审批'), findsNothing);
      expect(find.text('等待回答'), findsNothing);
    });
  });
}
