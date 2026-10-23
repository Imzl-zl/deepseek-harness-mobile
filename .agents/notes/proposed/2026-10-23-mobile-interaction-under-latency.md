# Agent Note: 在途交互是 host-held pending —— 断线只换投递通道，不结算

Status: proposed

## Problem

先纠正一个模型：提问**不是"Web 传给 App"**。它是 agent 里 `ctx.userQuestions.ask()` / `approval.request()`
发起的一次 waterfall；DSH Web 客户端与我们的连接器是**两个并列的 answerer**（我们 `prepend`，见
`connector/src/dsh/interactions.ts` 的文件头）。claim 之后桌面看不到这次交互 —— 这是 §6.2 的既有语义。

所以"重连后 Web 的还在、App 的没了"要拆成两件事：

- **Web 的为什么还在**：DSH 的 gateway 把在途请求当成 **host-held pending**，断线只撤投递、不结算，
  新客户端连上来会**重新投递**（`packages/api/gateway/src/index.ts:227` 的 `pendingRemoteEvents`、
  `:571` 新 client 注册时逐条重投、`:685-689` 的 `deliverRemoteEvent`、`:717-721` 断开只
  `removeRemoteEventDelivery`、`:696-698` 迟到/重复的答复是幂等 no-op）。它没有超时 —— 请求一直挂着，
  直到被答复、被取消或 source 关闭。
- **App 的为什么没了**：我们的连接器在设备离开服务态时**主动结算 claim**
  （`connector/src/interaction-claims.ts:222` 审批、`:273` 提问），理由写的是"手机不看了就立刻还桌面"。
  但 claim 一旦做出，桌面**拿不回来**（waterfall 已经过了它）：抛错只会让工具失败。也就是说，
  这条规则的名义收益不存在，实际效果是"一次 socket 抖动 / 一次重连 = 提问失败、卡片消失"。
  而 `presence.offline` 在**重连中**也会触发（`connector/src/presence.ts:54,118-123`）。

这是同一个设计问题：**在途交互的寿命应该挂在 host 上，而不是挂在某条连接上。**

### DSH 的成熟方案（可直接照搬的形状）

| 层 | DSH gateway | 我们 |
|---|---|---|
| 在途集合 | `pendingRemoteEvents`（host 内存，键是请求 id） | `claims`（host 内存，键是 callId）——**已经有了** |
| 投递 | 每个连上来的 client 一份（`:571`、`:685-689`） | `ev` 帧（会话事件）+ App 的接管桶 |
| 断线 | 只撤投递，**不结算**（`:717-721`） | **结算并抛错** ← 偏差在这里 |
| 重连 | 重投 pending（`:571`） | 不重投；卡片靠 App 内存里的桶 ← 第二个偏差 |
| 结算 | 首个答复赢；重复/迟到 no-op（`:696-698`） | `settleClaim` 首个赢；`i:<callId>` 幂等键 ——**已经对上** |
| 取消 | source / context 释放（`:635-641`、`:728-732`） | asker 的 signal、会话被替换 ——**已经对上** |
| 超时 | **没有** | 看护 10 min（契约 §6.2 的 fail-closed，**保留**） |

结论：我们缺的不是协议，而是**两处对齐** —— 断线不结算（P2a）、重连重投（P2b）。

### 第二处（App）：所有失败都被当成"已过期"

- `app/lib/ui/chat_page.dart:371-384`：`on Exception` 一律 `settle(itemId)` + 弹「这一项已过期」；
- `app/lib/ui/takeover.dart:340-449`：三个提交方法都是 `_busy = true` → `await _submit` → 写成功回执
  → `settle`，**没有 `try/finally`**；`_submit` 失败时回执仍然会写（「已回答 · …」），因为失败在
  `chat_page` 那层被吞掉了。

网络抖一下：卡片被撤（不能重试）、对话流里多一条「已回答」。**既没答上，又假装答上了。**

## Decision

四步；P1 / P2 都不改部署，P3 是可选的原生升级，P4 是另一件事。

**P1（App）：失败分类。**
- `interaction/not-pending` → 撤卡 +「已过期」；其余（传输 / 超时 / 未知）→ **留卡** +「没发出去，再试一次」。
- 失败不写成功回执、不 `settle`；`_busy` 用 `finally` 复位。
- 判据：控制器单测（失败时 `receipts` 为空、`active` 仍在、`busy` 复位）+ 接线单测。

**P2a（连接器）：连接离开不结算 claim（审批与提问同一规则）。**
- 删掉两处 `presence.onOffline(deviceId, () => watchdog.disconnect())`；`onAbort`（asker 取消）与看护
  超时照旧。会话被替换那条丢弃逻辑不动。
- 依据：上面那张表 —— DSH 自己的 gateway 在断线时只撤投递。
- 代价：用户真的走了，模型白等最多 10 min（不烧 token）；审批那条也一起改（它同样拿不回桌面）。
- 判据：端口单测（设备离线不立刻抛、重连后 `settleClaim` 成功、看护到点仍抛、取消仍抛）。

