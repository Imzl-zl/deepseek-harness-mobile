/// 会话流的**轮组**：把平铺的条目按"轮"切开，并给出折叠时该藏哪些。
///
/// ## 为什么要这一层
///
/// DSH Web 一轮跑完是一条可展开的控制行（`packages/client/ui-chat/src/client/chat/TurnProcessNodeView.tsx:10`），
/// 组内是这轮的过程；手机此前**完全平铺** —— 一轮 8 次工具就是 8 张卡片铺两屏，
/// 而且 `/settings` 里「工作步骤展示」四档只能作用于单张卡的明细。
/// 结构差与取舍见 `.agents/notes/proposed/2026-10-22-turn-groups-in-conversation-flow.md`，
/// 现状见 `docs/subsystems/turn-groups.md`。
///
/// ## 边界从哪来（**不是猜的**）
///
/// 事件流里本来就有边界：`turn/start` 落一条不可见的记账条目
/// （`OtherItem(eventType: 'turn/start')`，带轮号），一轮结束时落
/// `TurnProcessItem` / `TurnOutcomeItem`。所以分组只需扫一遍条目表：
///
/// - 遇到 `turn/start` 记账条目（且带轮号）⇒ 开一个新组；
/// - 遇到收口行（过程摘要 / 异常结局，且轮号与当前组相同）⇒ 这一组算**已收口**；
/// - 第一个 `turn/start` 之前的条目 ⇒ 一个 `turn == null` 的"未归属"组，
///   **永不折叠**（历史窗口没加载到那一轮的起点时就是这种形状，如实降级）。
///
/// 轮号缺席（老连接器 / 事件没带 `data.turn`）时同样落进未归属组 ——
/// 编一个 0 会让两轮并成一组。
///
/// ## 折叠藏什么、留什么
///
/// **藏**：过程条目 —— 工具卡、命令卡、模型重试、压缩卡。
/// **留**：用户那句话、助手正文（含它的思考行）、轮次收口行、审批/提问卡。
///
/// 理由两条：① DSH 折叠的正是 `processMember`（`ChatNodeSeat.tsx:78-83`），
/// 用户消息与最终回答是独立节点、始终可见；② 审批/提问是**等用户决策**的东西，
/// 收起来等于让人找不到待办。
library;

import 'chat_item.dart';

/// 这条条目是不是"过程"（折叠时要藏起来的那一类）。
///
/// 只认这四类：它们是"过程"的证据；消息与结局行都不是过程。
bool isProcessItem(ChatItem item) =>
    item is ToolCallItem ||
    item is CommandItem ||
    item is ModelRetryItem ||
    item is CompactionItem;

/// 一段连续的条目 + 它属于第几轮。
class TurnGroup {
  const TurnGroup({required this.turn, required this.items});

  /// 第几轮；`null` = 未归属（这一屏没有这一轮的 `turn/start`）。
  final int? turn;

  /// 组内条目，**保持原顺序**。
  final List<ChatItem> items;

  /// 这一组有没有可折的过程条目。
  bool get hasProcess => items.any(isProcessItem);

  /// 这一轮是否已经收口：组里**出现过**过程摘要 / 异常结局行。
  ///
  /// **不判"最后一条"**：`turn/end` 之后还会落几条没有轮号的记账事件
  /// （`request/*` / `session/title-llm-request` 之类），它们被并进这一组，
  /// 按"最后一条"判会把已收口的一轮判成还在跑 —— 真机上就表现成
  /// **没有折叠箭头**（2026-10-22 首轮验证踩到）。
  bool get closed =>
      items.any((item) => item is TurnProcessItem || item is TurnOutcomeItem);

  /// 能不能折叠：**有轮号、有过程、且已收口**。
  ///
  /// 运行中的一轮不收（DSH 同一条：`TurnProcessNodeView.tsx:18` 在
  /// `turn.status !== 'closed'` 时整行都不存在）—— 边跑边看是主场景。
  bool get collapsible => turn != null && hasProcess && closed;
}

/// 把条目表切成轮组（顺序与输入一致）。
///
/// 纯函数：不读时钟、不读 `AppModel`，`items` 变才重新算。
List<TurnGroup> buildTurnGroups(List<ChatItem> items) {
  final groups = <TurnGroup>[];
  var current = <ChatItem>[];
  int? currentTurn;

  void flush() {
    if (current.isEmpty) return;
    groups.add(
      TurnGroup(turn: currentTurn, items: List<ChatItem>.unmodifiable(current)),
    );
    current = <ChatItem>[];
  }

  for (final item in items) {
    // 边界 = **条目自己的轮号**。事件带 `data.turn` 的（助手消息 / 工具 /
    // `turn/start` 的记账条目…）由投影直接带上；不带的那几种（用户消息 /
    // 命令卡 / 重试 / 压缩）由 `AppModel` 按"最近一次 `turn/start`"补。
    // 轮号一变就是新的一组。
    //
    // 这样**历史窗口里也能分组**：恢复老会话时窗口里未必有 `turn/start`，
    // 但只要助手消息与工具卡带着轮号，边界就还在（那是 DSH 的事件形状，
    // 不是我们编的）。
    final boundary = item.turn;
    if (boundary != null && boundary != currentTurn) {
      flush();
      currentTurn = boundary;
    }
    current.add(item);
  }
  flush();
  return List<TurnGroup>.unmodifiable(groups);
}

/// 可折叠的轮号集合（UI 用它决定哪些收口行要画箭头）。
Set<int> collapsibleTurns(List<TurnGroup> groups) => {
  for (final group in groups)
    if (group.collapsible) group.turn!,
};

/// 折叠后的条目表：把"收起"的那些轮里的过程条目去掉，顺序不变。
///
/// [isExpanded] 为假 ⇒ 该轮收起。**未归属组永远不收起**（它没有轮号）。
List<ChatItem> applyTurnCollapse(
  List<TurnGroup> groups, {
  required bool Function(int turn) isExpanded,
}) => [
  for (final group in groups)
    if (group.collapsible && !isExpanded(group.turn!))
      ...group.items.where((item) => !isProcessItem(item))
    else
      ...group.items,
];
