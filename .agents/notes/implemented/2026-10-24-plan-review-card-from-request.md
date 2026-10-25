# Agent Note: 计划审查卡 —— 卡来自那次 `exit_plan_mode` 的 `tool/call`，词汇来自请求

Status: implemented

## Problem

`/plan` 的收尾是 `exit_plan_mode`：模型把整份计划交给 `userQuestions.ask()` 等用户批准
（`packages/plan/plan-mode/src/index.ts:313-333`）。桌面上这是一张"批准 / 继续规划"的卡；
**手机上一直什么都没有**，只有一条普通的 `exit_plan_mode` 工具记录，那一轮最后由工具程序
自己的 120 s 预算收口（2026-10-24 真机确认：会话日志停在 `tool/call`，没有 `tool/result`）。

2026-10-24 之前这里**故意不 claim**，理由写在 `interaction-client.ts:424-430`：
"那个 id 是 `exit_plan_mode` 的 tool call，而手机上没有它的卡 —— claim 一条用户看不到的交互，
会把 DSH 原生的 fail-closed 换成一个永远等不到人的挂起"。**那个理由有一半是错的**：

- 错的：手机**有**可用的锚点 —— `exit_plan_mode` 的 `tool/call` 事件不仅存在，参数里就是
  整份计划（`plan` 必填，`:283-284`），宿主自己的 `presentCall` 也把它当正文（`:364-369`）。
- 对的：`ask()` 请求里的**选项与标签**确实不会到手机（`intent` 只活在应答链的请求对象上）。

所以缺的不是"投递一整张卡"，而是两件事：**从那条 `tool/call` 造卡**，以及**把手机的
"同意"翻成请求里的标签**。

## Decision

**卡来自事件，词汇来自请求。**

1. 手机（`app/lib/data/projection.dart`）：`tool/call` 且 `name === 'exit_plan_mode'` ⇒ 造一张
   `InteractionKind.plan` 卡：身份 `t:<callId>`、`detail` = 参数里的整份计划、
   `title` = 计划第一个 markdown 标题（与宿主 `firstHeading` 同一条读法，取不到就用
   「计划审查」，不从正文截一段冒充标题）。**没有 `plan` 参数就不开卡**（宁可留给工具行）。
   渲染不用改：`TakeoverController` 的 plan 分支早就在（`takeover.dart` 的
   「等待确认计划」+ 要求修改 / 同意执行 + 正文可滚）。
2. 连接器（`dsh/interaction-client.ts`）：身份按 **`intent.callId` → `wait.callId` → 会话日志**
   依次取；**两者都没有才照旧委托**（不猜）。`intent.callId` 与手机那张卡的 `t:<callId>`
   是**同一个值**（`plan-mode/src/index.ts:329` 的 `exec.callId`），所以 claim 与卡天然对上。
3. 连接器（`interaction-claims.ts`）：claim 里记下请求侧词汇
   （`planReview: {questionId, approve}`），`settleClaim` 对这类 claim **重建**答案批次：
   `{answers: [{id: <plan-review>, selected: 同意 ? [<Approve>] : []}]}`。
   手机发的是一个**标记**（`kPlanApproveMark`），不是宿主的英文标签。
4. `plan-mode` 的判据照旧（`:346-350`）：`selected` 恰好一项且等于 `approve` 且没有
   `custom` 才算批准；空 `selected` 就是"继续规划"（它会把一句反馈作为工具错误抛回去）。

## Alternatives considered

1. **手机里写死 `'Approve'`（宿主的常量，`plan-mode/src/index.ts:76`）** —— 最强理由：
   零连接器改动，`settlePlan` 现在就能用。
   被否：那是把宿主的**英文标签**复制一份到手机，而标签的权威在请求里。DSH 改文案那天，
   手机会静默地"总是继续规划"。本仓反复踩过这一类（同一事实两处表达）。
2. **继续不接线（维持 2026-10-24 之前的决定）** —— 被否：真机已经证明手机上一句话都没有，
   而卡需要的两样东西（正文、身份）**都在会话事件里**，不接线没有理由了。
3. **把 `ask()` 请求整份投给手机（新增一条"pending 交互"帧/方法）** —— 最强理由：手机能拿到
   全部字段（题干 / 选项 / `intent`），不必猜任何东西。
   被否：那是给协议加一条**新的投递通道**，与"手机=Web 的接口透传、只加窄口"的不变量冲突；
   而现在这条路上没有缺任何字段（见 Decision）。
4. **让连接器替用户答"批准"** —— 荒谬但有诱惑力（省一个界面）。被否：那是替用户做决定。
5. **在连接器里改 `detail`/标题再下发** —— 被否：`tool/call` 事件是 DSH 的，连接器不重写会话事件；
   手机从参数里取正文即可。