**P2b（连接器）：手机重新订阅时，把该 sid 上仍在途的 ask 事件重发一遍。**
- 与 gateway 的 `deliverRemoteEvent(pending, client)` 同形：claim 里存下那次 ask 的事件
  （`approval/asked` 或 `tool/call`），在 `session.subscribe` 的恢复之后按原 seq 再发一次 `ev`。
- **不新增帧类型、不新增方法**：卡片本来就来自会话事件，App 按 `itemId` upsert，重发天然幂等。
- 解决的是"App 被杀掉重开"那一档：claim 还活着，但接管桶是内存态，事件水位已经越过那条 ask。
- 判据：连接器单测（订阅时只重发在途的、settled 的不发、重发的是原 seq）+ App 单测
  （同一个 `itemId` 二次入桶仍只有一张卡）。

**P3（可选，部署 + 连接器 + App）：timed。**
- 它解决的是**看护之后**才答的那一段（迟到答案成为用户消息、投影 `open/continued`），**不是**重连问题
  —— 重连靠 P2a/P2b 就够了。
- 代价仍是：桌面提问卡带倒计时、模型 120 s 后继续；且**只改部署不改端口 = 白改**
  （端口抢先抛错，`askTimed` 会重抛，`user-questions/src/index.ts:249-263`）。
- 单列，要你点头；不做的理由也成立。

**P4（另一件事）：计划审查卡。**
- `/exit_plan_mode` 的 `ask()` 带 `intent.callId`（`plan-mode/src/index.ts:313-330`），但卡只从
  `ask_user_question` 的 `tool/call` 生成 ⇒ 手机上永远没有计划审查卡。
- 要做就得让 App 从 `exit_plan_mode` 的 `tool/call` 渲染一张卡（`arguments` 里就是计划正文），单列。

## Alternatives considered

1. **只做 P1（保持断线即失败）**
   - 最强的理由：桌面零变化；失败快；模型不白等。
   - 为何不选：移动端最常见的失败就是"切后台 / socket 抖一下 / 重连中"，而它会让提问直接失败。
     P1 只能让失败变得诚实。
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
   - 为何被否：契约 §6.3 明确"待处理集合是会话事件的投影"；P2b 用重发事件就能达到同一效果，
     不必新增方法面（38 个方法名是封闭集）。
6. **App 自己重读一页历史再投影**
   - 最强的理由：连接器零改动。
   - 为何被否：那要把 `interactionSignalOf` 从"摄入时"扩到"加载时"，等于在 App 里再建一份
     待处理集合；重发事件是更薄的一层（而且与 gateway 同形）。

## Consequences

- 收益（P1）：网络抖一下不再被说成"已过期"，也不会留一条假的「已回答」；卡片可重试。
- 收益（P2a）：切后台 / socket 抖动 / 重连中 ≤10 min 内回来，提问与审批都还能答 —— 这是移动端
  最常见的失败形态，改动只有两行 `onOffline`。
- 收益（P2b）：App 被杀掉重开，卡片会随重发回来；claim 与卡片重新对齐，用户不必"再问一次"。
- 收益：整套设计只用了已有的两样东西（host 内存里的 claim 表 + 会话事件），**没有新协议、没有新方法、
  没有新帧**；幂等仍是 `settleClaim` 首个赢 + `i:<callId>` + `itemId` upsert。
- 代价（P1）：`onAnswer` 的契约从"吞掉失败"变成"把失败交回控制器"。
- 代价（P2a）：用户真的离开时，模型白等最多 10 min（不烧 token）；契约 §6.2 的 fail-closed 表要改
  （"断开"从触发项里去掉，只留超时 / 取消 / 会话被替换）。
- 代价（P2b）：订阅路径多一次"重发在途 ask"的扫描（每个 sid 的 claim 数很小）；如果 claim 在重发与
  送达之间被结算，App 可能短暂看到一张已被答掉的卡 —— 下一次答复会拿到 `not-pending` 并撤卡，
  与今天的"迟到即丢弃"同构。
- 代价（P3，若做）：桌面倒计时 + 模型 120 s 后继续；`QuestionPrompt.timed` 要加回来并真的被端口读
  （本轮的清理删了它，因为它当时没有读者）。
- 真机：P1 / P2 都能在单测与 widget 测试里证；P3 的"看护之后才答"才需要真机（约 1–2 轮）。

代码入口回指（P1 / P2 落地时补）：`app/lib/ui/takeover.dart` 的三个提交方法、
`app/lib/ui/chat_page.dart` 的 `_onTakeoverAnswer`、`connector/src/interaction-claims.ts` 的两处
`onOffline`、`connector/src/session-subscriptions.ts` 的订阅恢复之后。
