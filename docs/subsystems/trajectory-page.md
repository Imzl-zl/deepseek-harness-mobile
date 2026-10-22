# 轨迹页（会话详情 · 轨迹）

手机端「轨迹」分段：把当前会话**每一轮**的提问、回复、用时与计数排成一份可点开的账本。
数据全部来自电脑侧已有的两个来源，**没有甘特图，也没有「调用」明细** —— 原因见 §1 与 §4。

## 1. 数据面

| 这一行显示什么 | 来源 | 形状 |
|---|---|---|
| 轮次号 | `turnOutline` 投影 | `{turn, seq, prompt, response}`，严格按 turn 升序（`packages/session/session-turn-outline/src/projection.ts:61-75`） |
| 提问 / 回复预览 | 同上 | `prompt` ≤50 字符、`response` ≤120 字符，**预览由电脑侧截断**（同文件 `:28-31`） |
| 该轮用时 | `turn/end.time - turn/start.time` | 手机侧自己算（`app/lib/data/projection.dart:404-408`），落在 `TurnProcessItem.elapsedMs`（`app/lib/model/chat_item.dart:438-439`） |
| 消息 / 工具 / 子智能体计数 | 同上，来自该轮事件区间 | `TurnProcessItem.messageCount` / `toolCallCount` / `subagentCount` |
| 结局 | `turn/end.reason.kind` | `error` → 失败、`aborted`/`interrupted` → 已停止（`projection.dart:395-415`） |

**用时只在两个边界事件都落在手机手里的窗口内时才有值**，界面据此分三种说法：

| 情况 | 这一格 | 迷你条 |
|---|---|---|
| 这一轮有 `TurnProcessItem` 且用时 > 0 | `2 分 36 秒` | 按比例画 |
| 有它但用时为 0（`turn/start` 在更早一页，或真不到 1 秒） | `不到 1 秒`（`formatElapsedMs`，`chat_item.dart:505-511`） | **不画** |
| **没有**它（`turn/end` 都不在窗口内） | `用时未加载` | **不画** |

失败 / 已停止**替换掉这一格的文字**（`TurnProcessNodeView.tsx:24-30` 同一条），
但用时已知时条照画、只换颜色 —— "这一轮没跑完"与"跑了多久"是两件事，都该看得见。
**不摆 0，也不编一个数。**

### 为什么这一屏还没有时间轴

**数据在手机上就有**：每条会话事件都带 `time`（`core/sync_client.dart` 的 `SessionEvent.time`），
而 DSH Web 的时间轴就是**用这些 `time` 在客户端现算的**，不是 Host 投影：

| Web 的那一格 | 来源 |
|---|---|
| 一条消息 / 记录的起点 | `startedAt: finiteTime(node.time)`（`ui-trajectory/src/client/layout.ts:145,166`） |
| 一次工具调用的起点 | `tool/call` 事件的 time（同文件 `:190-196` 的 `callStartById`） |
| 一次助手请求的起止 | `startedAt: state.startTime` / `completedAt: node?.time`（`trajectory-assistant-definition.ts:308-309`） |
| 时间轴上的一段 | `cellRange` = `startedAt` + `timeSeconds`（`timeline.ts:61-67`） |

手机缺的不是数据面，是**投影层把起点丢了**：`tool/call` 先写 `updatedAt: time`
（`app/lib/data/projection.dart:197`），`tool/result` 到达时同一个条目又被覆盖成
`updatedAt: time`（同文件 `:237`）—— 起点与终点挤在同一个字段里，只剩终点。
所以真时间轴的前置条件是**手机侧保留每步起止**（给 `ToolCallItem` 加 `startedAt`、
`tool/result` 继承而不是覆盖），**不需要动 DSH**。

`turnOutline`（`{turn, seq, prompt, response}`，`projection.ts:61-75`）与 `sessionStats`
（会话级总量，`session-stats/src/projection.ts:72-81`）确实给不出每步 —— 但事件给得出，
而轨迹页的每一行本来就来自事件。进行中的记录只画开始标记、不虚构耗时
（`ui-trajectory/README.zh.md` 的「已知限制」）。

### 为什么没有「调用」明细

`ToolCallItem` 有名字、参数、结果与 diff 统计，**没有起止时间**
（`app/lib/model/chat_item.dart:599-641` 只有 `updatedAt`）。列出来只能是一份
"这一轮调了哪些工具"的清单，而同样的信息已经在对话流里、且那里能展开看参数与结果 ——
在轨迹页再列一遍是重复的第二个真值源。要做"每次调用多久"，前提与时间轴同一条：
**投影层保留 `tool/call` 的时刻**（事件里有，见上一节）。

## 2. 结构

单列、无横滑。顶部一行汇总，下面是轮次账本。

