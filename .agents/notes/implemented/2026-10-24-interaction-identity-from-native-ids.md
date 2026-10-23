# Agent Note: 交互身份改读原生 —— 审批用 `ApprovalRequestId`，`interaction.respond` 的键是 `itemId`

Status: implemented

## Problem

「手机能不能答这一次交互」的判据，原来被钉在**一个** `callId` 上，而它在两种原生形态里
根本不存在：

1. **审批**：`callId` 是**可选**的（`packages/interaction/user-approval/src/types.ts:68-69`），
   `approval/asked` 落盘时"有才写"（`src/index.ts:228`）。没有它就 `next()` ——
   而 DSH 的浏览器照样弹卡照样答（`client/ui-approval/src/client/index.ts:45-53`、`:59-65`）。
   后果比"少答一类"更宽：这条审批连**重投**也拿不到（`ask-event.ts` 原先按 `callId` 匹配）。
2. **提问**：问题不在 `callId`（它确实是提问的原生身份），而在**"卡的身份"被写成了
   "某个具体形态的 id"** —— 审批卡的 id 是 `i:<approvalId>`、提问卡是 `t:<callId>`
   （`app/lib/data/projection.dart:997,1003,1031`），而 wire 上只有一个 `callId` 字段，
   于是两种身份必须有一个"伪装成"另一个。

## Decision（已落地）

**待处理项的身份 = 手机那张卡的 `itemId`**，取值是两个原生 id 之一：

- 审批：`i:<approval/asked.id>`（`ApprovalRequestId`，服务铸、与 `approval/decided` 一对一）
- 提问 / 计划审查：`t:<callId>`

`interaction.respond` 的入参从 `{sid, callId, answers}` 改成 `{sid, itemId, answers}`；
连接器的在途 claim 表以 `itemId` 为键；手机发回的键与幂等键都是它。

### 身份的来源（第一条成立就用它）

**审批**（`connector/src/dsh/approval-call.ts`，新文件）：
请求带 `callId` ⇒ 按它精确配未结算的 `approval/asked`；不带 ⇒ 取**唯一**一条未结算的；
0 条 / 多条 ⇒ `next()`（委托，不猜）。

**提问**（`connector/src/dsh/interaction-client.ts`）：`wait.callId` → 日志推断
（`resolveQuestionCall`，只认 `ask_user_question`）→ 都没有就 `next()`。**没有把
`intent.callId` 接进这条链** —— 理由见下面的"没落地的"。

### 手机侧

- `interactionSignalOf` 的审批分支**不再要求 `callId`**，卡照开；`callId` 降级为
  "这条交互针对哪次工具调用"的展示字段（`app/lib/model/interaction.dart` 里变成 `String?`）。
- `InteractionAnswer` 去掉 `callId`，只留 `itemId`；`respondInteraction` 发 `itemId`、
  幂等键也用它（`app/lib/data/app_model.dart`）。
- `TakeoverController` 的三处答复构造改用 `item.itemId`（审批的答案项 id 只是非空占位，
  DSH 的审批答案看的是 `selected` 里的 `allowed-once`）。

### 连接器侧

- `ClaimRequest.itemId`（`interaction-claims.ts`）；`settleClaim` / `cancelClaim` 都按它。
- `interaction-face.ts`：应答路由 = ① 先问在途 claim；② 没认下就按前缀分叉 ——
  `t:` 走 DSH 的 `userQuestions.answer`（`continued` 提问那条原生路），
  `i:` 直接 `interaction/not-pending`（**DSH 没有"按 approval id 作答"的方法**），
  认不出的前缀是 `protocol/bad-frame`。
- **删死码**：`InteractionFace.pendingOf` / `projectPendingQuestions` / `PendingItem`
  （生产零调用，只有单测用），`itemIdOf` 换成 `approvalItemId` / `questionItemId` /
  `interactionItemOf` 三个**只有一处表达**的函数。
- `ask-event.approvalAskEvent` 改按 `id` 匹配（不再按 `callId`），于是"没有 tool call 的审批"
  也能被重投。

## 没落地的（原提案里写了，查完源码后**主动不做**）

**计划审查不 claim（不读 `intent.callId`）。** 原提案写的是"身份链里加 `intent.callId`"，
查完后发现这只修了**一半**：

