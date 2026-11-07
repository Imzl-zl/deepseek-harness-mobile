# Agent Note: 思考属于过程（可折），运行中的一轮过程保持展开

Status: implemented

## Problem

真机（`d61cf622`，2026-11-07）：同一轮里桌面有「思考」，手机没有。桌面那张图里
「已完成，用时 2 秒」与「已完成分析」都是展开的，思考行在里面；手机这一轮连折叠箭头
都没有 —— **思考没有任何入口可见**。

两处判据错，都不是设计：

1. `TurnGroup.hasProcess` 只查独立过程条目（工具 / 命令 / 重试 / 压缩）。
   而真实形状里，一轮**只发一次** `assistant/message`，`reasoning` 与 `text` 同在
   那一条消息里；没有工具的一轮于是被判定为"没有过程" ⇒ 不可折（不收口行箭头）。
2. `_turnExpanded` 在「回答结束后」这一档下**对任何轮都返回 false**，包括**还在跑**的轮。
   而 DSH 的规则是「尚未结束 / 已停止或失败 ⇒ 过程内容保持展开，不能收起整轮」
   （`packages/client/ui-chat/src/client/conversation-nodes/README.zh.md`）。

两条叠起来：默认收起态是 false、又没有箭头 ⇒ 思考永远不显示；而生成中同样被按下去，
于是"看不到"也发生在流式期间。

## Decision

1. `TurnGroup.hasProcess` 把「答复里带非空 reasoning 的 `MessageItem`」也算作过程证据。
   理由：折叠时它本来就被藏（`AssistantTurn.showReasoning = turnExpanded`），
   藏着却不给可折的箭头的那个组合是自相矛盾的。
2. `_turnExpanded`：**未收口的轮直接返回 true**（DSH 同一条）；已收口的轮才按
   「工作步骤收起时机」两档判。

## Alternatives considered

1. **让思考行不随轮组收起（永远显示一行折叠的「思考」）**
   - 最强的理由：用户看到的最直接；DSH 的折叠语义对触屏偏重。
   - 为何被否：DSH 明文把推理归入过程（`processMember`），折叠时一起藏；
     要做就是**有意偏离**，得先改文档。而且"哪一轮算过程"的判据会变成两套。
   现在可以不改代码就得到同一效果：设置「工作步骤收起时机」＝`下次有新消息时`。
2. **把最终答复的 reasoning 拆成独立 `ReasoningItem` 条目**
   - 为何被否：真日志里 reasoning 与 text 在**同一条** `assistant/message` 里；
     拆成两条会让"一条助手消息"变成"过程行 + 助手消息"，落定那一帧多一次换构造，
     而投影层的 `assistant/message` 只有一个 `itemId`。

## Consequences

- 只有思考、没有工具的一轮现在有折叠箭头：默认收起（按设置），点开可见思考。
- 生成中过程不再被"回答结束后"这一档按下去：流式期间思考行与工具卡都在。
- 判据加了三条用例（纯函数 1 + 页面 2），并做过变异校验：
  去掉 `hasProcess` 的那一支恰好这两条红；去掉"未收口返回 true"恰好"跑步中"那条红。
- 文档 `docs/subsystems/turn-groups.md` §3 / §6 同步。
