# Agent Note: 轨迹页真时间轴 —— 电脑侧折好，手机只画

Status: implemented

## Problem

轨迹页的「时间轴」一直不存在：原型摆了四行甘特条与 640px 横滑，
`_TrajectoryTab` 只传 `entries`，轨道恒空（前一篇
`2026-10-22-trajectory-turns-only-and-duration-bars.md` 把假轨道删了，
并把「没有每步起止」记为欠账）。

欠账的根因不是"事件里没有时间"——`SessionEvent.time` 一直都在，
DSH Web 的 Overview 正是**客户端拿它现算**的
（`packages/client/ui-trajectory/src/client/layout.ts:145,166` 的
`startedAt: finiteTime(node.time)`、`:190-196` 的工具起点、
`:305-319` 的请求起止）。缺的是**手机的条目表只覆盖已加载的一页**：
`turn/start` 落在更早的页里，那一轮就没有起点，`turn/end.time - turn/start.time`
退化成"不到 1 秒"。上一轮的 `TurnProcessItem.elapsedMs` 就是这么算的，
跨批即失真。

而按 Web 那条路把减法搬到手机，等于把"翻页边界"这个失真源焊死在渲染层：
无论怎么写，窗口外的轮都算不出正确用时。

## Decision

**时间一律在电脑侧算好，随投影下发；手机只解析与画。**

1. **新投影 `trajectory`**（`connector/src/dsh/trajectory.ts`）：fold 跑在
   电脑侧的**完整日志**上，`apply` 认得 `turn/start` / `turn/end` /
   `tool/call` / `tool/result` / `assistant/message` / `compaction/*`，
   其余事件返回**同一个引用**（注册表按 `Object.is` 比较，于是纯记账事件不触发发布）。
2. **过线的形状带 `offsetMs`**：每步给"相对本轮开始"的毫秒偏移，
   x 轴位置 = `offsetMs / turn.durationMs`。这是让「手机不许自己统计时间」
   在**渲染**上也成立的关键——手机唯一的算术是一次除法，没有一次 epoch 相减。
   `startTime` / `endTime` 只作记录（排查与 tooltip），界面几何不读。
3. **`durationMs` 是唯一的时长来源**：`null` = 还在跑，界面说「进行中」，
   绝不补 0。进行中的轮 x 轴没有右端，所以**只等距摆起点标记**，不画比例。
4. **能力位挂载**：`ctx.inject(['sessionProjections'], …)`，
   服务不在就什么都不注册 —— 手机看到"缺这个键"，按缺键显示
   （`这台电脑没给时间轴：连接器没有注册 trajectory 投影…`），
   而不是让插件挂载失败或给一张空轨道。
5. **有界 + 如实报截断**：`MAX_TURNS=200` / `MAX_STEPS_PER_TURN=200` /
   `MAX_STEPS_TOTAL=1200`，超了从最旧的丢，并报 `truncated` /
   `droppedTurns` / `droppedSteps` / 每轮 `stepsTruncated`；
   手机在顶部明说被截断。
6. **手机侧删掉减法**：`projection.dart` 的 `turn/end.time - turn/start.time`
   与 `TurnProcessItem.elapsedMs` 一并删除；过程摘要的「用时」改成读
   `trajectoryTurnOf(turn)?.durationMs`。`app/lib/` 里除了"读投影 + 画"
   不再出现时间减法。
7. **`turn/end` 后重读投影**：`_onDelta` 收到 `turn/end` 就刷一次
   `session.projections`（按 sid 合流，重复触发合并成一次），
   否则进行中的那一轮永远不会从"起点标记"变成真比例。

## Alternatives considered

1. **照 Web，手机拿 `SessionEvent.time` 现算**
   - 最强的理由：数据就在手机上，零新增数据面；与 Web 形态逐像素同源。
   - 为何被否：**只在已加载窗口内成立**。手机条目表是分页来的，
     `turn/start` 落在更早一页时那一轮就没有起点，算出来是"不到 1 秒"
     —— 这正是要修的失真。把减法留在手机，等于把失真源焊在渲染层：
     无论手机怎么写，窗口外的轮都算不出正确用时。而 fold 在电脑侧跑的是完整日志。
2. **手机拿全量事件自己折（先拉完整个日志再算）**
   - 最强的理由：不动连接器，纯手机侧解决。
   - 为何被否：长会话的日志是几十 MB，过无线通道拉到手机上只为画 6dp 的条，
     代价与"手机只渲染"的分工都不成立；而且每个平台（iOS / 安卓 / 鸿蒙）
     都要各自实现一遍同样的 fold，三份实现三个答案。
3. **用 `sessionStats` 的 `llmMs` / `toolMs` 画分段**
   - 最强的理由：投影现成、零成本。
   - 为何被否：那是**会话级总量**，没有"哪一段在什么时候"，
     拿它画分段只能画出假图；而假图与真图长得一样，用户无法分辨。