```
┌────────────────────────────────────────────┐
│ 共 12 轮 · 已知用时 8 分 12 秒（3 轮未加载）    │  11px caption
│ ┌────────────────────────────────────────┐ │
│ │ 第 12 轮              2 分 36 秒    ›  │ │  13px medium + 11px mono
│ │ ▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░ │ │  4px 迷你条（该轮 / 最长一轮）
│ │ 提问：记录一下给我新会话提示词           │ │  12px caption，1 行省略
│ │ 结果：已写进 docs/，并补了三条断言…      │ │  12.5px tertiary，2 行省略
│ │ 12 条消息 · 8 次工具 · 1 个子智能体      │ │  11px caption
│ └────────────────────────────────────────┘ │
└────────────────────────────────────────────┘
```

- **顺序**：按轮次升序（`turnOutline` 给的顺序）。内容超出一屏时**打开就滚到末尾**
  （最新一轮），往上滑看更早的轮；行数少时自然顶在上边，不留大片空白。
  不用 `reverse: true` —— 那一招在行少时会把内容顶到屏幕下半截。
- **迷你条**：长度 = `该轮用时 / 已加载轮里的最长用时`，最短 2%（1px 的条看不出有没有数据）。
  颜色是语义：正常 `roleAssistant`、失败 `error`、已停止 `roleTool`。
  拿不到用时的轮**不画条**（画一条 0 长度的空轨等于说"这一轮没花时间"）。
- **行高与点击**：整行可点（44dp 以上），行尾 `chevronRight` 只作指示、不单独可点。
- **汇总行**：`共 N 轮` 来自 `turnOutline`；`已知用时` 是已加载轮用时之和。
  有未加载的轮时**必须带括号说明有几轮**，否则"合计"会被读成全会话总时长。

## 3. 条目详情 sheet

点一行弹 `sheet-traj`：标题 `第 N 轮`。

- **短字段用 `DshKeyValue`**：用时、消息 / 工具 / 子智能体计数（各项为 0 不列）、结局（仅失败 / 已停止时出现）。
- **长文本用纵向块**：`提问` 与 `结果` 是"标签一行、正文下一行"，正文按词换行、不限行数。
  长英文放进 KV 行会撑破屏幕：`DshKeyValue` 的值是**无约束 `Text`**，
  它拿到自己的固有宽度后把标签列压到 2 字宽，整行右侧溢出（`dsh_sheet.dart:136-180`）。
  所以 `DshKeyValue` 加了可选 `multiline`（默认 `false`，统计 / 用量那几张 sheet 行为不变），
  本 sheet 的长文本走它。
- **只有一个动作：关闭**。没有「查看完整调用」这类点了只关闭面板的按钮。

## 4. 有意偏离（与 `design-and-tech-plan.md` §7.3 的原稿）

| 原稿 | 现在 | 原因 |
|---|---|---|
| 迷你甘特（横滑 640px）+ 四行轨道 | 每轮一条迷你条 | 没有每步起止（§1）；640px 在 390dp 竖屏上要先横滑才知道有内容 |
| 顶部 `[时长][轮次][调用]` 三个子分段 | 只有一个轮次视图 | 只有一个视图时摆分段就是假入口；时长以"每轮一条 + 汇总一行"给，调用明细不做（§1） |
| 竖向 ledger（上下文 / 助手 / 工具 / 错误四类条目） | 一轮一行 | 四类条目的时间与顺序只能从事件窗口推，翻页后不完整；轮次是**投影**给的、覆盖全会话 |

## 5. 验证

| 命令 | 覆盖 |
|---|---|
| `cd app && flutter test test/trajectory_test.dart` | 行规格（用时 / 未加载 / 迷你条比例 / 语义色）、单列无横滑、超一屏时锚到末尾、点行回调、空态 |
| `cd app && flutter test test/trajectory_outline_test.dart` | `turnOutline` 解析 + `buildTraceTurns` 的 join（含窗口外轮） |
| `cd app && flutter test test/dsh_sheet_test.dart` | `DshKeyValue.multiline` 在 390dp 下不溢出、标签横排 |
| 真机（411dp / 360dp） | 打开轨迹页与条目 sheet，截图里**没有黄黑 overflow 条纹**、`结果` 横排 |

判据不看"好不好看"：**没有 overflow、长文本按词换行、每个数字都有来源**。

### 5.1 真机（2026-10-22，d61cf622，隔离实例）

截图在 `D:\tmp\dsh-e2e\shots-1022\`，**不进仓库**。

| 项 | 结论 | 证据 |
|---|---|---|
| 一轮一行 + 汇总行 | 过 | `a10-trajectory-final.png`：`共 1 轮 · 用时 10 分 40 秒`，下一行就是 `第 1 轮`（行少时不留空洞） |
| 迷你条按比例 | 过 | `a02-trajectory.png`（两轮 1 分 37 秒 / 51 秒）：两条长度 ≈ 97:51 |
| 条目 sheet 不溢出 | 过 | `a11-sheet-final.png`（411dp）与 `a13-360dp-sheet.png`（360dp）：无条纹，`结果` 横排、按词换行，提问 / 结果是纵向块 |
| 单列无横滑 | 过 | 两档宽度下都没有 640px 固定宽度，也没有横滑提示 |
| 窗口外的轮说「用时未加载」 | 未造出 | 这个会话只有 1 轮且两个边界事件都在窗口里；由 `trajectory_outline_test.dart` 覆盖 |
