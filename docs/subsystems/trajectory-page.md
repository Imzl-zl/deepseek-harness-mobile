# 轨迹页（会话详情 · 轨迹）

手机端「轨迹」分段：把当前会话**每一轮**排成一份可点开的账本 —— 每轮一行，
行下一格时间轴（横向 = 这一轮的起止，纵向 = 模型 / 压缩 / 工具三条泳道）。

## 1. 一条硬规则：时间由电脑侧算

**手机不统计时间。** 每一轮、每一步的起止与时长都由连接器折好、随
`session.projections` 下发；手机只做两件事：**解析**（`model/trajectory.dart`）
与**画**（`ui/trajectory_timeline.dart`）。

判据（`app/lib/` 里可以机械扫的）：不出现 `turn/end.time - turn/start.time`
这类相减。时间轴几何里唯一的算术是**除法** —— 位置 = `offsetMs / turn.durationMs`、
长度 = `durationMs / turn.durationMs`，两个操作数都是投影给的。

连接器侧的投影定义在 `connector/src/dsh/trajectory.ts`（键 `trajectory`）：

| 字段 | 谁算 | 说明 |
|---|---|---|
| `turn.startTime` / `endTime` | 电脑侧（事件 `time`） | **只作记录**，界面不用它做几何 |
| `turn.durationMs` | 电脑侧 | `endTime - startTime`；进行中的轮是 `null` |
| `turn.outcome` | 电脑侧 | `TurnEndReason.kind` 原样（`completed` / `error` / `aborted` / `interrupted` / `blocked` / `max-tokens` / `forked`），未收口是 `null` |
| `step.offsetMs` | 电脑侧 | 相对这一轮起点的毫秒数 —— **时间轴的水平位置就是它** |
| `step.durationMs` | 电脑侧 | 这一步的时长；还在跑的步是 `null` |
| `step.isError` | 电脑侧 | 工具失败 / 助手消息 `interrupted` |
| `truncated` / `droppedTurns` / `droppedSteps` | 电脑侧 | 上限丢了多少（`MAX_TURNS=200`、`MAX_STEPS_PER_TURN=200`、`MAX_STEPS_TOTAL=1200`） |

形状与上限写死在 `connector/src/dsh/trajectory.ts` 的 `viewSchema` / 常量；
连接器测试 `connector/tests/trajectory.test.ts` 逐个键钉住（键集合断言在
`['durationMs','endTime','isError','kind','label','offsetMs','seq','startTime']`）。

## 2. 行的数据面

| 这一行显示什么 | 来源 | 形状 |
|---|---|---|
| 轮次号 | `turnOutline` 投影 | `{turn, seq, prompt, response}`，按 turn 升序（`packages/session/session-turn-outline/src/projection.ts:61-75`） |
| 提问 / 回复预览 | 同上 | `prompt` ≤50 字符、`response` ≤120 字符，**预览由电脑侧截断**（同文件 `:28-31`） |
| 该轮用时 | `trajectory` 投影的 `durationMs` | `formatElapsedMs` 只把它说成人话 |
| 时间轴 | `trajectory` 投影的 `steps` | 见 §3 |
| 消息 / 工具 / 子智能体计数 | 该轮 seq 区间内的条目 | `TurnProcessItem.messageCount` / `toolCallCount` / `subagentCount` |
| 结局 | `trajectory` 投影的 `outcome` | `error` → 失败、`aborted`/`interrupted` → 已停止；投影不在时退回 `turn/end.reason.kind` |

**行的来源是 `turnOutline`，不是 `trajectory`**：后者只保留最近
`MAX_TURNS` 轮，用它当行源会让被上限截掉的老轮整行消失 —— 看起来像那一轮
不存在。用 `turnOutline` 当行源、`trajectory` 只补时间轴，老轮就仍然是
「用时未知」，这是两句不同的话。

行尾这一格有四种说法，各自对应不同事实：

| 情况 | 这一格 |
|---|---|
| 投影里有这一轮，且已收口 | `2 分 36 秒` |
| 投影里有这一轮，但还在跑（`durationMs == null`） | `进行中`（时间轴只画起点标记，§3） |
| 投影里**没有**这一轮（被上限截掉，或这台电脑没注册投影） | `用时未知` |
| 结局是失败 / 已停止 | `失败` / `已停止`（替换掉时长，`TurnProcessNodeView.tsx:24-30` 同一条） |

**不摆 0，也不编一个数。**

## 3. 时间轴

