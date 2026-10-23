# Agent Note: 重连时按 `session.list` 重建「在跑吗」

Status: implemented

## Problem

**现象**：断线期间收口的一轮，重连后运行条一直转、输入栏停在「排队发送」，
杀 App 才消失（`memory.md` 已知缺口 9b）。

**机制**：`runningOf` 只有一个真值 `_runningSids`：`turn/start` 加、`turn/end` 撤
（`app/lib/data/app_model.dart:2677`、`:2781-2787`）。`_applySessionList` 平时
**只补不撤**（`:1855-1872`）—— 这是 2026-10-22 为「整轮运行条不出现」定的方向。
断线期间没有事件；重连时 `_onConnectionChanged` 只调 `refreshSessions()`
（`:1749`），而它只会把 `running: true` 补进集合 ⇒ 集合里那条 sid 永远留着。

**重连的第一包到底是什么**（读 `protocol/` 与 `connector/src/protocol/recovery.ts`，
不是猜）：

- `recovery.ts:298-311`：`since > latest` 或 `since < trimmedUpto` ⇒ **快照**
  （`revision-newer` / `window-missed`，`:300-306`）；否则 ⇒ **增量**
  （`frames` 里 `seq > since` 的帧，`:308-311`）。增量含漏掉的 `turn/end`。
- 快照的条目来自 `orderedItems(log, items)`（`:269-280`、`:314-318`），形状是
  `{seq,itemId,text}` —— **没有事件类型**，所以快照页本身说不出「这一轮收口了」。
- `protocol/verify-fixtures.mjs:139-163`：客户端先试中转窗口（`relay.since` ⇒ 增量），
  否则走 `bridge.hello`（增量或快照）。fixture `01-normal-delta.json` 是增量
  （from 1 / to 3），`04-window-missed-baseline.json` 是快照（`window-missed`）。
- 真连接器同一形状：`connector/src/session-subscriptions.ts:251-307` 先
  `buffer.tailFrom(sid, since)`（增量补发，`:259-268`），覆盖不到再走宿主的 opening
  帧（`:186-196` 把 `records` 逐条展开成 `ev`）；`connector/src/session-buffer.ts:183-204`
  的 `tailFrom` 覆盖不到就回 `undefined`，而 `:169-181` 的 `ack` 按设备落盘水位裁缓冲。
- 手机**恒声明 `since: 0`**：`app/lib/data/app_model.dart:2532` 的
  `openSession({int since = 0})`，所有调用点都用默认值；`app/lib/core/sync_client_impl.dart:888-890`
  记下它、`:136-142` 在 `sync.hello` 里整份重发。于是只要手机发过 `persisted`、
  缓冲被裁过，`tailFrom(sid, 0)` 就覆盖不到 —— **常态第一包是宿主的 opening 快照**，
  增量只在缓冲仍覆盖 0 时出现。

结论：**两种都可能**，而且不能把「收口」寄托在「那一条 `turn/end` 恰好以事件形式
落在第一包里」。更糟的是即使事件回来了，`session.list` 是另一条请求/应答：
从请求发出到这一包落地之间到达的 `turn/end` 比它新 —— 旧实现会把 `running: true`
再加回去，正好复现 2026-10-22 那条「旧快照把 true 钉死」的教训。

## Decision

**重连进服务态时，第一包 `session.list` 重建 `_runningSids`（唯一允许「撤」的地方）；
平时仍然只补不撤。**

准入门槛（可机械判定）：

1. 只在 `_onConnectionChanged` 的 `serving` 分支传 `reconcileRunning: true`
   （`app_model.dart:1749`）；其余 `refreshSessions()` 调用点不传，行为不变。
2. 请求发出**之前**拍一份 `_turnGeneration`（`turn/start` / `turn/end` 各 +1，
   `:2693-2707`、`:2781-2787`）。应答落地时，**代号变过的行直接跳过** ——
   事件比这一包新。
