# Agent Note: 审批与提问同进程直连 waterfall，词汇表映射收敛在适配层

Status: implemented

## Problem

桥接要代替桌面回答审批与提问。DSH 侧的机制是 **claim-or-delegate 的顺序 waterfall**：
handler 直接返回结果即 claim，调 `next()` 即交还（`packages/interaction/user-approval/src/types.ts:87-92`、
`packages/interaction/user-questions/src/types.ts:157-161`）。落地时有四个必须先答的问题：

1. **走哪条接入路径。** 参考实现（Agents-Anywhere）**没有**用 `ctx.on`，它把自己当作额外的
   Remote Events 客户端，订阅 `$events` 流再回 `$events/result`。两条路都能到。
2. **DSH 在这条缝上有三个静默失败模式。** 返回词汇表以外的 outcome → 静默归一成 `'unavailable'`
   （`user-approval/src/index.ts:288`）；answerer 抛异常 → 同样静默 `'unavailable'`（`:291`）；
   漏写 `return next()` → handler resolve 成 `undefined` → 还是 `'unavailable'`。
   **三者的表现都是"操作被拒"，没有异常、没有日志。**
3. **审批与提问的语义不对称。** 同样是 signal 被 abort，审批拿到字符串 `'cancelled'`（`:269`、`:293-306`），
   提问拿到异常 `ASK_ABORTED`（`user-questions/src/index.ts:288-290`）；链尾默认值也不对称 ——
   审批是 `'unavailable'`（`user-approval/src/index.ts:283`），提问是 **reject** `NO_PROVIDER`（`user-questions/src/index.ts:318-321`）。
4. **授权值只有一个。** outcome 闭集是 `'allowed-once' | 'rejected' | 'cancelled' | 'unavailable'`
   （`types.ts:32`），而 `'allowed-once'` 是唯一授权值（`user-approval/src/index.ts:211`）。
   "始终允许 / 本会话允许"在 DSH 里**不存在**。

## Decision

**同进程直连。** 插件用 `ctx.on('approval/request', ...)` 与 `ctx.on('user-questions/request', ...)`
注册 answerer，不走 `$events` 流。

**判定与映射收敛在本层。** claim 判定复用 `src/protocol/takeover.ts` 的纯函数；DSH 的 outcome
词汇表由本层产生 —— 连接层只能表达 `'allow-once' | 'reject'`（`RemoteApprovalDecision`），
授权值只可能从映射那一行出来。推给手机的那一步通过注入的 `RemoteInteractionPort`。

**失败一律 fail-closed，且必须留痕。** 审批失败 → 记日志 + 返回 `'unavailable'`；
提问失败 → 记日志 + **抛错**。

准入门槛（可机械判定）：

1. **两个 handler 都必须 `return next()`**，不能只调用它 —— 漏 `return` 等于把请求静默变成拒绝。
2. **只返回词汇表内的 outcome**；连接层不得自造。`allowed-once` 只从
   `decision === 'allow-once'` 这一个分支产生。
3. **三种情况必须 `return next()`**：会话未登记给手机（`sidOf` 返回 undefined）、
   `callId` 缺失、接管判定不 claim。绝不 claim 之后又答不出来。
4. **绝不替换 `request.signal`**：取消语义整个挂在 asker 的活 signal 上。
5. **提问失败必须抛错**，不得用 `{ answers: [] }` 伪装成「用户跳过了每一题」。
6. **失败必须记日志**：DSH 会把 answerer 的异常静默吞掉，不记就永久查不到。
7. **计划审查按提问处理**，靠 `intent.kind === 'plan-review'` 判别
   （`packages/plan/plan-mode/src/index.ts:320`），不占审批通道。

## Alternatives considered

1. 学参考实现走 `$events` Remote 流
   - 最强的理由：与浏览器客户端用同一条机制，将来要在浏览器里复用同一套转发逻辑时路径一致；
     它天然把「转发给人」和「进程内决策」分开，边界更清；而且 DSH 已经把两个事件放进
     `$events` 的 allowlist 并注册好了转发（`packages/api/remotes/src/index.ts:51-76`），
     接上去就有事件流。
   - 为何被否：那套是为**跨进程 / 浏览器**客户端设计的。本插件与 DSH **同进程**，走 `$events`
     要多两跳（WS 流 + 进程内 HTTP POST）、多依赖 `connection` 与 `typertGateway` 两个服务，
     还要为 arity 漂移写兼容 shim —— 参考实现就有这段（`interaction-stream.ts:15-27`），
     因为它在 `0.2.0-rc.1` 与 `rc.2` 之间真的漂了。这些代价买到的「跨进程能力」我们一条都用不上。
2. 在根 ctx 注册一个全接管 answerer，不做 claim 判定
   - 最强的理由：实现最短，不必维护设备状态与档位；行为可预测 —— 审批永远在手机上出现。
   - 为何被否：会**夺走桌面**。默认档 `foreground` 存在的全部理由就是「用户离开手机时审批照常在
     电脑上弹」（契约 §6.2）；全接管意味着插件一装上桌面就再也答不了审批，而 `never` 档
     （只通知不接管）也会失效。这是产品行为，不是实现细节。
3. 让连接层自己决定返回哪个 outcome
   - 最强的理由：连接层最清楚发生了什么，能表达「网络断了」与「用户点了拒绝」的区别；
     少一层映射，少一处要同步的词汇表。
   - 为何被否：DSH 的 outcome 词汇表封闭，且**返回词汇表以外的值会被静默归一成 `'unavailable'`**
     （无异常、无日志）。把映射放在连接层，等于把「能不能授权」的判断分散进网络代码，
     而那里恰恰是最容易因为一次重构多出个字符串的地方。收敛在本层后，
     `allowed-once` 只可能从一行代码产生，review 时一眼可见。
4. 提问拿不到答案时返回空答案 `{ answers: [] }`
   - 最强的理由：类型上合法，调用方不会拿到异常；实现最短，不必定义错误类型。
   - 为何被否：DSH 会把它当成**用户跳过了每一题** —— batch 校验（`user-questions/src/index.ts:178-185`）
     与定时工具（`tool-ask-user/src/timed.ts:172,179`）都这么读。那是在**伪造用户的决定**，
     比失败更糟：模型会基于一个从未发生的选择继续跑。链尾本来的行为就是 reject
     （`:318-321`），抛错才是与 DSH 一致的收束。

## Consequences

- 收益：claim 判定与 outcome 词汇表各收敛在一处（`takeover.ts` 与映射那一行），
  `allowed-once` 只可能从一个分支产生；三个静默失败模式各自有了明确处置 ——
  前两个被我们接住并记日志，第三个由「必须 `return next()`」这条门槛挡住；
  不引入 `connection` / `typertGateway` 依赖，也不背 arity shim；失败一律 fail-closed，
  不会有「静默放行」这条路径。
- 代价：与参考实现走了不同路径，它那段代码不能直接借鉴，将来若两侧要共用逻辑需要重写；
  `ctx.on` 的可见范围取决于注册上下文（根 ctx 注册即收到**所有** agent 的请求，
  `packages/core/scope/src/index.ts:176`），按会话路由只能靠 `sidOf` 在 handler 里过滤，
  多一层映射且漏过滤会串会话；**`never` 策略下我们的 answerer 根本不会被调用**
  （`user-approval/src/index.ts:270-275`，`prepend: true` 也无效），所以"手机上没弹审批"
  有两个完全不同的原因（档位是 `never` / 该会话没登记给手机），产品文案必须能区分，
  否则用户会把前者误报成故障。
