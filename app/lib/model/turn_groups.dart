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
    item is CompactionItem ||
    // 中间步骤的思考（`ReasoningItem`）也是过程：DSH 把 reasoning 归进
    // `processMember`（`ChatNodeSeat.tsx:78-83`），折叠时一起收起。
    item is ReasoningItem;

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

/// 这条条目是不是"助手侧"的内容（思考 / 工具 / 命令 / 重试 / 压缩 / 助手正文）。
///
/// 用它决定「助手」头画在哪：用户消息、上下文注入行都不是助手侧。
bool isAssistantSide(ChatItem item) => switch (item) {
  // 助手正文，**以及上下文注入行**（"电脑侧塞给模型的东西"）。
  // 后者是用户 2026-10-23 指出的：「上下文注入啥的显示在外面，不是在图标下面」——
  // 那块内容属于这一轮的助手块，头像要画在它上面。
  //
  // 判据用 `systemHint`（生产者：`runtime-context` / `skill-catalog` /
  // `time-context`）：**系统提示词**没有它（只有标题），因此它不会成为
  // "助手开始"的锚点 —— 系统提示词在用户那句之前，头像不能跑到问题上面。
  MessageItem(:final role, :final systemHint) =>
    role == MessageRole.assistant ||
        (role == MessageRole.system && systemHint != null),
  ReasoningItem() || ToolCallItem() || ModelRetryItem() => true,
  // **命令卡与压缩卡不算"助手在说话"**：斜杠命令是用户发起的执行，
  // 压缩是系统行为；把「助手」头挂在它们上面等于说错主语
  // （DSH 的 `GenericCommandCard` / `CompactionItem` 也各自带标签）。
  // 它们仍然是**过程**（折叠时随轮组收起），只是不拿头像。
  _ => false,
};

/// 该在哪些条目的**上方**画「助手」头：每一组里第一条助手侧条目。
///
/// ## 为什么头在最上面，而不是贴着最终回答
///
/// 用户 2026-10-23：「助手不应该是开始的时候显示吗？……不是一开始显示然后到输出完毕」。
/// 主流与 DSH 都是**一轮一个助手块**：块头在轮次开始，块内是思考 / 工具 / 正文。
/// 我们之前把头像钉在"最终回答"那条上，于是长轮次的头像出现在屏幕中间，
/// 读起来像两段对话（用户原话「怎么你这个中间显示？」）。
///
/// 返回的是 itemId 集合：`_TurnView` 据此在那一条上方补一个 [AssistantHead]。
/// **按"折叠后仍然可见的条目"算**：收起一轮时，被藏掉的那条（思考 / 工具）
/// 不能是头像的落点 —— 那样头像会跟着过程一起消失，折叠后整轮就没有助手段了
///（2026-10-23 widget 测抓到的）。
Set<String> assistantHeadItemIds(List<ChatItem> visibleItems) {
  final out = <String>{};
  int? run;
  var marked = false;
  for (final item in visibleItems) {
    // **只按"非空轮号变化"换段**：`turn == null` 的条目（`turn/end` 之后的
    // `request/*` 之类记账事件）归当前段，不能把段打断 —— 否则同一轮里
    // "思考(t1) → 记账(null) → 回答(t1)"会被切成两段、冒出两个头像。
    final turn = item.turn;
    if (turn != null && turn != run) {
      run = turn;
      marked = false;
    }
    if (marked || !isAssistantSide(item)) continue;
    out.add(item.itemId);
    marked = true;
  }
  return out;
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