```
┌────────────────────────────────────────────┐
│ 共 12 轮 · 已知用时 8 分 12 秒 · 1 轮进行中    │  11px caption
│ 时间轴不全（更早的 3 轮 · 12 步 没保留）…      │  仅 truncated 时出现
│ ┌────────────────────────────────────────┐ │
│ │ 第 12 轮              2 分 36 秒    ›  │ │  13px medium + 11px mono
│ │ ▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │ │  6px 泳道（模型）
│ │ ░░░░░░▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░ │ │  6px 泳道（工具）
│ │ 提问：记录一下给我新会话提示词           │ │  12px caption，1 行省略
│ │ 结果：已写进 docs/，并补了三条断言…      │ │  12.5px tertiary，2 行省略
│ │ 12 条消息 · 8 次工具 · 1 个子智能体      │ │  11px caption
│ └────────────────────────────────────────┘ │
└────────────────────────────────────────────┘
```

### 3.1 泳道

照 DSH 的分法（`packages/client/ui-trajectory/src/client/timeline.ts:51-55`：
工具一条、消息（含压缩）一条、上下文一条）：

| 语义泳道 | 装什么 | 颜色 |
|---|---|---|
| 0（上） | 助手请求（`step/start` … `assistant/message`） | `roleAssistant` |
| 1（中） | 压缩（`compaction/*`） | `roleContext` |
| 2（下） | 工具调用（`tool/call` … `tool/result`） | `roleTool` |

顺序**固定**，不按出现先后重排 —— 同一轮里模型段永远在最上面。
只画这一轮实际用到的泳道（没用到的泳道不占高度）。

**语义泳道号 ≠ 行号**：`layoutTimelineSegments` 在最后把用到的泳道**紧凑成行号**
（0,1,2…），`TimelineSegment.lane` 带的是行号。没有压缩段的轮里工具就在第 1 行 ——
直接拿语义号当行号会摆到"第 2 行"，而控件高度只有 `用到泳道数 × 6dp + 间隙`，
那段就画到框外面（2026-10-22 真机实测：工具段整条不可见）。所以：

- 行号由 `layoutTimelineSegments` 紧凑分配，`timelineHeight(steps)` 用**同一个计数**（用到的泳道数）算高度，两者永远一致；
- **颜色读段的类别**（`colorOf`），不读行号 —— 行号紧凑过，拿它挑颜色会让工具段在没压缩的轮里变成压缩色。

### 3.2 进行中的轮：只画起点标记

`durationMs == null` ⇒ x 轴没有右端，任何"位置"都是编的。此时**不画比例**，
按 seq 顺序等距摆起点标记（3dp），明确表示"有个开头"。等 `turn/end` 到了、
投影重读之后才变成真比例。

### 3.3 过窄段合并（规则明写，不静默丢）

窄屏上一轮可能有上百段，`offsetMs / durationMs` 落成像素后很多段不足 1dp。
规则在 `layoutTimelineSegments`（纯函数，可单测）：

1. 原始宽度 < `kTimelineMinSegmentWidth`（3dp）算**过窄**；
2. **同一条泳道内连续**的过窄段合成一格：左边界取第一段、右边界取最后一段；
3. 合并格保住它**全部的原始段**（`TimelineSegment.steps`）—— 点它时 sheet
   把每一段都列出来，所以一段都没丢，只是画在了一格里；
4. 颜色：格里有失败就是失败色，否则用第一段的类别色；
5. 钳位（每段至少 3dp）在**合并之后**做 —— 先钳再判会让每段都 ≥3dp，
   合并规则永远不触发。

点中判定在 `segmentAt`：整条轨道一个 `GestureDetector`，命中靠它按
`dx` 反查（3dp 的段自己收不到点击），左右各放宽 `kTimelineHitSlop`（4dp）。
点空白处返回 `null`，**不硬塞最近的一段**。

### 3.4 不横滑

时间轴的宽度就是父级给的可用宽度。原型 `.gantt-in { width:640px }` 是桌面
形态；390dp 竖屏上先横滑才知道有内容。密度问题由 §3.3 的合并解决。

### 3.5 截断要说出来

`trajectory.truncated` 为真时，汇总行下面多一行：
`时间轴不全（更早的 N 轮 · M 步 没保留）：电脑侧只保留最近的若干轮与步。`
被截掉的轮与"本来就没有时间轴"在界面上长得一模一样，不说就分不清。

`truncated` 的**真机证据缺失**（造出 200 轮以上的会话成本过高）：
这一条由单测 + widget 测覆盖（§6），文档在此明记。

## 4. 结构

单列、无横滑。顶部一行汇总（+ 截断说明），下面是轮次账本。

