# Agent Note: legacy 提问的身份从会话日志里推（唯一未结算的 `ask_user_question` `tool/call`）

Status: implemented

## Problem

**现象**：手机上出现一张提问卡，点选项、提交 —— 变成「工具失败」。
DSH 侧看到的是一次 `ask_user_question` 抛错，手机侧看到的是 `interaction/not-pending`。

根因不是"手机没发对"，而是**应答者那一刻没把两端本来相同的身份交给自己那份 claim**：

- 手机那张卡来自会话事件 `tool/call`，`itemId` 是 `t:<callId>`（`app/lib/data/projection.dart:1020-1033`）；
- 答复 `interaction.respond` 发的 `callId` 就是那个真 id（`app/lib/data/app_model.dart:3148-3160`）；
- 而连接器的在途 claim 以 `callId` 为键（`connector/src/interaction-claims.ts`），
  legacy 形态的请求里**没有** `wait.callId` ⇒ 键写成 `undefined` ⇒ `:251-256` 的 fail-closed 抛出
  ⇒ DSH 把一次提问变成工具失败。

### 三个事实问题（都读源码核实，行号对 0.2.1-rc.2 的 `D:\sudy\github\deepseek-harness`）

1. **这一次 ask 有没有身份？legacy 没有，timed 有。本机部署是 legacy。**
   - legacy 工具调 `ask()` 时**不传 `wait`**：`packages/interaction/tool-ask-user/src/index.ts:98-109`；
   - timed 形态才带：无限等待是 `timed.ts:200-203` 的 `wait: { callId: exec.callId }`，
     计时等待是 `user-questions/src/index.ts:251` 的 `wait: { callId, timed: true }`；
   - 本机：`packages/bundle/web-app/presets/cordis.patch.yml:109-110` 的 `tool-ask-user` **没写 config**，
     `Config.mode` 默认 `'legacy'`（`tool-ask-user/src/index.ts:24`），只有 `timed` 才注册 timed 工具（`:34-35`）；
     `~/.dsh/profiles/*/cordis.patch.yml` 里没有 `tool-ask-user` 的覆盖（本机逐个看过）。
2. **legacy 的唯一结算路径是应答链的 promise；`answer()` / `attachWait` / `askTimed` 在 legacy 下都用不了。**
   - `answer()` 只读投影里 `state === 'continued'` 的行
     （`user-questions/src/index.ts:146-149` 的 `continued()`、`:167-168` 的查找）；
   - 而投影的 fold **只跟踪 timed schema**：`projection.ts:12-20` 原文 "Calls made under the blocking
     legacy schema never enter it"，判别依据是请求头里有没有 `timeout` 参数（`:30-36`）；
   - `attachWait` 只认 `askTimed` 建的那张 wait 表（`:215-220`），legacy 从不建；
   - `askTimed` 是另一个入口（`:234-269`），legacy 工具从不调它。
3. **应答者被调用时，那条 `tool/call` 已经在 `agent.session.snapshotEvents()` 里，且它的 `tool/result` 还不在。**
   - 循环在 execute **之前**追加调用：`packages/core/agent-loop/src/tool-calls.ts:168` 调
     `appendToolCall`（`:263-266`），随后才 `prepare` / 执行（`:170+`）；
   - 执行完才追加结果：`:156` 调 `appendToolResult`（`:269`）；
   - 形状：`tool/call` 是 `{turn, step, callId, name, arguments}`
     （`packages/core/session/src/types.ts:362`），`tool/result` 的配对键是
     `data.message.toolCallId`（`:376-386`、`packages/llm/llm/src/message.ts:177`）。
   - **唯一性不是天然的**：同一 step 里并行发两次提问会让"未结算"多于一条。崩溃留下的悬空
     调用**不算** —— DSH 在加载时会补一条合成结果（`packages/core/session/src/repair.ts:18-29`）。
   - 证据：`connector/tests/question-call.test.ts` 用**真 `Session`**（`Session.create` + `append`）造日志，
     不是手搓事件数组 —— 手搓只会复述我们对形状的假设。

## Decision

**claim 之前从会话日志认身份：`tool/call` 里 `name === 'ask_user_question'`、且没有对应
`tool/result` 的 callId，恰好一个才用它做 claim 的键；0 个或 ≥2 个就 `return next()`（交还桌面）。**

准入门槛（可机械判定）：

1. **身份只有一个来源**：`wait.callId` 在场时用它（timed），不在场时才扫日志。
2. **唯一性**：`tool/call` 按 callId 去重后，未结算的必须恰好一条。重复记录（重放/恢复）不因此变成不唯一。
3. **结算判据是 `tool/result.data.message.toolCallId`**，不是"名字里带 result"之类的位置推断。
4. **失败方向**：认不出就 `next()` —— **不抛**（抛等于让这次提问变成工具失败）、**不猜**（猜错会把答案
   写进另一次调用）、**不返回空答案**（`{answers: []}` 会被读成"用户跳过了每一题"）。

落点：纯函数 `connector/src/dsh/question-call.ts`（文件头写了判据、并发语义、失败方向与"为什么读的是
已废弃的同步读"）；应答者在 `connector/src/dsh/interactions.ts` 的 `user-questions/request` 里调它。
`interaction-claims.ts:251-256` 的"没有 callId 不 claim"**保留** —— 它是兜底，不是主路径。

**为什么读一个已废弃的 API**：`Session.snapshotEvents()` 在 DSH 侧标了 deprecated
（`.agents/notes/implemented/architecture/2026-09-09-deprecate-synchronous-session-event-reads.md`：
"new calls are prohibited"），而"此刻正在执行的那次 tool call"没有别的非废弃缝。DSH 自己查 prompt 的
`rpcId` 也走这条读（`packages/api/session-controller/src/commands.ts:591-595`，带 line-scoped waiver）。
本仓没有 oxlint 门禁，所以没有那行 waiver —— 理由写在 `question-call.ts` 的同一段里；
提问是低频人机交互，扫描成本可忽略。

