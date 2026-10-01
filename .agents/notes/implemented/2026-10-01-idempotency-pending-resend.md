# Agent Note: 停在 `pending` 的键应当**重发**,而不是拒绝 —— 下游真的认得出重复

Status: implemented（取代 `2026-10-01-idempotency-two-phase.md` 里"pending 时 fail-closed 拒绝重发"这一条判断；
那一篇的**两阶段写入顺序**仍然成立）

## Problem

第 14 轮我把"键停在 `pending`"（上一次执行结果未知）处理成 **fail-closed：拒绝重发 + 让手机刷新**，
理由是"我们没有任何痕迹能区分它有没有生效"。

本轮准备实现启动核对时，先把契约 §5.6 那句话的后半段读完：

> 核对不出结论的键**按未生效处理并重发**——重发是安全的，DSH …

后半句被截断了，所以我去读源码求证"重发到底安不安全"。答案是**安全**，而且机制很具体。

## 求证到的事实

`sessionController.prompt` 的幂等判据是 `hasPromptRequest(agent, requestId)`
（`packages/api/session-controller/src/commands.ts:334` 调用、`:602-614` 定义）：

```ts
function hasPromptRequest(agent, requestId) {
  const matches = (message) => {
    const source = message.source
    return source.kind === 'user' && 'rpcId' in source && source.rpcId === requestId
  }
  if (agent.inbox.nextTurn.some(matches) || agent.inbox.nextStep.some(matches)) return true
  // 既有会话历史读取
  return agent.session.snapshotEvents().some((event) =>
    event.type === 'user/message' && /* source.rpcId === requestId */)
}
```

关键在第二条：它扫的是 **`agent.session.snapshotEvents()`——会话事件日志**，不只是内存里的在飞队列。
而 `prompt` 在此之前会 `await this.resolveAgent(request.sessionId)`，会话被加载/重放之后，
上一次那条 `user/message` 的 `rpcId` 就在其中。于是**重发同一个 `requestId` 会得到
`{ accepted: true }`，不产生第二条消息** —— 连"桥接与 DSH 都重启"这种最坏情形也覆盖了。

## Decision

- **`pending` + 本进程没有在飞 → 照常执行（重发）**，不再拒绝。日志里注明"按未生效重发"。
- 契约里那个"向 DSH 核对"因此是**省一次重发的优化**，不是安全前提：重发本身由下游判据兜住。
  它仍然值得做（少一次白跑、少一次模型入队），但不必为了它先冻住 `pending` 的语义。
- 第 14 轮的两阶段顺序（`pending` 先落盘 → 执行 → `done`）与"`pending` 落盘失败即拒绝执行"
  **保持不变**：那两条的理由（执行了却没痕迹 = 重发即重复）与下游无关，是我们自己的账。

准入门槛（可机械判定）：

1. 停在 `pending` 的键，重发**会执行**（`calls` 增加），且成功后行被补写成 `done`。
2. handler 抛异常仍留下 `pending`（那是"结果未知"的痕迹，不是失败标记）。
3. `pending` 落盘失败仍然**拒绝执行**（这条不受本轮影响）。

## Alternatives considered

1. 保持第 14 轮的 fail-closed（拒绝重发 + 提示刷新）
   - 最强的理由：不需要新事实就能论证"绝不产生第二条消息"；出错时偏保守总是安全的。
   - 为何被否：**代价是白付的**。拒绝重发让用户必须手动重发一次，而重发本来就被下游安全地去重 ——
     等于用一个不可见的失败换一个不需要的保护。而且它把 `pending` 变成了死路（要等 TTL 过期），
     与契约 §5.6 明写的"按未生效处理并重发"相反。
2. 先把"向 DSH 核对"做完再放开重发
   - 最强的理由：那样连"白跑一次"都省了，顺序上更"正确"。
   - 为何被否：核对需要先去重行里落 `sid`（落盘格式变更 + 迁移），是一条独立的路。
     而安全性不依赖它 —— 先放开重发（安全且简单），核对作为优化随后做。

## Consequences

- 收益：`pending` 不再是死路；崩溃窗口的恢复路径与契约一致；实现更简单（少一个错误分支）。
- 代价：极端情形下会白跑一次执行（下游去重返回 `accepted: true`，而我们的 `done` 记的是那次重发的结果）。
- **仍未做**：启动核对（优化；需要先定去重行要不要落 `sid`）与 `session.prompt` 本身。
