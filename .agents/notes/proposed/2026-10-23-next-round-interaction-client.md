# Agent Note: 下一轮提示词 —— 交互改成 gateway client

Status: proposed

## 提示词（整段复制）

```text
项目：dsh-mobile（D:\sudy\myproject\dsh-mobile，Windows / pwsh）。中文回复。

本轮只有一件：**把手机交互从 host answerer 改成 gateway 的 owner client**（一件一提交 + 一篇笔记）。
先判断能不能 0 个真机回合证明；要真机先报"约几个轮次"并拿到准。

## 0 先读（别跳）

- AGENTS.md（硬规则：改源码只用编辑工具；提交前看 git status；引 DSH 行号）
- memory.md 的「待办」第 12 条、「前置事实」、「真机联调的成本纪律」
- tools.md 的「Typert 两条铁律」与 Pitfalls（提交纪律、变异校验、headless 收工清理）
- `.agents/notes/proposed/2026-10-23-interaction-as-gateway-client.md`（提案，含全部行号）
- 契约 `docs/subsystems/remote-channel.md` §5.7 的 `interaction.respond` 行、§6.2、§6.3.1
- 现状代码：`connector/src/dsh/interactions.ts`、`connector/src/interaction-claims.ts`、
  `connector/src/session-subscriptions.ts` 的 `pendingOf`、`dsh/ask-event.ts`、`dsh/question-call.ts`

## 1 现状（省你半天）

上一轮已落地（`ff4c551` + `a32aac7`，**别重做**）：
- 在途 claim 挂在 host 上：**断线不结算**（删了两处 `presence.onOffline`），只有答复 / 取消 /
  会话被替换 / 看护超时收束；
- 手机重订阅时按原 seq **重投在途 ask 事件**（`session-subscriptions.ts` 的 `pendingOf` +
  `interaction-claims.ts` 的 `pendingAsks`），App 按 `itemId` upsert；
- App 失败分类：`interaction/not-pending` 撤卡，其余失败留卡可重试；失败不写成功回执。
- 门禁：connector **618** / flutter **1140** / boundary **360**。

**还没解决的（本轮要做的）**：连接器是 host 的 `prepend` answerer，claim 之后桌面收不到请求；
手机先答时桌面卡关不掉（桌面卡的关闭触发挂在它自己的 invocation 上，只有 gateway 的 `cancel`
能撤，而 `cancel` 只在 pending event 被某个 client 结算时发）。

## 2 本轮任务：连接器作为 owner client 接入 gateway 的 `$events` 流

### 2.1 能力与 API 事实（本地源码核实过，照抄）

- `ctx.get('connection')` 是 `HostConnectionService`（service 键 `connection`，
  `packages/client/connection/src/rpc-host.ts:92`）。
- `ctx.get('typertGateway')` 是 gateway（`packages/api/gateway/src/index.ts`）。
- 建 in-process owner peer：`connection.createPeer({ principal: { kind: 'owner' } })`
  （`rpc-host.ts:94,140`；`browserPeer` 也是 `{kind:'owner'}`）。
- 打开转发流：
  `gateway.wireStream.open('$events', { args: {} }, uplink, peer, signal)`
  （`api/gateway/src/types.ts:92-98,148-156`；DSH 测试用法：
  `api/gateway/tests/gateway-stream.host.spec.ts:373,379`、`gateway-access.host.spec.ts:697-703`）。
- 帧（`api/gateway/src/stream-protocol.ts`）：
  - `ready { clientId, host }`（`:34-39`）
  - `emit`（`:45-49`，忽略）
  - `waterfall { event, eventId, agentId, request }`（`:52-58`）
  - `cancel { eventId }`（`:61-64`）
- 回结果（`:12-13` 的 `$events/result`）：
  ~~~ts
  await connection.createSharedFetchHandler('/api').fetch(
    new Request('http://host/api/$events/result', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        type: 'client-request',
        rpcId: `result-${eventId}`,
        method: '$events/result',
        payload: { args: { clientId, eventId, outcome } },
      }),
    }),
    peer,
  )
  ~~~
  （`rpc-host.ts:207-215`；`http-bridge.ts:97` 的调用点带 `peer`；DSH 测试的完整 body：
  `gateway-access.host.spec.ts:587-602`）。`outcome` 是 `{kind:'result', value}` /
  `{kind:'next'}` / `{kind:'rejected', error}`（`types.ts:56-58`）。
- **wire 请求里没有 `agent` 对象**：用 `frame.agentId` 解析会话
  （`sidOf(frame.agentId)`），再用 `ctx.get('agents').get(agentId)` 拿 live agent 去读
  `session.snapshotEvents()`（legacy 提问的身份仍靠 `dsh/question-call.ts` 推）。
- 每个 `waterfall` 帧建一个 `AbortController`；收到同 `eventId` 的 `cancel` 就 abort。

### 2.2 迁移顺序

1. 新 `connector/src/dsh/interaction-client.ts`：owner peer + `$events` 循环 + 结果 POST。
   - `ready` 存 `clientId`；`waterfall` 按 `event`（`approval/request` / `user-questions/request`）
     复刻现有 `dsh/interactions.ts` 的映射（仲裁 → prompt → 端口）；
   - 手机答 → 发 `{kind:'result', value}`；`cancel` → `cancelClaim(callId)`；
   - 流断开 → 退避重连（gateway 会把在途事件重投给新 client，`api/gateway/src/index.ts:571`）。
2. 删 host answerer：`registerInteractions` 与 `prepend` 的理由一起删；仲裁改为"手机参不参与"：
   不参与就**不回应**这条 event（桌面照常答），参与就等手机。
3. `interaction-claims.ts`：保留端口，加 `cancelClaim(callId)`；结局从"返回 waterfall"改为
   "交给 result 发送方"。
4. 能力位：缺 `typertGateway` / `connection` 时**不做手机交互**（不转发、不 claim），不留 fallback。
5. 契约 §6.2 重写：从"claim-or-delegate / 手机接管"改成"手机是附加 client（fan-out）"。

### 2.3 待定策略（实施时定，写进笔记）

手机超时 / 失败时：
- 回 `{kind:'next'}`：fail-closed，但会把桌面正在显示的卡一起撤（gateway 结算 → cancel 给所有 client）。
- **不回（hold）**：桌面可以继续答；没人答就一直等（DSH 原生行为）。
推荐 **hold**，把 10 分钟看护从"抛错"改成"放弃等待、不回应"，并记录一条未处理。

## 3 硬规则

- 门禁只许升不许降：flutter 1140 / boundary 360 / connector 618 / relay 86 /
  protocol 486·26·49 / icons 100 / tool-paths 23 / CDP（proto 31 / settings 28 / authz 18 /
  tasks 53 / drawer 25 / picker / subs 41 / turns 60）。
- 改 `connector/src/**` 后必须 `pnpm exec tsc --noEmit && pnpm build && pnpm test`；
  改 `app/lib` 或 `app/packages` 后必须 `node app/tools/verify-platform-boundary.mjs`。
- 改源码只用编辑工具；提交前看 `git status` 完整清单；一个不变量只在一处表达。
- 真机回合先报价并拿到准；收工清理 headless。
- 不重开：timed 部署、计划审查卡、重投（`pendingAsks`）、App 失败分类 —— 都保留。
  独占 claim / `prepend` 是**本轮要删的**，别修补它。

## 4 判据

- connector 单测（假 gateway：`wireStream.open` 返回可控帧流 + 结果捕获）：
  1. 手机答 → 发 `{kind:'result'}`，value 与 `interaction.respond` 的批次一致；
  2. 桌面 `cancel` → 手机 claim 撤掉，且不再重投；
  3. 仲裁不参与 → **不回应**（不是发 `next`）；
  4. 缺 `typertGateway` / `connection` → 不挂交互面；
  5. 流断开重连 → 重开流、在途事件仍能被处理。
- 变异校验：把 `cancelClaim` 删掉 ⇒ 恰好"cancel 撤 claim"那条红；把结果 POST 的 `eventId`
  写死 ⇒ 恰好结果那条红。
- 0 个真机回合优先（全在连接器内，假 gateway 流就能证）；桌面卡是否真的关，最后要一次
  真机/桌面确认（**约 1 个轮次**），先报价。

## 5 收尾

- 笔记从 `proposed/` 移到 `implemented/`（同一篇，Status 改 implemented，写实际落地与代价）；
- 更新 `memory.md`（待办 12 收口、门禁数）与 `tools.md` 的项数；
- `git status` 必须只剩有意改动；一个提交。
```

## 说明（给用户，不用贴）

- 这轮的关键判断已经写好：**不是"关闭逻辑不对称"，是手机没走 DSH 的 client 通道**。
  提案里的行号都是本地源码核实过的，新会话不用重查。
- 唯一还需要拍板的是 2.3 的"超时回 `next` 还是 hold"；我在提案里推荐 hold（原生语义），
  新会话可以按这个直接做，不必再问。
- 真机成本：桌面卡是否真的关，属于桌面可见行为，最后约 1 个轮次确认。
