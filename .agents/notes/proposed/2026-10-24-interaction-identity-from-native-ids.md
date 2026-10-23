# Agent Note: 开工单 W1 —— 交互身份改读原生（`ApprovalRequestId` / `intent.callId` / `itemId`）

Status: proposed

## Problem

「手机能不能答这一次交互」的判据，现在被钉在**一个** `callId` 上，而这个 id 在两种原生
形态里**根本不存在**：

1. **审批**：`callId` 是**可选**的（`packages/interaction/user-approval/src/types.ts:68-69`，
   `callId?: ToolCallId`），`approval/asked` 落盘时也是"有才写"（`src/index.ts:228`）。
   我们没拿到就 `next()`（`connector/src/dsh/interaction-client.ts:330-335`）——
   而 DSH 的浏览器在 `callId === undefined` 时**照样弹卡、照样答**
   （`packages/client/ui-approval/src/client/index.ts:45-53`、`:59-65`：`PendingApproval`
   不要求 callId，`pending.result` 也不看它）。
   后果比"少答一类"更宽：这条审批**连重投也拿不到** —— 重投按 `callId` 匹配
   `approval/asked`（`connector/src/dsh/ask-event.ts:54-68`）。

2. **计划审查**：`/exit_plan_mode` 是**程序化** `ask()`，没有 `wait`，但**带 `intent.callId`**
   （`packages/plan/plan-mode/src/index.ts:313-330`，`callId: exec.callId` 在 `:326`）。
   我们只读 `wait.callId`，再退到"日志里唯一一条未结算的 `ask_user_question`"
   （`connector/src/dsh/interaction-client.ts:368-380`）—— 而 `/exit_plan_mode` 的
   `tool/call` 名字是 `exit_plan_mode`（`plan-mode/src/index.ts:277-282`），永远匹配不上
   ⇒ 身份 = `none` ⇒ 委托。
   于是**计划审查卡在手机上永远不出现**：`InteractionKind.plan` 在全仓只有一个生产者，
   是演示入口（`app/lib/ui/chat_page.dart:2385-2388` ← `_enqueueDemoTakeovers`）。

根的同一个形状是：**"这件事的身份"被写成了"某个具体形态的 id"**。DSH 有三处原生身份，
我们只认一处：

| 交互 | DSH 的原生身份 | 出处 |
|---|---|---|
| 审批 | `ApprovalRequestId`（服务铸，一对一配对 `approval/asked` / `approval/decided`） | `user-approval/src/types.ts:13-17`、`src/index.ts:224-232` |
| 提问（timed） | `wait.callId` | `user-questions/src/types.ts:136-145` |
| 提问（计划审查） | `intent.callId` | `user-questions/src/types.ts:33-34`、`plan-mode/src/index.ts:326` |
| 提问（legacy） | `tool/call` 的 `callId`（日志推断，手机可见的也只有它） | `connector/src/dsh/question-call.ts:76-95` |

而手机侧**早就在用**审批的原生 id 当卡 id（`app/lib/data/projection.dart:997,1003`：
`itemId: 'i:$approvalId'`），只是被 `callId == null` 那个提前返回挡住了（`:995-996`）。

## Decision

**待处理项的身份 = 手机卡上的 `itemId`，它的取值是两个原生 id 之一：**

- 审批：`i:<approval/asked.id>`（`ApprovalRequestId`）
- 提问 / 计划审查：`t:<callId>`

`interaction.respond` 的入参从 `{sid, callId, answers}` 改成 `{sid, itemId, answers}`；
连接器的在途 claim 表以 `itemId` 为键（不再以 `callId` 为键）。

### 身份的来源（按顺序，第一条成立就用它）

**审批**（`connector/src/dsh/interaction-client.ts` 的 `answerApproval`）：

1. 请求里带 `callId` ⇒ 在会话日志里找 `callId` 相同、且没有同 `id` 的
   `approval/decided` 的那条 `approval/asked`，取它的 `id`。这正是
   `ask-event.ts:54-68` 已经在做的事，把它拆成"认身份"与"取重投载荷"两个用途。
2. 不带 `callId` ⇒ 取日志里**唯一**一条未结算的 `approval/asked` 的 `id`。
3. 0 条 / ≥2 条 ⇒ `next()`（委托，不抛也不猜）。判据与失败方向照抄
   `connector/src/dsh/question-call.ts` 的写法（那边已经有这套"恰好一个"的机械判据）。

**提问**（`answerQuestion`）：`wait.callId` → **`intent.callId`** → 日志推断
（`resolveQuestionCall`，只认 `ask_user_question`）→ 都没有就 `next()`。

### 手机侧

- `interactionSignalOf` 的审批分支：**去掉 `callId == null` 的提前返回**
  （`app/lib/data/projection.dart:993-996`），卡照开；`callId` 变成"有就带上"的展示/关联字段。
