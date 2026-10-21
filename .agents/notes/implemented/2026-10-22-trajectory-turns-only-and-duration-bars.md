# Agent Note: 轨迹页只做「轮次」一屏，时间轴等有每步起止再谈

Status: implemented

## Problem

轨迹页原本照原型摆了四行甘特条（输入 / 模型 / 工具 / 错误）与 640px 横滑，
而**每一行的数据源都不存在**：`_TrajectoryTab` 只传 `entries`、`rows` 恒为 null，
甘特永远空着；顶部那三个 chip（时长 / 轮次 / 调用）也没有 `onTap`。
用户在真机上问「时间轴，轮次，调用都没有啊」，又在同一屏上撞到
`RIGHT OVERFLOWED BY 474 PIXELS`（条目 sheet 里一整句英文把「结果」挤成竖排）。

更关键的是**数据面**：`turnOutline` 只有 `{turn, seq, prompt, response}`
（`packages/session/session-turn-outline/src/projection.ts:61-75`），
`sessionStats` 是会话级总量（`packages/session/session-stats/src/projection.ts:72-81`）——
两者都给不出"每一步什么时候开始、花了多久"。Web 的 Overview 不是读投影，
而是用**客户端手里的事件时间**现算（`ui-trajectory/src/client/timeline.ts:61-67`），
而手机的条目模型没保留每步的 `startedAt` / `timeSeconds`。

## Decision

轨迹页只保留**一个「轮次」视图**：一轮一行（用时 + 用时迷你条 + 提问 / 结果预览 + 计数），
点开是纵向块详情。甘特与「调用」明细**不做**，直到有每步起止的数据面。

准入门槛（可机械判定）：

1. **每个数字都有来源**：轮次与预览来自 `turnOutline`，用时来自
   `turn/end.time - turn/start.time`（`TurnProcessItem.elapsedMs`），
   计数来自该轮事件区间。没有 `TurnProcessItem` 的轮说「用时未加载」，**不摆 0**。
2. **迷你条是比例**：长度 = 该轮用时 / 已加载轮里的最长用时（最短 2%），
   拿不到用时的轮不画条（0 长度的空轨等于说"这一轮没花时间"）。
3. **单列、不横滑**：390dp 上不许出现 640px 固定宽度（`trajectory_test.dart` 断言）。
4. **长文本走纵向块**：`DshKeyValue` 新增可选 `multiline`（默认 `false`，
   统计 / 用量那几张 sheet 形态不变），条目 sheet 的提问 / 结果用它；
   390dp 下不溢出、标签横排（`dsh_sheet_test.dart` 断言）。
5. **不摆假入口**：没有三个平级 tab、没有搜索钮、条目 sheet 只有一个「关闭」
   （原来那个「查看完整调用」是 `onPressed: pop()`）。

## Alternatives considered

1. **Host 侧加"每步起止"投影，照 Web 做真时间轴**
   - 最强的理由：那是唯一能同时支撑甘特与「调用」明细的数据面，
     而且与 Web 的形态真正对齐（它是用户最初的要求："完全没对齐 web"）。
   - 为何被否：这一轮的时间预算在 A/B/C 三件上，而新投影要动
     DSH 侧的投影注册 + 契约 §5.7 + 连接器透传 + 手机解析四层；
     更糟的是它得先定"步"的边界（DSH 的 step 与事件不是一对一），
     那是设计题不是实现题。先把**能诚实显示的部分**做对。
2. **用 `sessionStats` 的 `llmMs` / `toolMs` 画分段甘特**
   - 最强的理由：投影现成、零成本，看上去"有时间轴了"。
   - 为何被否：那是会话级总量，拿它画分段只能画出假图（`memory.md` 已记过这条），
     而假图与真图长得一样，用户无法分辨。
3. **保留 640px 甘特 + 横滑，只把空数据换成"暂无"**
   - 最强的理由：改动最小，桌面形态原样保留。
   - 为何被否：横滑区占掉一屏高度却只有四行空轨道；而 390dp 上
     用户要先横滑才知道有没有内容 —— 这正是用户说的"要考虑屏幕空间"。
4. **三个视图（时长 / 轮次 / 调用）都做，用 tab 切换**
   - 最强的理由：与 Web 的 toolbar 结构一致，看起来"对齐了"。
   - 为何被否：只有一个视图有数据源，摆三个 tab 就是上一轮刚删掉的那种假入口。

## Consequences

- 收益：轨迹页每个格子都有来源；`DshKeyValue` 的溢出根因被修在组件层
  （`multiline`），将来任何长文本 sheet 直接复用；640px 横滑与假 chip 一起消失。
- 代价：**仍然没有时间轴**。用户要的"甘特/每步耗时"必须等数据面，
  而那是 Host 侧改动（新投影或条目模型保留每步起止），不是前端能补的；
  `docs/subsystems/trajectory-page.md` §1 把这条前置条件写死了，
  下一次想"顺手画个甘特"的人会先撞到它。
