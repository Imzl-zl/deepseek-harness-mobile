/// 轮组的分组与折叠（纯函数，`lib/model/turn_groups.dart`）。
///
/// 守四件事：
///
/// 1. **边界来自事件**：`turn/start` 的记账条目（`OtherItem`）开一组，
///    收口行（`TurnProcessItem` / `TurnOutcomeItem`）结束一组 —— 不靠位置推测。
/// 2. **运行中的一轮不折**（DSH 的组头在 `turn.status !== 'closed'` 时压根不渲染）。
/// 3. **折叠只藏过程**（工具 / 命令 / 重试 / 压缩），用户那句话、助手正文、
///    收口行、审批卡都留着。
/// 4. **未归属的条目不折**：这一屏没读到 `turn/start`（历史窗口不全 / 老连接器）
///    时如实降级，不编一个轮号把两轮并成一组。
library;

import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/model/turn_groups.dart';
import 'package:flutter_test/flutter_test.dart';

/// `turn/start` 的记账条目（AppModel 在 `_onDelta` 里落的就是它）。
ChatItem start(int turn, int seq) => OtherItem(
  itemId: 's:$seq',
  seq: seq,
  updatedAt: 0,
  turn: turn,
  eventType: 'turn/start',
);

ChatItem user(int seq, String text) => MessageItem(
  itemId: 'u:$seq',
  seq: seq,
  updatedAt: 0,
  role: MessageRole.user,
  text: text,
);

ChatItem answer(int seq, String text) => MessageItem(
  itemId: 'a:$seq',
  seq: seq,
  updatedAt: 0,
  role: MessageRole.assistant,
  text: text,
);

ChatItem tool(int seq, String name) => ToolCallItem(
  itemId: 't:$seq',
  seq: seq,
  updatedAt: 0,
  name: name,
  status: ToolCallStatus.completed,
);

ChatItem command(int seq) => CommandItem(
  itemId: 'c:$seq',
  seq: seq,
  updatedAt: 0,
  name: 'compact',
  status: ToolCallStatus.completed,
);

ChatItem retry(int seq) => ModelRetryItem(
  itemId: 'r:$seq',
  seq: seq,
  updatedAt: 0,
  retry: 1,
  maxRetries: 3,
  message: '限流',
);

ChatItem compaction(int seq) => CompactionItem(
  itemId: 'k:$seq',
  seq: seq,
  updatedAt: 0,
  summary: '压掉了 8 条',
);

ChatItem process(int turn, int seq) =>
    TurnProcessItem(itemId: 'p:$turn', seq: seq, updatedAt: 0, turn: turn);

