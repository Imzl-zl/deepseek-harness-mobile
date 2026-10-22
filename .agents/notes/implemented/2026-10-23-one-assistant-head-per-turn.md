# Agent Note: 一个 turn 只有一个「助手」头

Status: implemented

## Problem

用户 2026-10-22 深夜看真机截图后当场问：「它一个在输出干嘛分这么多段？为啥这个助手输出命令显示，
输出还显示助手？我看其他的每次思考都显示这个助手，一直都是它输出能显示好几个助手？？
是渲染的问题还是啥？还是设计如此？」

真日志（`session-4f50055e…`）说明了**事件形状**：一个 turn 会落**每个 step 一条**
`assistant/message`：

| turn | step 1 的 content | step 2 的 content |
|---|---|---|
| 1 | `reasoning(2239 字)` + `tool-call` | `reasoning(207 字)` + `text(最终回答)` |
| 4 | `reasoning(121 字)` + `tool-call` | `text(最终回答)` |
| 5 | `tool-call`（无思考无正文） | `text(最终回答)` |

而我们**每条都投影成 `MessageItem`、每条都画一个「助手」头**（头像 + 思考行 + 正文），
于是同一轮里 step 1 变成"一个只有头像（或头像 + 思考行）的助手"，step 2 又一个 ——
屏幕上像两个人在对话。

## Decision

按主流与 DSH 的形状切：**只有带正文的那条才是"一条助手消息"**。

1. 投影层（`data/projection.dart`）对 `assistant/message`：
   - 正文非空 ⇒ `MessageItem`（助手头 + 正文，思考行内联在它身上）；
   - 正文为空、思考非空 ⇒ **`ReasoningItem`**（新增条目类型，**过程行**，没有头像）；
   - 两者都空（只有 `tool-call`）⇒ `skip`，不占条目。
2. `ReasoningItem` 进 `isProcessItem` ⇒ 与工具卡同级，**轮组收起时一起消失**
   （DSH 把 reasoning 归进 `processMember`，`ChatNodeSeat.tsx:78-83`）。
3. 最终回答里的思考行也跟着轮组走：`AssistantTurn.showReasoning`，
   收起时为 false（对应 DSH 的 `compactAnswer`）。
4. **消息计数口径改成 DSH 的**：`_turnStatsOf` 只数**带正文**的助手消息
   （`hasAssistantReplyContent`，`assistant-content.ts:9-15`），但 token 合计仍把
   `ReasoningItem.usage` 算进去。

## Alternatives considered

1. **保留每步一条，只把中间的「助手」头换成更轻的标签（`思考 · 第 1 步`）**
   - 最强理由：改动最小，保留"这一步有一条消息"的暗示。
   - 为何被否：用户要的是"一个在输出"，标签只是把重复说得好听一点；而且 DSH 与主流
     都不这么做 —— 中间步骤在结构上就不是"助手消息"，而是过程。
2. **折叠时只把重复的头藏起来，展开时照旧**
   - 最强理由：不动投影层。
   - 为何被否：展开正是"想看过程"的时候，那时屏幕上出现三个头像更刺眼；
     而且"折叠藏什么"会从"条目级"退化成"条目内部的条件渲染"，两套规则。
3. **把中间步骤的思考并进最终回答的那条消息里**
   - 最强理由：一轮里只剩一条 `MessageItem`，渲染层零改动。
   - 为何被否：思考与它那一步的工具调用**顺序上交错**（思考 1 → 工具 1 → 思考 2 → 答案），
     合并会把过程压成一段，丢掉的正是"它当时在想什么、然后做了什么"。

## Consequences

- 收益：一轮里只有一个「助手」头（最终回答）；过程（思考 + 工具）聚在它上面，
  收起后一轮只剩"提示 + 回答 + 一行收口"。展开时是"思考行 + 工具卡"的连续过程，
  不再有头像穿插 —— 真机 `p2-one-head-expanded.png`（61 步的轮次，零头像穿插）。
- 代价：
  - 新增条目类型 `ReasoningItem`，`_TurnView` 的 sealed switch 多一支（编译器会逼着补）；
  - **"几条消息"的计数会变小**（以前把只有思考的那步也算一条）：这是向 DSH 靠，
    但历史截图/用户记忆里的数字会变；
  - 中间步骤的思考与它那一步的工具卡之间不再有头像分隔，只靠顺序区分；
  - 空正文且无思考的那条**不再落条目**，于是它那一份 `usage` 也不进合计
    （真日志里那种步通常没有 usage；真要算得靠事件级汇总，本轮没做）。
- 判据：
  - `app/test/assistant_step_projection_test.dart`（3 条）：有正文 → `MessageItem`；
    只有思考 → `ReasoningItem`；什么都没有 → 不占条目。
    **变异校验**：把分支条件退回"只判正文空"，该测与「一轮多步」那条 widget 同时红。
  - `app/test/turn_group_collapse_test.dart` 新增「一轮多步：只画一个助手头；
    思考与工具都随轮组收起」——收起时 `find.text('助手')` 恰好 1、思考与工具卡都不在；
    展开后思考行与工具卡回来、助手头仍是 1。
  - 真机（`d61cf622`）：`shots-2026-10-22/p1-one-head-collapsed.png`（61 步的轮次收起成
    一行 + 最终回答）、`p2-one-head-expanded.png`（展开：连续 8 张 `pwsh` 工具卡，无头像）。
  - 门禁：flutter **1101** / boundary **352** / analyze+format 0。
