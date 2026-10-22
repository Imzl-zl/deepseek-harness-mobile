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
| 工具卡、命令卡、模型重试、压缩卡 | 用户消息、助手正文（含思考行）、收口行（复制 / 用量）、审批与提问卡 |

依据 DSH：折叠的是 `processMember`（`packages/client/ui-chat/src/client/chat/ChatNodeSeat.tsx:78-83`），
用户消息与最终回答是独立节点、始终可见；审批与提问是**等用户决策**的东西，收起来等于让人找不到待办。

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
| 下次有新消息时 | `next-input` | 收口后仍展开，直到下一轮开始（只有最新那一轮保持展开） |

与 DSH 的两档同名同义（`packages/client/ui-chat/src/chat-settings.ts:15,21`，默认 `completion`）。
**存手机本地**（键 `collapse_timing`），与「工作步骤展示 / 性能与用量」同一条；
电脑侧可写的三个 `(ns,path)` 不动。

## 6. 判据

- 纯函数 `app/test/turn_groups_test.dart`（11 条）：切分、重复 `turn/start`、
  历史窗口按轮号分组、可折条件三种、收藏范围、未归属组不折、按轮分别判。
- 页面 `app/test/turn_group_collapse_test.dart`（3 条）：收口后默认收起 → 点开 → 再收；
  空正文的助手消息不留空行；`next-input` 档最新一轮默认展开、上一轮收起。
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