## Alternatives considered

1. **把部署改成 `mode: timed`**（让每个 ask 都带 `wait.callId`，投影也有行，`answer()` 原生可用）
   - 最强的理由：它是 DSH 为"UI 要拿住一次提问"设计的原生形态 —— 有 id、有投影、有 `answer()`，
     连接器几乎不用写判据，只需补一条 `wait?.callId === undefined → next()` 的护栏。
   - 为何被否：它改的是 **shipped preset**（`packages/bundle/web-app/presets/cordis.patch.yml`），不是本仓代码；
     而且 timed 工具多一个 `timeout` 参数、桌面端的提问卡会带倒计时 —— 为"手机上能答"换掉用户看得见的
     提问形态，是把部署行为当成修复手段。本仓要的是**认出身份**，不是**改提问形态**。
2. **在连接器里维护一张"进行中的 ask 调用"表**（监听 `session/event`，见到 `tool/call` 记下、见到
   `tool/result` 删掉）
   - 最强的理由：不读废弃 API，每次查询 O(1)，也天然跨连接共享。
   - 为何被否：那是**第二个真值源**。插件晚挂载 / 会话在挂载前就已在跑 / 事件流断过，表就比日志旧，
     而"表里没有"与"日志里没有"会给出不同的结论 —— 症状是偶发的 `next()`（手机上点了没反应）。
     日志是持久真值，扫它是自愈的；低频路径不值得为 O(n) 引入漂移面。
3. **取"最近一条未结算的 ask 调用"**（不要求唯一）
   - 最强的理由：并行提问是极少数，取最近一条能让绝大多数场景都成功，比 `next()` 更"有用"。
   - 为何被否：并行时它会**确定地选错** —— 答案写进另一次调用，模型拿到的是另一个问题的回答。
     这比失败更坏：失败至少是可见的。
4. **让 `askQuestion` 在没有身份时返回空答案**
   - 最强的理由：工具不会失败，回合能继续。
   - 为何被否：`{answers: []}` 在 DSH 的语义里是"用户显式跳过了每一题"（`tool-ask-user/src/timed.ts:172,179`），
     等于替用户做了一个他没做过的决定。这条在本仓的 `interaction-claims.ts` 文件头已经写死。
5. **什么都不做，只在文档里记成"legacy 不支持"**
   - 最强的理由：零风险，不碰已废弃 API。
   - 为何被否：本机部署就是 legacy，等于"手机上的提问永远答不了"；而修法不需要新方法、不需要改协议、
     手机侧零改动 —— 代价只是连接器里一个纯函数。

## Consequences

- 收益：未计时提问在手机上真的能答；`interaction.respond` 的形状、手机侧代码、方法面**全都不变**；
  身份解析是一处纯函数（可单测、无状态），应答者只多了一个 `if`。
- 收益：`next()` 的失败方向让"认不出"退化成"桌面接管"，而不是"工具失败"—— 比修复前严格更好。
- 代价：多了一处对**已废弃**的 `snapshotEvents()` 的生产调用（带 waiver，理由如上）；每次 legacy 提问
  扫一遍日志（低频，可忽略）。
- 收口：`QuestionPrompt` / `ApprovalPrompt` 上三个**只写不读**的字段删掉了（`dshSessionId` ×2、`timed`）——
  端口只读 `sid` / `callId`；`planReview` 保留，并第一次真的被读（"程序化提问不 warn"的判据）。
- 代价：**PTC 子调用里的提问认不出**（它没有 `tool/call` 事件，只有 `tool/ptc-dispatch*`），一律 `next()`；
  手机上本来也没有对应的卡。
- 代价：**程序化提问**（`/exit_plan_mode` 的 `ask()`，不产生 `tool/call`）也落 `next()` —— 它在手机上
  本来就没有卡（卡只从 `ask_user_question` 的 `tool/call` 生成），所以不是回归。这一支**不 warn**：
  `planReview` 标记把它与"真的认不出"区分开；其余 `none` / `ambiguous` 各留一条 warn。
- 代价：并行两次提问时，后跑到的那个应答者会看到两条未结算（`ambiguous`）并交还桌面；先跑到的
  可能只看到自己那一条（认领，正确）。取决于循环调度，但不会认错 id。
- 判据：`connector/tests/question-call.test.ts` 8 条（真 `Session` 造事件：唯一 / 已结算排除 / 两条
  ambiguous / 一老一新 / 别的工具 / 空日志 / 重复记录 / 工具名），`connector/tests/interactions.test.ts`
  新增 5 条（legacy 唯一 → claim 到真 id；两条并发 → `next()`；没有 / 只有已结算 → `next()`；
  timed 的 `wait.callId` 优先于日志；程序化提问 → `next()` 且不 warn）。
- 变异校验（都做过）：① 把"推出 id"改回 `undefined`（`found` → `none`）⇒ **恰好 4 条红**：
  3 条 `found` 的解析用例 + 1 条 legacy claim 接线；② 把身份缺失的 `next()` 改回 `throw` ⇒
  **恰好 2 条红**：两条 `next()` 接线用例；③ 把"程序化提问不 warn"的判据改成恒真 ⇒
  **恰好 1 条红**：那条"不 warn"用例。
- 门禁：connector **599 → 612**（+13），其余不变；**0 个真机回合**。

代码入口回指：`connector/src/dsh/question-call.ts` 的文件头与
`connector/src/dsh/interactions.ts` 的身份解析处各有一行指向本篇。
