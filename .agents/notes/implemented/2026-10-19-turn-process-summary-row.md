# Agent Note: 一轮的过程摘要（turn-process）——每轮一条收口

Status: implemented

## Problem

2026-10-19 顺着 DSH Web 的节点清单摸到的第四个缺口。

DSH Web 在**每一轮结束时**给一行摘要（`TurnProcessNodeView.tsx`）：
`用时 2 分 36 秒 · 12 条消息 · 8 次工具调用 · 1 个子智能体`，
可折叠收起该轮内容。手机上没有这一行 —— 于是一轮跑完，用户看到的就是
"又多了几屏内容"，没有"这一轮到底干了什么、花了多久"的收口。

同一天已经接了 `turn-error` / `turn-max-tokens` / `model-retry`
（`.agents/notes/implemented/2026-10-19-turn-outcome-and-model-retry.md`），
那一批把 `turn/end` 变成"只有异常才占条目"。这一批把**每轮都有的收口**补上。

## 调查

### 1. DSH 的计数不在事件里

`contract/turn-process.ts` 的 `TurnProcessSpec`：`messageCount` /
`toolCallCount` / `subagentCount` 全由 **turn 状态机**推出。
手机没有那个状态机，但有条目表 —— 数它等价。

### 2. 真形状

```json
{"type":"turn/start","seq":4,"time":1791270058171,"data":{"turn":1}}
{"type":"turn/end","seq":117,"time":1791270214061,"data":{"turn":1,
  "reason":{"kind":"aborted","reason":{"kind":"user"}}}}
```

用时 = `end.time - start.time`（真例 155890ms ≈ 2 分 36 秒），
DSH 同处就是这个差并 `Math.max(1000, …)`（`TurnProcessNodeView.tsx:23`）。

### 3. 子智能体委派的判据

`contract/turn-process.ts:44-46` 的 `isSubagentDelegationTool`：
名字是 `subagent` 或以 `subagent_` 开头。控制类工具
（`send_message` / `list_agents`）**不算** —— DSH 的原注释把两类分开列。

## Decision

### 1. `ChatProjection` 从"一条"改成"零到多条"

`turn/end` 在 DSH 上是**两个独立节点**（`turn-process` 与 `turn-error`，
各有自己的 seq 锚点，`register-node-renderers.ts:70-75`）。手机侧同一个事件
也就产出两条：过程摘要（每轮都有）+ 异常结局（只有异常）。
合成一条会让"用时"与"错误原文"抢同一行。

`items` 成为主字段，`item` 退化成 `items.first` 的便捷读法。
**单条目构造器不再是 const**（要包运行时列表）。

### 2. `AppModel._onDelta` 逐条落表 + 数计数

- **逐条落表**：`for (final projected in projection.items)`。只落第一条的
  话，异常结局会被过程摘要顶掉（这一批实测踩到：9 个既有测试因此变红，
  逐个确认是"预期变化"后更新）。
- **记 `turn/start` 的 time 与 seq**（按轮次号，只在本批内有效）：
  time 算用时、seq 当计数区间起点。
- **`_turnStatsOf(store, inBatch, startSeq, endSeq)`**：在
  `[turn/start.seq, turn/end.seq]` 区间里数 —— 助手消息 /
  `ToolCallItem`（按 `_isSubagentDelegation` 分成工具与子智能体两桶）。
  **`startSeq` 为 null（历史翻页落在窗口外）时返回全 0**：区间不明就不数，
  与"拿不到就不显示"同一条纪律（0 项在 `stats` 里不列，不会摆出
  "0 条消息 · 0 次工具"这种噪声）。

### 3. 模型与 UI

`TurnProcessItem`（turn / elapsedMs / 三个计数 / failed / stopped +
`title` 与 `stats` 两个 getter）与 `TurnProcessRow`（一行：时钟/告警图标 +
`第 N 轮` + 统计）。`stats` 的规则照 DSH：**失败/停止时换成一句话**
（`失败` / `已停止`，DSH 同处也是替换而不是附加），
**计数为 0 的项不列**。

`formatElapsedMs`：`< 1000` 说"不到 1 秒"（DSH 的 `Math.max(1000, …)`
同源，但中文里"1 秒"比"0 秒"可信，而"不到 1 秒"更准）。

## Alternatives considered（否掉的）

- **把过程摘要塞进 `TurnOutcomeItem`**（一个类型两个用途）：DSH 是两个节点，
- **在投影层数计数**：投影层是纯函数，不认识"哪些条目属于这一轮"。
- **`turn/start` 也占条目**：DSH 的 turn-process 挂在轮次**末尾**
  （`TurnProcessNodeView.tsx:18` 要求 `turn.status === 'closed'`），
  开头占一条会多一个空行。
- **UI 上做"点击收起该轮"**（DSH 的 `turnProcess.setOpen`）：那是组级交互，
  而我们没有 turn 组（消息流是平铺的）。留白，不造一个半调的折叠。

## Consequences

- 收益：每轮有一条收口（用时 + 消息/工具/子智能体计数）。
- 代价：`ChatProjection` 的 `item` 从字段降为 getter（一处签名变化）；
  `_onDelta` 多一个循环与两个私有辅助。
- 测试：`turn_outcome_test.dart` 19 项（新增过程摘要四条 +
  `TurnProcessRow` 的 widget 用例），并做了**变异验证**
  （`stats` 的分隔符一改就红）。
- 全量门禁：`flutter test 790` / `analyze 0` / `format 0` /
  `boundary 281` / `icons 100`。

## 未验证的部分（说清楚）

**真机上没看到收口行**：adb 反复被 ROM 行为打断（抽屉按钮落点、jumper
不显示、237 条的会话滚不到轮的边界）。投影（含计数规则）与渲染都有测试，
其中 `stats` 那条含变异验证；**端到端要用户随便开一个会话看一轮的末尾**。
