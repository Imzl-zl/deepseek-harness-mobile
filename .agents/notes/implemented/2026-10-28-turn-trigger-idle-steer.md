# Agent Note: 唤醒一轮的判据要连 `idleSteer` 一起搬，不能只认 `next-turn`

Status: implemented

## Problem

`32dfc72` 把「唤醒新一轮的注入消息」按 DSH 的 `turn-trigger` 显示，判据写成了
「这条非人 `user/message` 的 id 在 `inbox-next-turn` 的 claim 里」。
2026-10-28 真机验收（会话 `session-bc31f325`，设备 d61cf622）当场对不上：

- 桌面 DSH 在 seq=118 那一行画的是 **「收到任务消息」**（`agent-message`，带箭头图标、可展开）；
- 手机画的是 **「上下文注入 · agent-message」**；
- 整场验收里 **「子任务状态更新」一次都没出现**。

真机日志（`D:\tmp\dsh-mobile-home\sessions\...\session.v4.jsonl.zstd` 解出来的事件流）
说明宿主根本不走 `next-turn`：

```text
seq=114 agent/inbox/spliced target=next-step inserted=[655f81d9]   # 子智能体发来消息
seq=115 turn/start turn=4
seq=116 agent/inbox/spliced target=next-step removed=1            # 被 claim 走
seq=117 step/start turn=4 step=1
seq=118 user/message id=655f81d9 kind=agent-message                # 唤醒这一轮的那条
```

`next-turn` 只用于**人**发的消息（seq=3/21/98）。子智能体的 `agent-message` 与
`subagent-settled` 走的是 `next-step`：宿主先把消息排进运行中的轮次，空闲时
**由 claim 本身开一轮**。于是「只认 next-turn」在真机上恒为假。

DSH 的真实判据（`@deepseek-ai/dsh-client-ui-chat/lib/client.js:9857-9866`，asar 内
`//#region lib/types/client/conversation-nodes/message.js` 段）：

```js
const idleSteer = location.kind === "step" && location.step.step === 1 &&
  turnStart !== void 0 && (nextStep?.claimSeq ?? -1) > turnStart &&
  (nextTurn?.claimSeq ?? -1) < turnStart && nextStep?.claimedHuman === false &&
  nextStep.currentClaimed.has(String(event.data.id));
waking: nextTurn?.currentClaimed.has(String(event.data.id)) === true || idleSteer
```

## Decision

把 DSH 的两个 inbox 节点**整体**搬进 `_InboxTracker`：每个 inbox 存
「队列 + `currentClaimed` + `claimSeq` + `claimedHuman`」，`waking` 按上面那条
`|| idleSteer` 原样算；插话（`source.kind === 'user'`）改成**查询**而不是消费
（DSH 是状态查询，一次 claim 可以同时 claim 走多条）。

准入门槛（可机械判定）：

1. 消息落在**本轮第 1 步**、`next-step` 的 claim 晚于本轮 `turn/start`、
   `next-turn` 的 claim 早于它、那批 claim 里**没有人**发的消息 ⇒ 标题按 `kind` 换词
   （`agent-message` = 「收到任务消息」、`subagent-settled` = 「子任务状态更新」），
   且**没有**生产者尾巴（`systemHint == null`）。落在第 2 步的同样事件仍是
   「上下文注入 · kind」—— 与桌面同形。
2. 判据只有 DSH 那一条：不用「非人消息 + 运行中」这类近似，也不看正文文本。
3. `currentClaimed` 在每次 claim 时**整体替换**；插入的 id 从上一批摘掉。
   不这样做，久远的 claim 会一直命中，把普通注入误判成唤醒。

## Alternatives considered

1. 「非人消息一律当唤醒」
   - 最强的理由：一行代码，真机上「子任务状态更新」立刻出现，验收当场变绿。
   - 为何被否：桌面并不这样。真机 seq=125 的 `subagent-settled` 落在**第 2 步**
     （运行中的一轮里被注入），桌面把它画成上下文注入；一律当唤醒会让手机多出
     一行桌面没有的通知，等于用新偏差换旧偏差。
2. 等宿主改成用 `next-turn` 推子智能体消息
   - 最强的理由：判据会变得和手机现有实现一样简单，不必维护 turn/step 状态。
   - 为何被否：那是替宿主做决定。`next-step` 的语义就是"排进运行中的轮次"，
     宿主用它区分"插进这一轮"与"开下一轮"，手机只能读不能改。
3. 按正文猜（含 "Background subagent ... finished" 就当唤醒）
   - 最强的理由：不依赖 inbox 事件，恢复/翻页场景也能认。
   - 为何被否：文案是宿主的实现细节，改一个字就失效；而且它把"读法"从事件搬到
     字符串匹配，与 `projection.dart` 现有的判据体系冲突。

## Consequences

- 收益：手机与桌面在同一份事件流上给出同一行标题；`32dfc72` 想做的事这次真的生效
  （用例 4 条：两条正例按 `kind` 换词、两条反例覆盖"第 2 步"与"那批 claim 里有人"）。
- 收益：插话判据从"消费候选"改成"查询 claim 集合"，一次 claim 走多条时不再漏判。
- 代价：`AppModel` 的收帧循环要多记两件事（本轮 `turn/start` 的 seq、当前第几步），
  `_InboxTracker` 从两个 id 列表变成两个 inbox 快照。
- 代价（记录在案的边界）：`currentClaimed` / `claimSeq` 只存在于**在线事件流**里。
  打开会话时投影只给队列，所以"打开之前就已经 claim 掉"的那条只能按上下文注入显示
  —— 桌面靠回放整份会话日志能认出，手机不能。真机验收这一轮里手机全程在线，
  没有踩到这条。
