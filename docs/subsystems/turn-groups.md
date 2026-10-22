# 会话流的轮组（turn 分组 + 可折叠过程）

会话流里**一轮**是一个可折叠的组：组头是那一条 `第 N 轮 · 用时 · 条数 · 工具数` 收口行，
点它收起 / 展开这一轮的过程。运行中的一轮**不折**（组头根本不出现）。

## 1. 分组边界

边界来自**条目自己的轮号**（`ChatItem.turn`）：

| 来源 | 谁带轮号 |
|---|---|
| 事件自带的 `data.turn` | `turn/start` 的记账条目、`assistant/message`、`tool/call`、`tool/result`、`system/message` |
| 由 `AppModel` 按"最近一次 `turn/start`"补 | `user/message`、`command/*`、`llm/retry*`、`compaction/*` |
| 都没有（历史窗口没加载到那一轮的起点 / 老连接器） | 落进"未归属组"，**永不折叠** |

真机日志的次序是 `turn/start` → `step/start` → `user/message`（`session-4f50055e…`：
seq 93 → 95 → 96），所以用户那句话属于**它前面那个** `turn/start`。

切分在 `app/lib/model/turn_groups.dart`（纯函数）：轮号一变就是新的一组；
`turn/start` 之前若还有条目，那些是 `turn == null` 的未归属组。

## 2. 折叠藏什么

| 收起时**隐藏** | 收起时**保留** |
|---|---|
| 工具卡、命令卡、模型重试、压缩卡、**中间步骤的思考行**、最终回答自带的思考行 | 用户消息、助手正文、收口行（复制 / 用量）、审批与提问卡 |

依据 DSH：折叠的是 `processMember`（`packages/client/ui-chat/src/client/chat/ChatNodeSeat.tsx:78-83`），
用户消息与最终回答是独立节点、始终可见；审批与提问是**等用户决策**的东西，收起来等于让人找不到待办。

## 2.1 一个 turn 只有一个「助手」

一个 turn 的 `assistant/message` **每个 step 一条**（真日志：第 1 步 `reasoning + tool-call`、
第 2 步 `reasoning + text`）。只有**带正文**的那条是"一条助手消息"：

| 这一步的 content | 条目 | 渲染 |
|---|---|---|
| 有正文 | `MessageItem`（role assistant） | 「助手」头 + 思考行 + 正文 |
| 只有思考 | `ReasoningItem` | 一行「思考过程」（**无头像**，过程行） |
| 都没有（只有 `tool-call`） | 不落条目 | 无 |

"几条消息"的计数也只数带正文的那条（DSH 的 `hasAssistantReplyContent`，
`packages/client/ui-chat/src/client/contract/assistant-content.ts:9-15`）。

**头像的位置在组开头**（`assistantHeadItemIds`，`model/turn_groups.dart`）：
一轮里第一条"助手侧"条目（思考 / 工具 / 重试 / 助手正文）上方画一次，
于是长轮次的头像在最上面，不在中途。两条细节：

- **按折叠后仍然可见的条目算**：收起一轮时被藏掉的那条不能是头像落点，
  否则头会跟着过程一起消失（折叠后整轮没有助手段）；
- **命令卡与压缩卡不拿头**（斜杠命令是用户发起、压缩是系统行为，主语不是助手），
  它们仍然随轮组收起。

## 3. 什么时候可折

`TurnGroup.collapsible` = **有轮号 + 有过程条目 + 已收口**（组里出现过
`TurnProcessItem` / `TurnOutcomeItem`）。判"已收口"看的是"出现过"而不是"最后一条"
—— `turn/end` 之后还会落几条没有轮号的记账事件，判最后一条会让已收口的一轮没有箭头。

运行中的一轮不可折：DSH 的整轮控制行在 `turn.status !== 'closed'` 时整行不渲染
（`TurnProcessNodeView.tsx:18`），我们同一条。

## 4. 与 DSH 的差异（有意偏离）

DSH 的整轮控制行在**轮次开头**（`turn.start.seq − 0.1`，
`conversation-nodes/common.ts:18` 的 `processControl`），另有独立的 `turn-tail` 行放复制与用量。
手机这一版把两者合成**一行、落在轮次末尾**：内容本来就在上方，点末尾那行把上面收起来
比在开头放一条更省手指，也少一行 chrome。代价是"折叠开关在它所控制的内容下方"。

## 5. 「工作步骤收起时机」

设置页「通用」组的一行（`app/lib/model/preferences.dart` 的 `CollapseTiming`，两档）：

| 档 | 落盘值 | 行为 |
|---|---|---|
| 回答结束后（默认） | `completion` | 轮次一收口就收起 |
| 下次有新消息时 | `next-input` | 收口后仍展开，直到用户发出下一句（判据是"它是不是最后一组"，不是"最后一个可折的轮"） |

与 DSH 的两档同名同义（`packages/client/ui-chat/src/chat-settings.ts:15,21`，默认 `completion`）。
**存手机本地**（键 `collapse_timing`），与「工作步骤展示 / 性能与用量」同一条；
电脑侧可写的三个 `(ns,path)` 不动。

## 6. 判据

- 纯函数 `app/test/turn_groups_test.dart`（11 条）：切分、重复 `turn/start`、
  历史窗口按轮号分组、可折条件三种、收藏范围、未归属组不折、按轮分别判。
- 页面 `app/test/turn_group_collapse_test.dart`（4 条）：收口后默认收起 → 点开 → 再收；
  **一轮多步只画一个助手头**（思考与工具随组收起）；空正文的助手消息不留空行；
  `next-input` 档最新一轮默认展开、上一轮收起。
- 投影 `app/test/assistant_step_projection_test.dart`（3 条）：有正文 → 助手消息；
  只有思考 → 过程行；都没有 → 不占条目。
- 真机（`d61cf622`，2026-10-22）：`shots-2026-10-22/n1-collapsed-clean.png`（收起：
  只剩提示 + 回答 + `第 5 轮 ⌄`）与 `n2-expanded.png`（展开：`run_code` 卡回到提示与回答之间）；
  设置页 `n3-settings-row.png`（「工作步骤收起时机 · 回答结束后」）。

## 7. 已知边界

- **历史窗口不全**时，那一轮的 `turn/start` 可能没加载：该组仍是未归属、不折（如实降级，
  不补零也不猜轮号）。
- **断线期间**收口的一轮要等重连收到事件后才可折（与运行条同一条边界）。
- 折叠会让列表格数变化（`reverse: true`）：目前收起/展开后不调整滚动位置，
  极端情况下点开的地方在屏幕外 —— 见 `.agents/notes/implemented/2026-10-22-turn-groups-phase-1.md`
  的 Consequences。
