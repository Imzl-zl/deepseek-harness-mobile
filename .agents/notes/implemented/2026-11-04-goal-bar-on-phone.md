# Agent Note: 目标条落在手机上 —— 只读投影，动作全走 `/goal`

Status: implemented

## Problem

DSH 的「目标」是输入框上方的一条 dock（`conversation.input.dock` 里 order 10 的那一格），
不是聊天消息：`/goal <objective>` 建一个跨轮次的目标，条子上给暂停 / 恢复 / 编辑 / 清除。
手机侧三件事都没有：

1. **没有这条界面**：底部 dock 栈只有接管卡 / 排队条 / 输入栏 / 统计条；
2. **没有数据**：`goal` 投影从没被 `session.projections` 的解码层读过
   （`app/lib/wire/rpc/projections.dart` 的键表只有 14 个）；
3. **没有刷新时机**：投影只在 `notification` / `openSession` / `connectLanding` /
   `appResume` / `viewFocus` 重读，而"电脑上改了目标"这三条一条都不命中 ——
   症状会是"桌面暂停了目标，手机那条一直显示进行中"。

还有一条形状上的硬约束：**DSH 的四个动作是 `goals` 的 `@Remote`**
（`packages/goal/goal/src/index.ts:330,353,365,434`），而手机这条通道的方法面里
**没有** `goal.*`（`connector/src/protocol/methods.ts`）。

## Decision

**照 DSH 画一条 36dp 的 dock；数据只读 `goal` 投影；四个动作走 `/goal …` 斜杠命令；
`goal/change` 到达就重读一次投影。**

可机械判定的四条：

1. **数据只有一处**：键名只在 `app/lib/wire/rpc/projections.dart`，解析只在
   `app/lib/model/goal.dart` 的 `parseGoalView`，界面读 `AppModel.goal`。
   必填字段缺失 / 阶段不在四值里 ⇒ **整个目标当没有**（不猜 —— 阶段决定画哪几个按钮）。
2. **可见性只有一条**：`complete` 与"没有目标"都不画条（`GoalBar.tsx:86` 同一条），
   由 `GoalView.visible` + `GoalBar.build` 表达，`goal_bar_test.dart` 逐态钉住。
3. **动作不发新方法**：`/goal pause` / `/goal resume` / `/goal clear` / `/goal edit <objective>`，
   走已放行的 `command.execute`（`connector/src/handlers.ts:88` 的 `MOBILE_COMMANDS`）；
   失败按 `CommandOutcome` 的既有三段式呈现（与 `chat_page.dart` 的 `_switchPermission` 同一套）。
4. **刷新与 `turn/end` 同一个合并闸**：`AppModel._onDelta` 见到 `goal/change` 记一笔，
   循环结束后 `_refreshProjectionsOnce(sid)`（在飞 + 攒一次，同批两条信号只发一次请求）。

## Alternatives considered

1. 给连接器加 `goal.get` / `goal.pause` / `goal.resume` / `goal.clear` / `goal.edit` 五个方法
   - 最强的理由：与 DSH 的 Remote 一一对应，动作带 `{id, revision}` 的 CAS 语义，
     **不会在对话流里落命令卡**，也就不用把 `/goal` 的命令文本当协议用。
   - 为何被否：方法面是契约（§5.7 的 50 个方法）、金样、错误码表、幂等键四处的同一张表 ——
     加五个方法要同改四处，并重新生成 `wire-shapes.json`；而 `/goal` 这条命令已经放行，
     且 `command-goal` 内部做的就是那四个 Remote 的调用（`command-goal/src/index.ts:161-174`），
     CAS 由宿主自己按当前状态取 ref（`goal/src/index.ts:458-468` 的 `expectCurrent`）——
     手机连"revision 过期"这个错误都碰不到。走命令不是降级，是把 CAS 交回给宿主。
