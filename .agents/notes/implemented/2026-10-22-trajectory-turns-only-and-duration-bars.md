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

1. **这一轮就做真时间轴（手机侧用事件 `time` 现算，照 Web）**
   - 最强的理由：数据其实**就在手机上** —— 每条事件带 `time`，而 Web 的 Overview 正是
     客户端用这些 `time` 现算的（`ui-trajectory/src/client/layout.ts:145,166` 的
     `startedAt: finiteTime(node.time)`、`:190-196` 的工具调用起点、
     `trajectory-assistant-definition.ts:308-309` 的请求起止）。不缺 Host 数据面，
     只缺手机侧把起点留下来：`tool/call` 写 `updatedAt`，`tool/result` 又覆盖它
     （`app/lib/data/projection.dart:197` / `:237`）。这是与 Web 形态真正对齐的路。
   - 为何被否：这一轮的时间预算在 A/B/C 三件（两件是**静默数据丢失**的真缺陷）上，
     而时间轴要改投影层的条目形状（加 `startedAt`、`tool/result` 改成继承），
     再配一套新的行内渲染与判据 —— 那是另一件独立的事，半截做出来就是"看起来有时间轴、
     其实只有一半"。**下一轮要做的第一件事就是它**（前置条件已写进
     `docs/subsystems/trajectory-page.md` §1）。
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
- 代价：**仍然没有时间轴**。而它并不是"数据面拿不到"——事件里有 `time`，
  Web 就是客户端现算的；缺的是手机侧投影层只留了一个 `updatedAt`
  （`app/lib/data/projection.dart:197` / `:237`）。所以这是**一笔欠账，不是一道墙**：
  下一轮加 `startedAt` + 改 `tool/result` 为继承 + 行内渲染即可，
  `docs/subsystems/trajectory-page.md` §1 把这条前置条件写清楚了。