- 提问分支不变（`t:<callId>` 本来就是原生身份）。
- `respondInteraction` 发 `itemId`（`app/lib/data/app_model.dart:3148-3161`），幂等键
  `requestId` 也用它（现在写的是 `i:<callId>`，与卡 id 不是同一个东西）。

### 连接器侧

- `ClaimRequest.callId` → `ClaimRequest.itemId`（`connector/src/interaction-claims.ts:63-77`）。
- `settleClaim(sid, itemId, answers)`；审批的词汇表映射不动（`allowed-once` 是 DSH 的，
  `user-approval/src/types.ts:32`）。
- `interaction-face.ts` 的应答路由：先 `settleClaim(itemId)`；没认下就把 `t:` 前缀解回
  `callId` 走 `userQuestions.answer`（`continued` 提问那条原生路，
  `user-questions/src/index.ts:164-206`）；`i:` 前缀在 claim 之外**没有落点**
  （DSH 没有"按 approval id 作答"的方法）⇒ 回 `interaction/not-pending`。
- **顺手删死码**：`InteractionFace.pendingOf` / `projectPendingQuestions` /
  `PendingItem`（生产零调用，只有 `connector/tests/interaction-face.test.ts:139-142` 用）。
  `itemIdOf` 保留并成为**唯一**的 id 表达处（现在它的 `i:<callId>`
  （`interaction-face.ts:101-105,132-134`）与手机侧的两种约定都不一致）。

## 判据（做完了怎么算对）

- **单测（0 真机）**：假 gateway 推一条**没有 `callId`** 的 `approval/request` ⇒ 连接器
  claim 一条 `i:<approvalId>` 的交互，手机答 `itemId` 后回 `{kind:'result'}`。
- **单测**：推一条带 `intent.callId` 的 `user-questions/request`（无 `wait`）⇒ claim 成功，
  计划审查的答案批次原样回给 waterfall（`selected` 含 approve 标签即同意 —— DSH 的规则，
  `user-questions/src/types.ts:28-30`）。
- **单测**：日志里两条未结算 `approval/asked` ⇒ `next()`（不猜）。
- **变异校验两组**：① 把"读 `intent.callId`"删掉 ⇒ 恰好计划审查那条红；② 把审批的唯一性判据
  改成"取最后一条" ⇒ 恰好"两条未结算"那条红。
- **真机 1 个回合**（本条唯一的真机项）：一个会触发 `/exit_plan_mode` 的回合，手机能看到
  计划审查卡并答"同意执行"。报价 **1 回合**。

## 代价

- **契约**：§5.7 的 `interaction.respond` 行（`docs/subsystems/remote-channel.md:376`）要改参数名
  与键形状；§6.2 的"没有稳定身份"两条并成一条更准确的表述；`app/lib/model/interaction.dart`
  与 `docs/` 的字段名同批改。
- **门禁**：protocol **454**（fixtures 的断言内容变；若增删断言，两侧同改并把 454 更新到
  `AGENTS.md` / `tools.md` / `memory.md` 三处）、connector **611**、flutter **1140**、
  boundary **360**。**改断言必须做一次变异校验。**
- **不会变好的一件事**：手机在**没订阅**那个会话时仍然看不到卡（B12，通道形态，不属本单）。

## Alternatives considered

1. **只补 `intent.callId`，不动审批的键**（最小改动）
   - 最强的理由：计划审查立刻可用，契约一个字不改。
   - 为何不选：B2 那条"没有 `callId` 就不参与"仍然在；而且同一件事会有两套键
     （审批 `callId`、计划审查 `intent.callId`），第三个形态出现时又要加一处。
2. **让手机直接发 `approvalId` / `callId` 两个字段**（不改键、加一个可选字段）
   - 最强的理由：向后兼容老手机。
   - 为何不选：本仓没有在用的旧手机（配对即同版本），而"两个键哪个优先"就是第二份真值。
3. **给审批加一个"按 approval id 作答"的 DSH 方法**
   - 为何不选：DSH 没有这个面，凭空造一个就是把"替宿主决定"换个地方犯。

## 不做的事

- 不改 `approval/asked` / `approval/decided` 的事件形状（那是宿主落盘格式）。
- 不为"≥2 条未结算审批"发明队列/优先级（原生就是并发，认不出就委托）。
- 不改审批的 outcome 词汇表（`allowed-once` 是唯一授权值，`user-approval/src/types.ts:32`）。
- 不碰 `approval/asked` 的 `callId` 可选性。

Note: 本单来自总账 `.agents/notes/proposed/2026-10-24-native-rules-audit.md` 的 B1 / B2 / B6 /
C11 / N1 / N3 / N4；原则见 `implemented/2026-10-24-native-semantics-first.md`。
