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
| 工具卡、命令卡、模型重试、压缩卡、内联 diff、变更文件、**过程产出的图片**、**中间步骤的思考行**、最终回答自带的思考行 | 用户消息、助手正文、收口行（复制 / 用量）、审批与提问卡 |

「过程产出的图片」指这一轮干活时产生的截图 / diff 图；**用户自己发的附件**在用户气泡里，
不属于这一类，始终可见。

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
一轮里第一条"助手侧"条目上方画一次，于是长轮次的头像在最上面，不在中途。
"助手侧"= 助手正文、**上下文注入行**、思考、工具、重试。三条细节：

- **上下文注入行算助手侧**：它是"电脑侧塞给模型的东西"，属于这一轮的助手块 ——
  头像画在它上面，三行 `上下文注入 · runtime-context / skill-catalog / time-context`
  因此都落在头像**下面**（用户 2026-10-23：「应该都在图标下面」）。
  判据是 `MessageItem.systemHint != null`；
- **系统提示词不算**：它只有标题没有 `systemHint`，而且在用户那句话之前 ——
  拿它当锚点会让头像跑到问题上面；
- 头像旁边那行名字是 App 名 **`DeepSeek Harness`**（`kAppName`），不是「助手」。

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

组头右侧一枚箭头：**收起朝下、展开朝上**（DSH 是 `chevronDown` + `rotate(180deg)`，
`TurnProcessNodeView.module.css:37-39`；落地端 `chat_turns.dart` 的 `TurnProcessRow` 同一条）。
没有过程条目的一轮画的是收口行本身、**不画箭头** —— 点了没有东西可收，箭头会骗人点。

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

- 纯函数 `app/test/turn_groups_test.dart`（17 条）：切分、重复 `turn/start`、
  历史窗口按轮号分组、可折条件三种、收藏范围、未归属组不折、按轮分别判、
  助手头落点（含"折叠后按可见条目算""命令卡不拿头""夹记账事件也只画一个头"）。
- 页面 `app/test/turn_group_collapse_test.dart`（4 条）：收口后默认收起 → 点开 → 再收；
  **一轮多步只画一个助手头且头在最上面**（位置断言 + 思考与工具随组收起）；
  空正文的助手消息不留空行；`next-input` 档最新一轮默认展开、上一轮收起。
- 投影 `app/test/assistant_step_projection_test.dart`（3 条）：有正文 → 助手消息；
  只有思考 → 过程行；都没有 → 不占条目。
- 原型 `mock/proto/tools/verify-turns.mjs`（60 项，需 headless）：未归属组不折、
  收口后默认收起（工具卡 / 内联 diff / 变更文件 / 图片 / 思考行都不在）、点组头展开再收起、
  组头文案三段与用量 / 复制、一个 turn 只有一个助手头（命令卡与压缩卡不拿头）、
  审批与提问卡不随收起、运行中的一轮没有组头、打断也是收口、「工作步骤收起时机」两档与手动优先。
- 真机（`d61cf622`，2026-10-22）：`shots-2026-10-22/n1-collapsed-clean.png`（收起：
  只剩提示 + 回答 + `第 5 轮 ⌄`）与 `n2-expanded.png`（展开：`run_code` 卡回到提示与回答之间）；
  设置页 `n3-settings-row.png`（「工作步骤收起时机 · 回答结束后」）。

## 6.1 非人消息：上下文注入 vs 唤醒通知（2026-10-28 对齐 DSH）

`user/message` 不一定"人说的"：`data.source.kind !== 'user'` 的都是**注入**
（运行时上下文 / 技能目录 / 子代理完成通知…）。桌面拆成两种节点，手机照同一条：

| DSH 节点 | 判据 | 标题 |
|---|---|---|
| `context` | 注入，但**不是**它唤醒这一轮 | 「上下文注入」+ 生产者 kind（`runtime-context` …） |
| `turn-trigger` | 注入，且被 `inbox-next-turn` claim 走 | 按 `source.kind` 换词：`subagent-settled` =「子任务状态更新」、`agent-message` =「收到任务消息」、`tool-jobs` =「后台任务状态更新」…（表外 →「收到执行请求」） |

出处：分类 `ui-chat/src/client/conversation-nodes/message.ts:96-111`；标题表
`chat/turn-trigger.ts:29-70` + `locale.ts:53-62`；形状
`TurnTriggerNodeView.tsx:39-42`（只有标题 + 时间 + 箭头，**没有**「· 生产者」尾巴）。

分类只在 `app/lib/data/projection.dart`；"谁被 claim"只在 `AppModel` 的
`_InboxTracker`（`claimIfWaking` / `claimIfSteering`）—— 投影层是纯函数。

## 7. 已知边界

- **历史窗口不全**时，那一轮的 `turn/start` 可能没加载：该组仍是未归属、不折（如实降级，
  不补零也不猜轮号）。
- **断线期间**收口的一轮：运行条在重连时按 `session.list` 重建（`running-cues.md` §3），
  但这一轮的**收口行**仍要等 `turn/end` 事件到达才出现（组头只由 `turn/end` 落表产生）——
  两者不再是同一条边界。
- 折叠会让列表格数变化（`reverse: true`）：目前收起/展开后不调整滚动位置，
  极端情况下点开的地方在屏幕外 —— 见 `.agents/notes/implemented/2026-10-22-turn-groups-phase-1.md`
  的 Consequences。