2. 不画条，只在 `/goal` 的命令卡里看结果
   - 最强的理由：零新界面、零新解析，命令卡已经会显示 `Status:` / `Rounds:` / `Commands:`。
   - 为何被否：命令卡会随对话流滚出视野，而目标的整个意义是**跨轮次**可见 ——
     用户要的是"现在这一屏在往哪跑"，不是"翻回去看上一次 `/goal` 的输出"。
3. 引 `GoalActivation`（`armed` / `disarmed`），让暂停钮只在 armed 时出现
   - 最强的理由：这才是 DSH 的完整判据 —— `GoalBar.tsx:131,140` 的 `showResume` 与暂停钮
     都由 activation 决定，"active 但已 disarmed"是一个真实状态（会话重启后目标仍在、
     但不再自动续跑）。
   - 为何被否：activation 是**进程内**状态（`goal/src/types.ts:66`），要 `goals.get` 的
     Remote 读或 `goal/activation-changed` 事件（`goal/src/index.ts:504-513`），手机两条都没有。
     编一个本地"已激活"标记就是第二份真值，而它错了的症状是**按钮点下去必然失败**。
     代价如实记在 `docs/subsystems/goal-bar.md` §2 与 §8。
4. 动作成功后自己再重读一次投影（照 `switchPermission` 的写法）
   - 最强的理由：不依赖 `goal/change` 真的到达；即使事件丢了，界面也会跟上。
   - 为何被否：目标的身份 / 阶段 / 正文只由 `goal/change` 改（`goal/src/index.ts:142-155`
     的 fold；另一种 `source.kind === 'goal'` 的用户消息只推进 `roundsStarted`，
     而条子不画轮次），再叠一次重读就是两个触发点，且会和事件那次撞成两次往返 ——
     合并闸正是为"同批两条信号"写的。少一处判据，就少一处会漂的地方。
5. 编辑弹 sheet（与排队条的编辑一致）
   - 最强的理由：触屏上"行内展开输入框"历来可疑，而排队条已经用 sheet 做同一件事，
     两个 dock 的编辑形态一致。
   - 为何被否：DSH 的编辑就在同一格里（`GoalBar.tsx:88-127`），而这一格的正文只有一行、
     动作只有两个 —— 弹 sheet 会遮住"我正在改哪一条"。真机上 36dp 的行内输入框可用
     （`goal_bar_test.dart` 钉住编辑态的字段与保存路径）。
6. 把 `goal/change` 也落成条目（像其它未知事件那样变 `OtherItem`）
   - 最强的理由：`projectEvent` 的默认分支就是"未知类型不丢"，保持一条通路。
   - 为何被否：它是状态事件、没有可渲染的正文（与 `agent/inbox/spliced` 同一条），
     落进本地库只会多一行永远不显示的记录。识别它之后按"已知但不渲染"处理。

## Consequences

- 收益：目标条在手机上可见、可操作；**桌面改了目标手机跟上**（同一条 `goal/change`）；
  键名、解析、可见性、刷新各只有一处；`goal` 投影同时进了连接器金样
  （`FULL_PROJECTION_VALUES` 从 14 个键变 15 个），App 的解析因此有**外部真值**盯着。
- 代价：每次点动作都会在对话流里落一张 `/goal` 命令卡（`command/run` + `command/done`
  是宿主的生命周期事件）—— 这是"不开新方法"的直接后果，要消掉它得走上面第 1 条。
- 代价：目标编辑器是**单行**，保存前把换行折成空格。连接器在拼命令行之前就拒收
  带换行的 `line`（`connector/src/handlers.ts:1242-1246`），而 DSH 的 `/goal` 能收
  多行目标 —— 多行目标到手机上会被压成一行。这是这条传输的限制，不是界面的选择。
- 代价：**没有 activation**，所以"active 但已 disarmed"在手机上显示成「进行中的目标」+ 暂停钮；
  要修得先给连接器加 `goal.*`。
- 代价：目标条占了底部预算的 42dp（条 36 + 下边距 6）。出现时 `_BottomBudget` 的
  `reserved` 会加上它，接管卡与候选面板的可分空间因此变小 —— 这是"这一列只能有一份预算"
  那条规则的必然结果，不是额外设计。
