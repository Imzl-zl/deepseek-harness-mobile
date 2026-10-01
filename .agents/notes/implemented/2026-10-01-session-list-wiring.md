# Agent Note: `session.list` 取自 `sessionController.list`，标题与别名各有归属

Status: implemented

## Problem

方法面接上之后（上一轮），手机首页要的第一个方法是 `session.list`。接它之前有三处不确定，
而三处都不能靠猜：

1. **清单从哪来？** 契约 §5.7 只写"会话清单（含别名、标题、状态、最近活动）"。
   现成的候选有三个：`sessionQuery.listSessions`（语料库，合并落盘与活会话）、
   `sessionController.list`（可见会话，按活动排序）、或直接列落盘目录。
2. **标题从哪来？** 上面那些面**都没有标题**：`SessionSummary` 是
   `{ agentAvailable, sessionId, updatedAt, running, blank, origin?, cwd?, projections? }`，
   `SessionRecord` 是 `{ header, live, persisted }`。标题在 `session-title` 那一边。
3. **别名在哪分配？** `sid` 是**通道自己的概念**（中继与手机都只见它），而适配器只该做 DSH 的映射。

顺带发现两件更该修的事：`src/dsh/` 下的四个适配器（`sessions` / `jobs` / `subagents` / `settings`）
**一个测试都没有**（`layering.test.ts` 只保证它们对着源码写过）；而且没有任何一个被装配过 ——
这一轮是第一次真正用上 `sessions.ts`。

## Decision

- **清单取自 `sessionController.list`**：它是权威（"visible Session rows … ordered by activity"，
  `packages/api/session-controller/src/index.ts:251-254`），**已经按活动排好序**，
  而且是本插件**已有的必需服务** —— 不必新增依赖。`sessionQuery` 留给搜索/事件读取（下一轮按需接）。
- **清单先不含标题**，并把这个事实写进契约那一行：`session-title` 读的是**活的 `Session` 对象**，
  对"只在落盘里的会话"拿不到；投影里只有 `sessionListMetadata = { blank, lastPromptAt }`。
  手机侧先用 `cwd` 末段 + 相对时间兜底（DSH 自己的 `workspaceLabel` 就是这么做的）。
- **别名在方法面合成，不在适配器里**：适配器返回 `dshSessionId`（明确标注"不要发给手机"），
  方法面把它换成 `sid`，并且**逐字段构造给手机的行**（不 spread）。
- **给 `alias.ensure` 加同键合流**：并发 `ensure` 同一个会话会各分配一个别名，
  留下一个孤儿 `bySid` 条目 —— 而"一个会话两个 sid"正是别名机制要防的事。

准入门槛（可机械判定）：

1. `session.list` 的载荷里**不出现** DSH 会话 id（e2e 断言 `JSON.stringify(...).includes(dshId) === false`）；
   给手机的行也不含 `dshSessionId` 这个键。
2. 适配器的映射是逐字段的：往 `SessionSummary` 里多塞字段（`agentAvailable` / `projections`）
   不会出现在结果里。
3. `subagent` 由 `origin === 'subagent'` 推出（不替手机决定是否折叠）；`cwd` 缺了就不出现这个键。
4. 同一会话并发 `ensure` 只分配一个别名、`bySid` 里不留第二个指向它的条目。

## Alternatives considered

1. 用 `sessionQuery.listSessions`
   - 最强的理由：它是"语料库"面，`SessionRecord` 带 `persisted`，还能顺手拿到落盘状态；
     将来做搜索时反正要接它。
   - 为何被否：它多一层（要先接一个可选服务），而 `sessionController.list` 已经在手边、
     而且**按活动排序**这件事正是清单要的。等真需要搜索时再接它，那时多出来的能力才有人用。
2. 直接列落盘目录 / 自己维护会话清单
   - 最强的理由：不依赖任何服务，实现最短。
   - 为何被否：会绕过 DSH 的**可见性判定**（哪些会话对这个客户端可见），
     还会把子代理会话混进用户的清单。这正是"不重建投影语义"那条纪律要防的。
3. 顺手把标题也做出来（对活会话问 `session-title`，落盘会话留空）
   - 最强的理由：手机首页没有标题几乎不可用，能填一点是一点。
   - 为何被否：一个"有时有、有时没有"的字段，调用方无法判断该不该显示兜底 ——
     最终会变成"有的行有标题、有的行是路径"，比统一用兜底更难看。标题要单独一轮，
     把"哪些会话能拿到标题"这件事一次定清楚（要么都从持久投影取，要么都不取）。
4. 在适配器里分配别名
   - 最强的理由：`session.list` 少一步合成，调用方拿到就能用。
   - 为何被否：适配器的契约是"只做 DSH 的映射"（`docs/subsystems/connector-and-relay.md` §1.2 的分层），
     而 `sid` 是通道的概念。混进去之后，"适配器不重建语义"这条就守不住了 ——
     下一个适配器会顺手再塞一个通道概念进来。
5. 给 `session.list` 加 `agentAvailable` 等字段
   - 最强的理由：DSH 有，白拿；将来某个屏可能要用。
   - 为何被否：本轮没有屏用它。**加字段比删字段便宜**这条不成立 ——
     线上字段一旦发出去就要背兼容。等有屏要了再加，那时也知道它该怎么显示。

## Consequences

- 收益：手机首页要的第一个真方法通了（别名 + 活动时间 + 状态 + cwd），
  且"id 不过线"有 e2e 断言；会话适配器第一次有了测试（此前 `src/dsh/` 下
  `sessions`/`jobs`/`subagents`/`settings` 四份**零测试**）；别名的并发分配隐患被修掉。
- 代价：`session.list` 每次调用都会对没有别名的会话做一次分配（首次列表 N 次落盘），
  之后走内存表；契约 §5.7 那一行改成了"标题不在这里"。
- **两处如实记下的欠账**：① `jobs` / `subagents` / `settings` 三个适配器仍然没有测试，
  它们在被装配之前必须先补（否则第一次装配就是第一次运行）；② `session.page` / `subscribe`
  还没接 —— 它们要 `follow` 的开启帧 `cursor` 与订阅生命周期，比 `list` 复杂一档。

## 一条测试方法论（变异校验抓出来的）

变异校验里把 `alias.ensure` 的合流去掉，**测试全绿** —— 追下去发现不是测试没写，
而是**替身不忠实**：内存表的 `put` 被写成同步改内存，而真实域表是**先落盘、再改内存**
（单写链，`domain.ts:263-270`）。那个 await 边界正是并发撞车的窗口；
替身把它抹平了，并发用例就永远撞不上。修法是让替身保留这个 await 边界 ——
之后同一个变异立刻命中。教训：**凡是要测并发的替身，必须保留真实介质的时序特征**
（哪一步先、哪一步跨 await），否则用例只是"看起来在测并发"。