3. 代号没变：`running: true` 补进集合；`running: false` 撤掉并清 `_turnStartedAt`
   （`:1874-1888`）。
4. 请求失败：不动集合（不知道就不撤，`refreshSessions` 的 catch 只留声）。

代码入口回指：`runningOf` 的文档注释末尾有一行
`Note: … 2026-10-23-running-rebuilt-on-reconnect.md`。

## Alternatives considered

1. **让 `_applySessionList` 一律按 `running` 撤**（把「只补不撤」整个推翻）
   - 最强理由：一处规则、没有例外；列表本来就是 `running` 的权威。
   - 为何被否：列表在轮次进行中是旧值（2026-10-22 真机：一轮跑 40 秒、运行条整轮
     没出现），一律撤会把正在跑的轮次关掉。方向不变是用户明确要求。
2. **`runningOf = _runningSids || 快照.running`**（回到 2026-10-22 之前）
   - 最强理由：快照参与判断，中途订阅（事件流没覆盖到这一轮）时不会漏运行条。
   - 为何被否：旧快照的 `true` 永远关不掉（2026-10-22 真机转了 5 分钟），
     这是已经付过代价的教训。
3. **重连时先清空 `_runningSids`，再让 `refreshSessions` 补**
   - 最强理由：一行改动，语义直白。
   - 为何被否：清空到应答落地之间运行条会消失；请求失败时把还在跑的一轮也关掉
     （把「不知道」当成「没有」）。
4. **只靠重放事件收口**（不动 `session.list`）
   - 最强理由：事件是电脑侧事实，最实时；协议层的增量确实含 `turn/end`。
   - 为何被否：协议层的快照没有事件类型；真连接器的 opening 帧虽带事件，
     「窗口里恰好有那一条」不是契约；而且 `session.list` 与事件流是两个方向，
     旧的一包会把 `true` 加回来（第 3 条判据的用例）。

## Consequences

**收益**

- 断线期间收口的一轮，重连后 `runningOf == false`：运行条消失、输入栏从
  「排队发送」回到可发送。
- 仍在跑的一轮保持 `true`（新快照或重放的 `turn/start` 都能补）；
  重连那包读失败保持原值。
- 事件流仍然赢过快照：代号护栏让「请求之后到达的 `turn/end` / `turn/start`」
  不被旧快照覆盖。

**代价**

- 多一个 `_turnGeneration` map + 计数器（只增不减、跨会话共用；每会话每轮两笔，
  内存可忽略）。
- `refreshSessions` 多一个可选参数；重连时多一次「代号快照」，没有额外网络往返。
- 重连那包如果**失败**，运行条仍可能停在一个过期的 `true` 上（下一次列表 / 事件
  才有机会）—— 这是有意的：不知道就不撤。
- 轮组的**收口行**仍要等 `turn/end` 事件落表才出现（`docs/subsystems/turn-groups.md`
  §7），所以「运行条停了」不等于「收口行出现了」；两者不再是同一条边界。
- 门禁：flutter **1121 → 1127**（新增 6 条），其余不变；0 个真机回合。

**判据**

- `app/test/running_reconnect_test.dart` 6 条（5 模型 + 1 widget）：
  快照说 `false` ⇒ 撤；快照说 `true` ⇒ 留；`turn/end` 先于快照落地 ⇒ 旧 `true`
  不许加回来；`turn/start` 先于快照落地 ⇒ 旧 `false` 不许关掉；列表读失败 ⇒ 保持；
  `ChatPage` 重连后运行条消失、主键从「停止」回到「发送」。
- 变异校验（都做过）：
  1. 把 `refreshSessions(reconcileRunning: true)` 改回 `refreshSessions()` ⇒
     **恰好 3 条红**（快照收口 / `turn/end` 先到 / widget），其余 3 条绿；
  2. 拆掉代号护栏（`if (_turnGeneration[…] != …) continue;`）⇒ **恰好 2 条红**
     （`turn/end` 先到、`turn/start` 先到），其余绿。