## Consequences

- **收益**：计划审查在手机上从"看不见"变成"能看能答"；一次 `/plan` 不再白等 120 s。
- **代价（有意）**：手机那两个按钮是我方文案（同意执行 / 要求修改），不是宿主的
  `Approve` / `Keep planning` —— 因为宿主的选项从来不到手机。
- **代价**：`settleClaim` 里现在有两处词汇映射（审批的 `allowed-once`、计划的
  `intent.approve`）。它们都在同一个位置、都只读**请求**里的词 —— 再加第三种交互时
  必须继续走这条规则（"词从请求来，不从手机来"）。
- **代价**：`plan-mode` 的"继续规划"会把一句反馈当工具错误抛出（`:349-350`），所以手机上
  点「要求修改」后那一轮以工具失败收尾 —— 那是宿主的语义，我们不吞。

## 真机验证（2026-10-25）：桌面有卡、手机没有

仪器：`d61cf622` + 隔离实例（63900 / 直连 8790）+ 中转 8787；桌面侧是**同一个实例**的
Web GUI，跑在 headless Edge 里（`D:\tmp\dsh-e2e\cdp.mjs`）。手机与桌面同时在线。

1. 桌面：侧栏 `Greeting` 行出现 `计划待审`；会话底部出现计划卡（标题 = 计划第一行，
   `要求修改` / `同意执行` 两枚按钮），正文是整份计划。
2. 手机：**同一时刻没有任何卡**。10:52–11:00 的 24 张采样（`p-10-s01…s24`）里只有模型正文
   与「深度求索中，用时 N 分」；输入卡上方空着。`uiautomator` 语义树里也搜不到 plan 字样。
3. 在桌面点 `同意执行` ⇒ 会话日志 `seq:90 plan/mode {"active":false}`（紧接
   `step/end` 之后），该轮继续往下跑 —— 宿主的整条计划审查链是通的。
4. 反面对照（同一轮之后、同一台手机）：让模型用 `ask_user_question` 提一问三选项 ⇒
   **卡正常出现**、选项可选、`提交` 落库（`seq:130 tool/result {"answers":[…]}`）。
   见 `2026-10-25-bottom-budget-and-takeover-card.md` 的真机一节。

结论：**缺口精确在 plan-review 这一种 ask 的手机侧投递/认领**，不是整条 waterfall 链，
也不是手机上的卡片渲染（plan 分支早就在）。本篇"手机上能看能答"的收益**在真机上未成立**。

- 已排除：DSH 侧没有这次交互（桌面有卡且能结算）；转发请求丢 `intent`
  （`api/gateway/src/stream-protocol.ts:146-172` 只删 `agent` / `signal`）；手机缺 plan 卡分支。
- 待查（下一轮，需要一次日志 + 约 1 个模型请求）：`interaction-client.ts` 的 `answerQuestion`
  里 `planReviewOf` 到底认没认出 `intent.kind === 'plan-review'`。认不出会**静默** `next`
  （`:461-472`，而 `log` 走 `ctx.logger`，按 `tools.md` 到不了 stdout），表现与"没收到"完全一样。
  查法：在 `answer()` 里临时加 `console.error`（`tools.md` 记着 console.error 能到 stdout），
  打 `frame.event` / `frame.agentId` / `sidOf()` 的结果，再走一次 `/plan` + 一句 prompt。

## 判据

- connector（`tests/interaction-client.test.ts` +4）：带 `intent.callId` ⇒ claim 且键是
  `t:call-plan`、答复按请求重写成 `{id:'plan-review', selected:['Approve']}`；"继续规划"⇒
  空 `selected`；没有 `intent.callId` ⇒ 回退 `wait.callId`；两者都没有 ⇒ 委托且不 warn。
- flutter（`test/plan_review_test.dart` +5）：`exit_plan_mode` 造 plan 卡（身份 / 正文 / 标题 /
  缺字段不开卡）；`firstHeadingOf` 的读法；答复载荷（同意带标记、拒绝空 selected）；
  卡上看得见正文与两个按钮。
- `pnpm exec tsc --noEmit` 0、`pnpm build` 过、`dart analyze --fatal-infos` 0、`dart format` 0。

## 代码入口回指

`connector/src/dsh/interaction-client.ts`（`planReviewOf` 与身份优先级）、
`connector/src/interaction-claims.ts`（`ClaimRequest.planReview` 与 `settleClaim` 的重建）、
`app/lib/data/projection.dart`（`exitPlanModeTool` / `firstHeadingOf` / plan 卡分支）、
`app/lib/model/interaction.dart`（`kPlanApproveMark`）、`app/lib/ui/takeover.dart`（既有 plan 分支）；
契约 `docs/subsystems/remote-channel.md` §6.3.1 与 §15。