4. **手机上把每步起点留在条目模型里（上一轮否掉的那条路的后半段）**
   - 最强的理由：只改 `projection.dart` 的两处（`tool/call` 写起点、
     `tool/result` 改成继承），改动最小。
   - 为何被否：它只解决"工具段的终点被覆盖"，解决不了"起点不在这一页"。
     修一半的产物是"看起来有时间轴、其实只有一半"，比没有更糟。

## Consequences

- 收益：窗口外的轮也有时间轴；每个数字只有一个来源；手机侧连一次 epoch
  相减都没有（判据可机械检查：`app/lib/` 里搜不到 `time - `）；
  投影缺席时是"缺能力"而不是"空轨道"。
- 代价：
  - **多一份要维护的投影**：DSH 的事件词表变了要跟着改 `apply`，
    且它随 `session.projections` 整包下发（几十 KB 起），所以必须有界。
  - **有界就有截断**：超过 200 轮 / 1200 步的老会话，更早的部分没有时间轴。
    这一点在界面明说，不静默丢。
  - **手机不再有"自己算"的退路**：连接器没注册这个投影，轨迹页就只有
    轮次行与"用时未知"，不会退回到一个近似值。这是有意的 ——
    近似值看起来和真值一样，用户分不出来。
  - **`turn/end` 后要多一次往返**：进行中的轮要等这次刷新才变成真比例
    （按 sid 合流，不会因为多轮并发放大成多次）。

## 证据（2026-10-22 真机）

隔离实例（`DSH_HOME=D:\tmp\dsh-e2e`、`--profile mobile-e2e`）+ 本机中转容器，
`adb reverse` 后装 debug APK，跑两轮真实会话。真值从会话日志
（`session.v4.jsonl.zstd`，拼接多帧 zstd，按魔数切帧）逐事件读出：

| 轮 | 日志 `durationMs` | 手机显示 | 结论 |
|---|---|---|---|
| 1 | 31587 | `31 秒` | 一致 |
| 2 | 19614 | `19 秒` | 一致 |

第 1 轮几何（轨道宽 1011px，`offsetMs/durationMs` 换算 vs 截图像素）：

| 段 | 期望左边界 | 实测 | 期望宽 | 实测 |
|---|---|---|---|---|
| 助手 1 | 50.1 | 50 | 118.7 | 118 |
| 工具 1 | 169.1 | 169 | 15.2 | 15 |
| 助手 2 | 186.4 | 186 | 183.6 | 182 |
| 工具 2 | 369.1 | 369 | 51.3 | 51 |
| 助手 3 | 422.1 | 422 | 173.2 | 172 |
| 工具 3 | 595.1 | 595 | 47.0 | 46 |
| 助手 4 | 643.3 | 643 | 410.6 | 409 |

全部误差 ≤ 2px（亚像素取整）。点工具段 → sheet 显示 `工具 · pwsh` / `1 秒`
（日志 1601ms）；点轮次行 → `用时 31 秒` / `计数 4 条消息 · 3 次工具`。
进行中的轮（第 2 轮未收口时）只画一个起点标记，收口后自动变成真比例
（`turn/end` 后刷新生效）。

**真机截图**：`D:\tmp\dsh-e2e\shots-1022c\`（`t05-traj-done.png` 第 1 轮时间轴、
`t11-segment-sheet.png` 工具段 sheet、`t13-turn2-running.png` 进行中只有起点标记、
`t14-turn2-done.png` 第 2 轮真比例）。

**未覆盖（缺真机证据，由单测 / widget 测代替）**：

- `truncated`（>200 轮或 >1200 步）：造这种会话要跑上百轮真请求，
  经济上不成立。由 `connector/tests/trajectory.test.ts` 的三个上限用例
  与 `app/test/trajectory_test.dart` 的截断文案用例覆盖，文档按此注明。
- 压缩段（`compaction/*`）：同上，本轮会话没有触发压缩。
- 投影缺席的空态：由 widget 测覆盖两种文案。

## 真机抓到的一个缺陷（已修，留作判据）

首次装机时**只有助手段可见，工具段整条不见**。原因：`timelineHeight` 按
"用到的泳道数"算高度（2 → 15dp），而段的位置用**语义泳道号**（工具 = 2 → top 18dp），
落到框外。修法是把"高度"和"行号"绑到同一个计数上：
`layoutTimelineSegments` 在最后把用到的泳道**紧凑成行号**（0,1,2…），
`timelineHeight` 用同一个"用到的泳道数"。颜色改为读**段的类别**而不是行号
（行号紧凑过，读它会让工具段在没压缩的轮里变成压缩色）。

判据写进了 `app/test/trajectory_test.dart`：
`timelineHeight(turn.steps) >= (max(lane)+1) * kTimelineLaneHeight`。
这条是**真机才暴露**的 —— 纯单测与 widget 测都不会渲染到框外去报警，
所以它按"量了才算数"补了一条几何不变式。
