# Agent Note: 开工单 W2 —— `$events` 换代不撤在途 claim（claim 挂在挂载上，不挂在流上）

Status: proposed

## Problem

`connector/src/dsh/interaction-client.ts:497-504`：一条流走到头（`api/remotes` 重新注册
事件源 / peer 失效 / 任何导致 `for await` 结束的原因）时，我们**撤掉这一代的全部在途
claim**，并 `await Promise.allSettled([...tasks])`：

```ts
} finally {
  generation = null
  clientId = null
  for (const eventId of [...deliveries.keys()]) cancelDelivery(eventId)
  await Promise.allSettled([...tasks])
}
```

`cancelDelivery` → `deps.port.cancelClaim(callId)` → claim 以 `withdrawn` 收束
（`connector/src/interaction-claims.ts:169-177`）⇒ 那条 `waterfall` 的结果**再也回不去**。

后果是一段**真窗口**：手机在这一拍点答 → `interaction.respond` 找不到 claim →
落到提问路由 → DSH 回 `false` → 我们回 `interaction/not-pending`
（`connector/src/interaction-face.ts:380-384`）→ App **撤卡**
（`app/lib/ui/chat_page.dart:378-395`），而桌面那张卡**还在**（gateway 没结算它）。

这条规则的形状与已经删掉的 A4 一模一样：**把一个连接事件翻译成一条语义终态**。

## DSH 的原生语义（逐条）

| 事实 | 出处 |
|---|---|
| 客户端离开只撤**投递**，**不结算** pending | `packages/api/gateway/src/index.ts:717-721` |
| 新 client 上来时把在途事件**重投**给新 client（同一 `eventId`） | `:571`、`:685-689` |
| 结算只由 `{kind:'result'}` / `{kind:'rejected'}` / "全员 `next`" 触发 | `:700-709` |
| 重复或迟到的结果是 no-op（不报错、不结算） | `:696-699` |
| 结算时给其余投递发 `cancel` | `:734-745` |
| "fans one scoped waterfall out and accepts the first Client result" / "delegates to the Host only after every active Client returns next" | `packages/api/gateway/tests/gateway-stream.host.spec.ts:1320`、`:1402` |

也就是说：**claim 的寿命属于 Host 上那条 pending event，不属于某一条传输**。
我们这条 `$events` 流只是"投递"。

## Decision

**claim 的生命周期挂到挂载（插件）上，不挂到流的一代上。**

1. 一代流结束（`finally`）时：**只**把这一代的 `clientId` 与 `deliveries` 表清掉，
   **不** `cancelClaim`；**不** `await` 挂着的 `tasks`（它们属于挂载）。
2. 重投来的同一 `eventId`：`deliveries.has(eventId)` 已有那条 claim ⇒ 直接跳过、不重复
   claim（这条规则今天就在：`interaction-client.ts:416-418`）。
3. 结果回写：`reply()` 在**调用时**读 `clientId`（今天就是这样，`:294-300`），所以换代之后
   手机答的答案会用**新** `clientId` 发出去，而 gateway 那边这条 pending 已经重投给新
   client（`:571`）⇒ `pending.deliveries.has(client)` 成立，结果被接纳。
4. **只有 `dispose()`**（插件卸载 / 进程退出）才撤 claim：那时确实"结果再也发不回去"，
   与 DSH 自己"插件 teardown 时把 waterfall 交还"同构
   （`packages/client/ui-user-questions/src/client/index.ts:199-204` 的 `dispose`）。
5. 结果被 gateway 拒（窗口里别人已经结算 / asker 取消）：**不重试**，只留 warn
   （今天的行为，`:317-321`）。此时"没送到"是正确结局 —— DSH 本来就丢弃迟到应答
   （`user-approval/src/index.ts:303`）。

## 判据（0 真机）

- **单测**：假 gateway 断开当前流（`streams[0]` 结束）→ 打开新一代 → 推**同一 `eventId`**
  的 `waterfall` ⇒ ① 不再 claim（端口只收到一次 `askApproval`）；② 手机答一次 ⇒ 结果用
  **新** clientId 出现；③ 全程没有 `withdrawn`。
- **单测**：流换代**之后**才有人 `cancel` 同一 `eventId` ⇒ 撤在途 claim（不追发结果）。
- **单测**：`dispose()` 时有在途 claim ⇒ `withdrawn` 且不挂住进程（`run()` 能结束）。
- **变异校验**：把 `finally` 里的"不撤 claim"改回"撤" ⇒ 恰好上面第一条红。
- 契约 §15 的那条"换代窗口"改成事实描述：**换代不再让手机看到 `not-pending`**；
  仍存在的窗口只剩"换代之前别人已经答了"（那时 `not-pending` 是对的）。

## 代价

- connector 门禁（611）会变：新增 3 条左右；`interaction-client.test.ts` 里那条
  "换代窗口里不发明 outcome" 的用例要**改写**（它的前提变了，不是放宽）。
- 一处新的挂载级内存：在途 claim 跨代存活（本来就是"一条 claim 可能等十分钟的人"）。
  风险是"流一直连不上、claim 永远挂着" —— 但这正是 DSH 的语义（没人答就一直等，
  契约 §6.2），不是新边界。
- App 侧**不改**：`not-pending` 撤卡对"真过期"仍然正确；只是不再被换代误触发。
- **不需要真机**：这条的判据全在假 gateway 与端口上。

## Alternatives considered

1. **只把 `await Promise.allSettled(tasks)` 去掉，保留撤 claim**
   - 最强的理由：改动更小，重连不再被挂住的 claim 拖住。
   - 为何不选：撤了 claim 就等于"结果丢了"，手机点答仍然拿 `not-pending`；症状不变。
2. **换代时撤 claim，但让 `interaction.respond` 在 `not-pending` 后自动重试一次**
   - 为何不选：这是"终态被当成可重试"的反面版本（把可重试的当终态，再加一层重试去补），
     且 App 已有"留卡可重试"的分支（B3），两条重试会叠在一起。
3. **让 claim 跟着 `$events` 的 `clientId` 走（换代 = 新 claim）**
   - 为何不选：等于把"宿主上的那条 pending"复制成每代一份，同一条交互会有两个等待者。

Note: 本单来自总账 `.agents/notes/proposed/2026-10-24-native-rules-audit.md` 的 C13；
同族的判定见该篇"根因分段 2"（把连接态当语义态）。