void main() {
  group('切分', () {
    test('按 turn/start 分成两组，成员与顺序都对', () {
      final items = [
        start(1, 1),
        user(2, '第一问'),
        tool(3, 'bash'),
        answer(4, '第一答'),
        process(1, 5),
        start(2, 6),
        user(7, '第二问'),
        answer(8, '第二答'),
        process(2, 9),
      ];
      final groups = buildTurnGroups(items);
      expect(groups.length, 2);
      expect(groups[0].turn, 1);
      expect(groups[0].items.map((i) => i.itemId), [
        's:1',
        'u:2',
        't:3',
        'a:4',
        'p:1',
      ]);
      expect(groups[1].turn, 2);
      expect(groups[1].items.map((i) => i.itemId), [
        's:6',
        'u:7',
        'a:8',
        'p:2',
      ]);
    });

    test('第一个 turn/start 之前的条目是"未归属"组，且不可折叠', () {
      final items = [
        user(1, '窗口外的开头'),
        tool(2, 'read'),
        start(1, 3),
        user(4, '问'),
        process(1, 5),
      ];
      final groups = buildTurnGroups(items);
      expect(groups.length, 2);
      expect(groups[0].turn, isNull);
      expect(groups[0].collapsible, isFalse);
      expect(groups[1].turn, 1);
    });

    test('重复的同一个 turn/start（重放）不会多开一组', () {
      final items = [start(1, 1), user(2, '问'), start(1, 3), process(1, 4)];
      final groups = buildTurnGroups(items);
      expect(groups.length, 1);
      expect(groups.single.turn, 1);
    });

    test('历史窗口：没有 turn/start 也能按条目自己的轮号分组', () {
      // 恢复老会话时窗口里未必有 `turn/start`；助手消息与工具卡带着 `data.turn`
      // （事件形状如此），边界照样成立。
      const items = <ChatItem>[
        MessageItem(
          itemId: 'u:2',
          seq: 2,
          updatedAt: 0,
          role: MessageRole.user,
          text: '问',
        ),
        ToolCallItem(
          itemId: 't:3',
          seq: 3,
          updatedAt: 0,
          turn: 1,
          name: 'bash',
          status: ToolCallStatus.completed,
        ),
        TurnProcessItem(itemId: 'p:1', seq: 4, updatedAt: 0, turn: 1),
        MessageItem(
          itemId: 'a:5',
          seq: 5,
          updatedAt: 0,
          turn: 2,
          role: MessageRole.assistant,
          text: '第二轮的答',
        ),
      ];
      final groups = buildTurnGroups(items);
      // 三条：开头那条没有轮号的用户消息自成一组（**永不折叠** ⇒ 始终可见）——
      // 这是有意的降级：宁可多一段平铺，也不把用户的话挂到别的轮名下。
      expect(groups.length, 3);
      expect(groups[0].turn, isNull);
      expect(groups[0].items.map((i) => i.itemId), ['u:2']);
      expect(groups[1].turn, 1);
      expect(groups[1].items.map((i) => i.itemId), ['t:3', 'p:1']);
      expect(groups[2].turn, 2);
    });

    test('空表与纯未归属表都不炸', () {
      expect(buildTurnGroups(const []), isEmpty);
      final only = buildTurnGroups([user(1, '问')]);
      expect(only.length, 1);
      expect(only.single.turn, isNull);
    });
  });

  group('能不能折', () {
    test('收口且带过程 ⇒ 可折', () {
      final groups = buildTurnGroups([
        start(1, 1),
        tool(2, 'bash'),
        process(1, 3),
      ]);
      expect(groups.single.collapsible, isTrue);
      expect(collapsibleTurns(groups), {1});
    });

    test('运行中（还没有收口行）⇒ 不可折 —— 边跑边看是主场景', () {
      final groups = buildTurnGroups([
        start(1, 1),
        user(2, '问'),
        tool(3, 'bash'),
      ]);
      expect(groups.single.closed, isFalse);
      expect(groups.single.collapsible, isFalse);
      expect(collapsibleTurns(groups), isEmpty);
    });

    test('收口行之后还有无轮号的记账事件 ⇒ 仍算已收口（真机踩到：否则没有箭头）', () {
      final items = [
        start(1, 1),
        tool(2, 'bash'),
        process(1, 3),
        const OtherItem(
          itemId: 'o:4',
          seq: 4,
          updatedAt: 0,
          eventType: 'request/header',
        ),
      ];
      final groups = buildTurnGroups(items);
      expect(groups.single.closed, isTrue, reason: '判"最后一条"会漏这一种');
      expect(groups.single.collapsible, isTrue);
    });

    test('一轮里没有过程条目 ⇒ 不可折（没什么可收的，别给假箭头）', () {
      final groups = buildTurnGroups([
        start(1, 1),
        user(2, '问'),
        answer(3, '答'),
        process(1, 4),
      ]);
      expect(groups.single.hasProcess, isFalse);
      expect(groups.single.collapsible, isFalse);
    });
  });

  group('助手头落在哪（一轮一个、且在最上面）', () {
    test('每组第一条助手侧条目拿头；用户消息与上下文行不拿', () {
      final groups = buildTurnGroups([
        start(1, 1),
        user(2, '问'),
        user(3, '上下文注入'),
        tool(4, 'bash'),
        answer(5, '答'),
        process(1, 6),
      ]);
      final visible = applyTurnCollapse(groups, isExpanded: (_) => true);
      final heads = assistantHeadItemIds(visible);
      expect(heads, {'t:4'}, reason: '头在轮次开头（第一条助手侧条目），不是贴在回答上');
    });

    test('折叠后按**可见**条目算：被藏掉的过程不能让头跟着消失', () {
      final groups = buildTurnGroups([
        start(1, 1),
        user(2, '问'),
        tool(3, 'bash'),
        answer(4, '答'),
        process(1, 5),
      ]);
      final collapsed = applyTurnCollapse(groups, isExpanded: (_) => false);
      expect(
        assistantHeadItemIds(collapsed),
        {'a:4'},
        reason: '收起时工具卡被藏掉，头必须落到仍然可见的回答上（否则整轮没有助手段）',
      );
    });

    test('同一轮里夹一条无轮号的记账事件，也只画一个头', () {
      // `turn/end` 之后会落 `request/*` 之类没有轮号的条目；它们**不能把段打断**，
      // 否则"思考 → 记账 → 回答"会被切成两段、冒出两个头像。
      final groups = buildTurnGroups([
        start(1, 1),
        user(2, '问'),
        tool(3, 'bash'),
        const OtherItem(
          itemId: 'o:4',
          seq: 4,
          updatedAt: 0,
          eventType: 'request/header',
        ),
        answer(5, '答'),
        process(1, 6),
      ]);
      final visible = applyTurnCollapse(groups, isExpanded: (_) => true);
      expect(assistantHeadItemIds(visible), {'t:3'});
    });

    test('命令卡 / 压缩卡不拿头（主语不是助手），但仍然是过程', () {
      final groups = buildTurnGroups([
        start(1, 1),
        user(2, '问'),
        command(3),
        compaction(4),
        answer(5, '答'),
        process(1, 6),
      ]);
      final visible = applyTurnCollapse(groups, isExpanded: (_) => true);
      expect(assistantHeadItemIds(visible), {'a:5'}, reason: '头落在助手正文上');
      expect(isProcessItem(command(7)), isTrue, reason: '命令卡仍然随轮组收起');
    });

    test('没有助手侧条目的组（只有用户消息）不拿头', () {
      final groups = buildTurnGroups([start(1, 1), user(2, '问')]);
      final visible = applyTurnCollapse(groups, isExpanded: (_) => true);
      expect(assistantHeadItemIds(visible), isEmpty);
    });
  });

  group('折叠藏什么', () {
    test('只藏过程：用户消息 / 正文 / 收口行 / 审批卡都留着', () {
      final items = [
        start(1, 1),
        user(2, '问'),
        tool(3, 'bash'),
        command(4),
        retry(5),
        compaction(6),
        const ApprovalItem(
          itemId: 'ap:7',
          seq: 7,
          updatedAt: 0,
          title: '允许跑 rm -rf',
          decided: false,
        ),
        answer(8, '答'),
        process(1, 9),
      ];
      final groups = buildTurnGroups(items);
      final shown = applyTurnCollapse(groups, isExpanded: (_) => false);
      expect(shown.map((i) => i.itemId), [
        's:1',
        'u:2',
        'ap:7',
        'a:8',
        'p:1',
      ], reason: '工具 / 命令 / 重试 / 压缩被收起，其余保持原顺序');
      // 展开时一条不少。
      final open = applyTurnCollapse(groups, isExpanded: (_) => true);
      expect(open.length, items.length);
    });

    test('未归属组永远不收起（哪怕回调说收）', () {
      final items = [user(1, '窗口外'), tool(2, 'read')];
      final groups = buildTurnGroups(items);
      final shown = applyTurnCollapse(groups, isExpanded: (_) => false);
      expect(shown.length, 2);
    });

    test('按轮分别判：展开的第 1 轮原样、收起的第 2 轮只留过程之外的行', () {
      final items = [
        start(1, 1),
        tool(2, 'bash'),
        process(1, 3),
        start(2, 4),
        tool(5, 'read'),
        process(2, 6),
      ];
      final groups = buildTurnGroups(items);
      final shown = applyTurnCollapse(groups, isExpanded: (turn) => turn == 1);
      expect(shown.map((i) => i.itemId), ['s:1', 't:2', 'p:1', 's:4', 'p:2']);
    });
  });
}