- **顺序**：按轮次升序（`turnOutline` 给的顺序）。内容超出一屏时**打开就滚到末尾**
  （最新一轮），往上滑看更早的轮；行数少时自然顶在上边，不留大片空白。
  不用 `reverse: true` —— 那一招在行少时会把内容顶到屏幕下半截。
- **行高与点击**：整行可点，行尾 `chevronRight` 只作指示、不单独可点。
- **汇总行**：`共 N 轮` + `已知用时 X`（已收口轮之和）+ `N 轮进行中` +
  `N 轮用时未知`。有拿不到的轮时**必须带"已知"二字**，否则合计会被读成全会话总时长。

## 5. 详情 sheet

**点一行** → `sheet-traj`，标题 `第 N 轮`：

- **短字段用 `DshKeyValue`**：用时、计数（各项为 0 不列）、时间轴截断说明；
- **长文本用纵向块**（`DshKeyValue.multiline`）：`提问` 与 `结果` 是"标签一行、
  正文下一行"，按词换行、不限行数。长英文放进 KV 一行会撑破屏幕：
  `DshKeyValue` 的值是**无约束 `Text`**，它拿到固有宽度后把标签列压到 2 字宽，
  整行右侧溢出（`dsh_sheet.dart` 的类文档）；
- **只有一个动作：关闭**。没有点了只关闭面板的假按钮。

**点一格时间轴** → 同一形态的面板，标题 `第 N 轮 · M 段`（M>1 时）：

- 每段一行：`工具 · read` / `助手消息` / `压缩` + 时长；
- 时长读 `durationMs`；失败与时长**并列**（`失败 · 1 秒`），因为段的粒度上
  "多久"与"成没成"塞得下两个；还在跑的段说 `进行中`，不补 0；
- 合并格（§3.3）在这里**逐段列出**，并多一行说明"这几段在时间轴上挨得太近，
  画成了一格"。

## 6. 验证

| 命令 | 覆盖 |
|---|---|
| `cd connector && pnpm test tests/trajectory.test.ts` | fold 纯函数（键集合 / `offsetMs` 不变式 / 三个上限）+ 接线（键真的出现在 `session.projections` 里） |
| `cd app && flutter test test/trajectory_test.dart` | 行规格、时间轴几何（位置 / 长度 / 泳道）、进行中只画标记、合并规则与"一段都不少"、`truncated` 文案、空态两种、无假入口、390dp 不横滑 |
| `cd app && flutter test test/trajectory_outline_test.dart` | `turnOutline` 解析 + `buildTraceTurns` 的 join（投影缺席 / 进行中 / 结局以投影为准） |
| `cd app && flutter test test/turn_outcome_test.dart` | 过程摘要**不再**算时长；`statsWith` 只拼串 |
| `cd app && flutter test test/dsh_sheet_test.dart` | `DshKeyValue.multiline` 在 390dp 下不溢出 |

判据不看"好不好看"：**没有 overflow、每个数字都有来源、进行中的轮没有假比例**。

### 6.1 与 DSH Web 对齐

数字以 DSH Web 为准（差 >1 秒即错）。同一会话在两侧各看一轮的用时：
两侧都读 `turn/start.time` 与 `turn/end.time`，差别只在**谁做减法**
（Web 在客户端、手机在连接器）。进行中的轮两侧都不给时长。

### 6.2 真机证据

见 `.agents/notes/implemented/2026-10-22-trajectory-timeline-from-host-projection.md`
的「证据」一节（含截图文件名与未覆盖项）。

## 7. 有意偏离（与 `design-and-tech-plan.md` §7.3 的原稿）

| 原稿 | 现在 | 原因 |
|---|---|---|
| 迷你甘特（横滑 640px）+ 四行轨道 | 每轮一格时间轴（3 泳道，不横滑） | 640px 在 390dp 竖屏上要先横滑才知道有内容；密度由合并规则解决（§3.3） |
| 顶部 `[时长][轮次][调用]` 三个子分段 | 只有一个轮次视图 | 只有一个视图时摆分段就是假入口 |
| 竖向 ledger（上下文 / 助手 / 工具 / 错误四类条目） | 一轮一行 | 四类条目的时间与顺序只能从事件窗口推，翻页后不完整；轮次是**投影**给的、覆盖全会话 |
| 时间轴在客户端用事件 `time` 现算（DSH Web 的做法） | 电脑侧折好 `offsetMs` 下发 | 手机侧的 `SessionEvent.time` 只在已加载窗口内完整，翻页后的轮会退化成"不到 1 秒"（2026-10-22 之前的症状） |
