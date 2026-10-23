# Agent Note: 在途交互是 host-held pending —— 断线只换投递通道，不结算

Status: implemented

## Problem

先纠正一个模型：提问**不是"Web 传给 App"**。它是 agent 里 `ctx.userQuestions.ask()` / `approval.request()`
发起的一次 waterfall；DSH Web 客户端与我们的连接器是**两个并列的 answerer**（我们 `prepend`，见
`connector/src/dsh/interactions.ts` 的文件头）。claim 之后桌面看不到这次交互 —— 这是 §6.2 的既有语义。

"重连后 Web 的还在、App 的没了"因此要拆成两件事：

- **Web 的为什么还在**：DSH 的 gateway 把在途请求当成 **host-held pending**。断线只撤投递、不结算；
  新客户端连上来会**重新投递**（`packages/api/gateway/src/index.ts:227` 的 `pendingRemoteEvents`、
  `:571` 新 client 注册时逐条重投、`:685-689` 的 `deliverRemoteEvent`、`:717-721` 断开只
  `removeRemoteEventDelivery`、`:696-698` 迟到/重复的答复是幂等 no-op）。它没有超时 —— 请求一直挂着，
  直到被答复、被取消或 source 关闭。
- **App 的为什么没了**：我们的连接器在设备离开服务态时**主动结算 claim**
  （`connector/src/interaction-claims.ts` 的两处 `presence.onOffline`），理由写的是"手机不看了就立刻
  还桌面"。但 claim 一旦做出，桌面**拿不回来**（waterfall 已经过了它）：抛错只会让工具失败。
  而 `presence.offline` 在**重连中**也会触发（`connector/src/presence.ts:54,118-123`）——
  一次 socket 抖动 / 一次切后台，提问与审批就当场死。

第二处（App）：所有失败都被当成"已过期"——

- `app/lib/ui/chat_page.dart` 的 `_onTakeoverAnswer`：`on Exception` 一律 `settle(itemId)` + 弹「已过期」；
- `app/lib/ui/takeover.dart` 的三个提交方法：`_busy = true` → `await _submit` → 写成功回执 → `settle`，
  **没有 `try/finally`**；`_submit` 失败时回执仍然会写（「已回答 · …」），因为失败在 `chat_page` 那层
  被吞掉了。

网络抖一下：卡片被撤（不能重试）、对话流里多一条「已回答」。**既没答上，又假装答上了。**

## Decision

**在途 claim 的寿命挂在 host 上，不挂在某条连接上；断线只换投递通道，重连重投在途 ask 事件；
App 按错误码决定卡片去留。** 三处落点：

1. **连接器 · 断线不结算**（`interaction-claims.ts`）：删掉审批与提问两处
   `presence.onOffline(deviceId, () => watchdog.disconnect())`。claim 只由四件事收束：**答复**、
   **asker 取消**（原 signal）、**会话被替换**（`settleClaim` 的 sid 检查）、**看护超时**（10 min，
   契约 §6.2 的 fail-closed 保留）。claim 之前设备就不在线仍然立刻抛（没有投递目标）。
2. **连接器 · 重连重投**（`session-subscriptions.ts` + `interaction-claims.ts` + `dsh/ask-event.ts`）：
   - 应答者把那次 ask 的会话事件（`approval/asked` / `tool/call`）以 `{seq, body}` 随 prompt 带进 claim；
   - 端口用 `pendingAsks(sid)` 给出仍在途的那些；
   - `session.subscribe` 的恢复（补发之后、快照**之前**）按**原 seq** 再发一遍 `ev`。
   **不新增帧类型、不新增方法**：卡片本来就来自会话事件，App 按 `itemId` upsert，重发天然幂等 ——
   与 gateway 的 `deliverRemoteEvent(pending, client)` 同形。
3. **App · 失败分类**（`takeover.dart` + `chat_page.dart`）：
   - `interaction/not-pending` → 撤卡 +「已过期」（客户端动作正是"刷新待处理列表"）；
   - 其余（传输 / 超时 / 未知）→ **留卡** +「没发出去，再试一次」；
   - 失败**不写成功回执、不撤卡**；`_busy` 用 `finally` 复位（抽成 `_send`，三个提交方法共用）。

准入门槛（可机械判定）：

1. **claim 的收束条件只有四个**（答复 / 取消 / 会话被替换 / 看护超时）；"设备断开"不在其中。
2. **重投只发仍在途的**：claim 表里没有的不发；发的是**原 seq 与原 body**（不推进水位）。
3. **幂等仍是三条老规矩**：`settleClaim` 首个赢、`i:<callId>` 幂等键、App 按 `itemId` upsert。
4. **App 的失败分类只认 `interaction/not-pending` 为"没了"**；其余一律留卡可重试。

**没有采用的两项**（不是遗漏，是明确不做）：

- **timed 部署**：它只解决"看护 10 min 之后才答"的那一段，**不解决重连**；代价是桌面提问卡带倒计时、
  模型 120 s 后返回 `pending` 继续。且只改部署不改端口等于白改（端口抢先抛错时 `askTimed` 会重抛，
  `user-questions/src/index.ts:249-263`）。要做需要单独决定。