- 身份是有的（`/exit_plan_mode` 的 `ask()` 带 `intent.callId`，`plan-mode/src/index.ts:326`），
- **但手机上那张卡不存在** —— 手机的提问卡只从 `ask_user_question` 的 `tool/call` 生成
  （`projection.dart:1020-1043`），`exit_plan_mode` 只落一条普通工具行。

claim 一条用户**看不到**的交互，会把 DSH 原生的 fail-closed（没有任何 answerer 时抛
`NO_PROVIDER`，`user-questions/src/index.ts:318-321`）换成一个**永远等不到人**的挂起 ——
比现在更坏。要让手机答计划审查，缺的是"卡来自请求"这条投递（B12 的升级），不是少读一个字段。
所以：**代码不动，把限制如实写进契约 §15 与 §6.3.1**（本次已写），C11 在总账里从
`设计缺陷` 改判为 `未实现`。

## 证据（0 个真机回合）

- **connector 611 → 615**：`interaction-client.test.ts` 那条"没有 callId 就委托"换成三条
  （无 `callId` 照样 claim / 一条 `approval/asked` 都没有 → 委托 / 两条 → 委托）；
  `interaction-face.test.ts` 删掉两条 `pendingOf` 用例、加四条 `itemId` 路由用例
  （审批走 claim、不在 claim 里的 `i:` → `not-pending`、认不出前缀 → `bad-frame`、缺 `itemId`
  → `bad-frame`）。**没有放宽**：删掉的三条断言的**行为**本身被删了（死码），其余全是新增。
- **flutter 1140（数值不变，全绿）**：`interaction_projection_test` 的"没有 callId 就不开卡"
  改成"也开卡、id 是 `i:<approvalId>`"；`interaction_wiring_test` 断的是新载荷
  （`itemId` + 幂等键同值）；`takeover_test` 断答复用 `item.itemId`。
- **变异校验两组**（做完即还原）：
  ① `approval-call.ts` 恢复旧规则（`callId === undefined` 时恒 `none`）⇒ **恰好 2 条红**
  （"无 callId 照样 claim" + "两条未结算 → 委托"），其余 26 条绿；
  ② `interaction-face.ts` 把 `i:` 分支关掉 ⇒ **恰好 1 条红**（"不在 claim 里的 `i:` →
  not-pending"），其余 17 条绿。
- **DSH 侧证据全是源码行号**：`user-approval/src/types.ts:13-17,68-69`、`src/index.ts:224-232`、
  `client/ui-approval/src/client/index.ts:45-53`；`user-questions/src/index.ts:164-206,318-321`；
  `gateway-stream.host.spec.ts:1320`（fan-out + 第一个 result 结算）、`:1402`（全员 next 才交还）。

## 顺手修的红门禁（独立提交 `2da3745`）

`app/test/fixtures_test.dart` 还写死"16 条 fixtures"，而 `fce4f9e` 已删掉 fixture 16 ⇒
`flutter test` 从那时起**一直是红的**（上一轮报的"1140 全绿"漏了这个文件）。
现在改成 15，并在文件头写清"条数四处同步"的纪律。

## 代价与后果

- **契约**：§5.7 的 `interaction.respond` 行、§6.2 的"没有稳定身份"两条、§6.3（新增一句
  "claim 判据是会话登记不是订阅"）、§6.3.1（新增"审批身份从日志认"与"计划审查只能看不能答"）、
  §15（两条新限制）。已全部同批改完。
- **老连接器 / 老手机不兼容**：`callId` → `itemId` 是**载荷字段改名**，没有双读兼容。
  本仓没有在用的旧版本（配对即同版本），这是有意的：两个键并存就是第二份真值。
- **仍未做**：计划审查在手机上只能看不能答（要"卡来自请求"的投递）；
  审批认不出身份时仍只有桌面能答（原生委托）。

## 代码入口回指

`connector/src/dsh/approval-call.ts`（审批身份）、`connector/src/dsh/interaction-client.ts`
（身份链与 claim）、`connector/src/interaction-claims.ts`（`itemId` 表）、
`connector/src/interaction-face.ts`（`itemId` 前缀路由）、
`app/lib/model/interaction.dart` / `app/lib/data/projection.dart` / `app/lib/ui/takeover.dart`。

Note: 来自总账 `.agents/notes/proposed/2026-10-24-native-rules-audit.md` 的 B1 / B2 / B6 / N1 /
N4；计划审查那条（C11）在那篇里已按本篇的结论改判。