- **计划审查卡**：`/exit_plan_mode` 的 `ask()` 带 `intent.callId`，但卡只从 `ask_user_question` 的
  `tool/call` 生成，手机上永远没有计划审查卡。要做就得让 App 从 `exit_plan_mode` 的 `tool/call`
  渲染一张卡（`arguments` 里就是计划正文），那是另一条 App 面。

## Alternatives considered

1. **只做 App 失败分类（保持断线即失败）**
   - 最强的理由：桌面零变化；失败快；模型不白等。
   - 为何被否：移动端最常见的失败就是"切后台 / socket 抖一下 / 重连中"，而它会让提问直接失败。
     App 侧只能让失败变得诚实。
2. **把看护从 10 min 加到 60 min**
   - 最强的理由：不改语义、只调参数。
   - 为何被否：它根本不走断线那条路（`onOffline` 立刻收束），覆盖不到真正的失败原因。
3. **直接上 timed（不改端口）**
   - 最强的理由：投影、`answer()`、迟到答案都是现成的。
   - 为何被否：端口在断开时抢先抛错，`askTimed` 会重抛 ⇒ 工具照样失败；而且它改的是**模型行为**
     （120 s 后继续），不该拿来当"重连修复"。
4. **给在途 claim 加持久化（落盘）**
   - 最强的理由：连接器重启也能恢复。
   - 为何被否：连接器与 DSH 同进程，进程没了工具调用也早没了；持久化只会留下一份永远等不到
     答复的记录。DSH 的 gateway 也是纯内存的。
5. **新增 `interaction.pending` 方法 / `pending.changed` 帧**
   - 最强的理由：最直接，App 一拉就有。
   - 为何被否：契约 §6.3 明确"待处理集合是会话事件的投影"；重投事件就能达到同一效果，
     不必新增方法面（38 个方法名是封闭集）。
6. **App 自己重读一页历史再投影**
   - 最强的理由：连接器零改动。
   - 为何被否：那要把 `interactionSignalOf` 从"摄入时"扩到"加载时"，等于在 App 里再建一份
     待处理集合；重投事件是更薄的一层（而且与 gateway 同形）。

## Consequences

- 收益：切后台 / socket 抖动 / 重连中 ≤10 min 内回来，提问与审批都还能答；App 被杀掉重开，
  卡片会随重投回来 —— claim 与卡片重新对齐，用户不必"再问一次"。
- 收益：整套设计只用了已有的两样东西（host 内存里的 claim 表 + 会话事件），**没有新协议、没有新方法、
  没有新帧**；幂等仍是 `settleClaim` 首个赢 + `i:<callId>` + `itemId` upsert。
- 收益（App）：网络抖一下不再被说成"已过期"，也不会留一条假的「已回答」；卡片可重试。
- 代价：用户真的离开时，模型白等最多 10 min（不烧 token）。审批那条也一起改了 —— 它同样拿不回桌面。
- 代价：订阅路径多一次"重投在途 ask"的检查（每个 sid 的 claim 数很小）；若 claim 在重投与送达之间
  被结算，App 可能短暂看到一张已被答掉的卡 —— 下一次答复会拿到 `not-pending` 并撤卡，
  与"迟到即丢弃"同构。
- 代价：`onAnswer` 的契约从"吞掉失败"变成"把失败交回控制器"（`_send` 只负责复位 busy）。
- 判据（连接器，612 → 618）：`interaction-claims.test.ts`（断开不结算 —— 审批与提问各一条 /
  断开后看护到点仍抛 / `pendingAsks` 只给在途的）、`interaction-chain.test.ts`（整链断开后仍能答）、
  `interactions.test.ts`（审批与提问的 prompt 都带重投载荷）、
  `session-subscriptions.test.ts`（重投按原 seq 且先于快照）。
- 判据（App，1137 → 1140）：`takeover_test.dart`（失败不写回执、不撤卡、busy 复位）、
  `chat_takeover_wiring_test.dart`（传输失败留卡 / `not-pending` 撤卡）。
- 变异校验（都做过）：① 把"断线不结算"改回 `watchdog.disconnect()` ⇒ **3 条红**（两条"断开"用例 +
  "断开后看护到点"那条 —— 断开先以 `disconnected` 收束，看护那条也就到不了 `timeout`）；
  ② 删掉订阅里的重投循环 ⇒ **恰好 1 条红**；③ App 的 `_send` 忽略 `sent`（失败也写回执/撤卡）⇒
  **恰好 2 条红**（控制器那条 + 传输失败接线那条）。
- 门禁：connector **618** / flutter **1140** / boundary **360**；**0 个真机回合**（重连时序在单测里
  用"设备离线 → 答复仍落"证）。

代码入口回指：`connector/src/interaction-claims.ts` 的 `askApproval` / `askQuestion` 注释、
`connector/src/session-subscriptions.ts` 的 `pendingOf`、`connector/src/dsh/ask-event.ts` 的文件头、
`app/lib/ui/takeover.dart` 的 `_send`、`app/lib/ui/chat_page.dart` 的 `_onTakeoverAnswer`。
