# Agent Note: 交互走 gateway 的 client 通道 —— 手机是附加 client，不是 host answerer

Status: proposed

## Problem

现状（`ff4c551` / `a32aac7` 之后）的交互链路是：连接器在 **host 的 waterfall** 里 `prepend` 一个
answerer，claim 之后由它等手机回答。这条路的三个后果都不是产品要的：

1. **claim 之后桌面看不到**（契约 §6.2 原话"手机接管期间审批不在电脑上出现"）。桌面那一路是
   `api/remotes` 的转发应答者（`api/remotes/src/index.ts:137-159`），我们在它前面，它根本收不到。
2. **手机先答，桌面卡关不掉**：桌面卡的寿命是它自己那条 invocation；唯一的"别处已答"信号是
   gateway 的 `cancel`（`api/gateway/src/index.ts:738-744`），而它只在**这条 pending event 被某个
   client 结算**时发。我们不是 client，手机答了没人结算它。
3. 于是"桌面先答手机能撤、手机先答桌面撤不了"—— 不是关闭逻辑不对称，是**手机没走 DSH 的
   client 通道**。

DSH 自己的多客户端模型恰恰是"所有 client 都收到、谁先答谁赢、其余收 `cancel` 撤卡"：
`api/gateway/src/index.ts:571`（新 client 注册时重投）、`:676-677`（新事件投给所有 client）、
`:696-698`（重复/迟到结果是 no-op）、`:717-721`（断线只撤投递）、`:738-744`（结算时给其余 client 发
`cancel`）。手机要的就是这个模型。

## Decision

**连接器不再做 host answerer；它作为 gateway 的一个 owner client 接入 `$events` 转发流**，
与浏览器标签页同一条路。手机仍然是我们的通道，但它的答案以**该 eventId 的 result** 回给 gateway：

- 桌面弹卡（原生，不变）；手机也弹（我们的卡）；
- **手机先答** → 连接器回 `{kind:'result', value}` → gateway 结算 → 给桌面 client 发 `cancel` → 桌面卡关；
- **桌面先答** → gateway 给连接器发 `cancel` → 连接器撤手机 claim → 手机卡由 `approval/decided` /
  `tool/result` 事件关；
- 两边由**同一个触发**关闭。

### 可行性证据（本地源码，0 猜测）

- host 侧可以建 **in-process owner peer**：`client/connection/src/rpc-host.ts:94`（`browserPeer` 就是
  `{principal:{kind:'owner'}}`）、`:140` 的 `createPeer({principal})`。
- 打开 `$events` 流：`ctx.typertGateway.wireStream.open('$events', { args: {} }, uplink, peer, signal)`
  （`api/gateway/src/types.ts:92-98,148-156`）。DSH 自己的测试就这么用：
  `api/gateway/tests/gateway-stream.host.spec.ts:373,379`、`gateway-access.host.spec.ts:697-703`。
- 帧形状（`api/gateway/src/stream-protocol.ts`）：
  - `ready {clientId, host}`（`:34-39`）、`emit`（`:45-49`）、
  - `waterfall {event, eventId, agentId, request}`（`:52-58`）、`cancel {eventId}`（`:61-64`）。
- 回结果：`POST /api/$events/result`，body
  `{type:'client-request', rpcId, method:'$events/result', payload:{args:{clientId, eventId, outcome}}}`
  （`:12-13`；DSH 测试的完整形状见 `gateway-access.host.spec.ts:587-602`）。in-process 走
  `ctx.connection.createSharedFetchHandler('/api').fetch(request, peer)`（`rpc-host.ts:207-215`，
  `http-bridge.ts:97` 的调用点带 `peer`）。
- `outcome`：`{kind:'result', value}` / `{kind:'next'}` / `{kind:'rejected', error}`（`types.ts:56-58`）。
- 客户端收到 `cancel` 会 abort 自己的 invocation（`api/gateway/src/client/remote-events.ts:148-149`）——
  桌面卡就是这么被撤的。

### 迁移顺序（一件一提交）

1. **新 `connector/src/dsh/interaction-client.ts`**：owner peer + `$events` 循环 + 结果 POST。
   - `ready` 存 `clientId`；`waterfall` 按 `event` 分派到现有端口（`askApproval` / `askQuestion`）；
     `cancel` 撤对应手机 claim；`emit` 忽略。
   - 流断开 → 退避重连（gateway 会把在途事件重投给新 client，`:571`）。
2. **删 host answerer**：`registerInteractions`（`dsh/interactions.ts`）与 `prepend` 的那套理由一起删；
   仲裁（`decideTakeover`）改为"**手机参不参与**"：不参与就**不回应**这条 event（桌面照常答），
   参与就等手机。
3. **`interaction-claims.ts`**：保留端口（手机侧在途 + 看护 + `interaction.respond` 的落点），
   加 `cancelClaim(callId)`（gateway `cancel` 用）；结局从"返回 waterfall"改为"交给 result 发送方"。
4. **能力位**：缺 `typertGateway` / `connection` 时**不做手机交互**（不转发、不 claim），
   不再保留第二套 host-answerer 路径 —— 净删代码。
5. **契约 §6.2 重写**：从"claim-or-delegate / 手机接管"改成"**手机是附加 client**（fan-out）"；
   三档仲裁的含义改成"手机参不参与"。

### 待定的一个小策略（实施时定，写进笔记）

手机超时 / 失败时回什么？

- **`{kind:'next'}`**：fail-closed，但会把桌面正在显示的卡一起撤掉（gateway 结算 → cancel 给所有 client）。
- **不回（hold）**：桌面可以继续答；没人答就一直等（这是 DSH 原生行为：没有 client 答就挂着）。
  代价是"手机唯一在场且失败"时回合会挂到用户取消。

推荐 **hold**（原生语义），把"10 分钟看护"从"抛错"改成"放弃等待、不回应"，并记录一条未处理。

## Alternatives considered

1. **host answerer 扇出（`next()` + `Promise.any`）**
   - 最强的理由：改动小，桌面也能弹。
   - 为何被否：桌面先答时能撤手机 claim，但手机先答时**桌面那条 invocation 没人结算** → 幽灵卡。
     这正是本轮要消灭的不对称；`Promise.any` 只是把问题藏起来。
2. **给 DSH 桌面 UI 补监听**（`ui-approval` / `ui-user-questions` 收 `approval/decided` / `tool/result` 就关卡）
   - 最强的理由：改动最小（几行），最直接。
   - 为何被否：那是 DSH 的代码（上游），升级会被覆盖；而且它只解决"撤卡"，不解决"桌面收不到请求"。
3. **维持独占 claim（现状）**
   - 最强的理由：简单、无幽灵卡。
   - 为何被否：桌面在手机接管时看不到 —— 产品上不接受。
4. **保留 host answerer，另写一个桌面客户端插件代理应答**
   - 最强的理由：不动 DSH。
   - 为何被否：客户端侧的 listener 是 **waterfall**（`api/gateway/src/client/remote-events.ts:241-246`），
     第二个 listener 拿不到已被 `ui-approval` claim 的请求；同 tab 内无法代理。
5. **不做（只记录，不改）**
   - 为何被否：桌面与手机的行为不对称是用户明确指出的产品问题。

## Consequences

- 收益：桌面**原生卡**照常弹、照常关；手机只是多一个输入；两边由同一个 gateway 触发关闭。
- 收益：删掉 `prepend` / 独占 claim / 离线不对称 / 幽灵卡这一整套；仲裁只剩"参不参与"。
- 收益：重投（`pendingAsks`）仍然有用（手机重开时把在途 ask 再发一遍），不受影响。
- 代价：交互传输层重写（新 client 循环 + 结果 POST），要接 `typertGateway` / `connection` 两个服务；
  缺服务时手机没有交互面（不再有 fallback claim）。
- 代价：in-process client 是**新增的信任面**（owner peer 在进程内），要写清它为什么安全
  （与插件本身同权限；不新增网络入口）。
- 代价：流断开重连、结果 POST 失败重试、`cancel` 与手机 claim 的竞态，都要有测试。
- 判据（草案）：假 gateway 流（ready/waterfall/cancel）+ 结果捕获：手机答 → 发 result；
  桌面 cancel → 撤 claim；仲裁不参与 → 不回应；缺服务 → 不挂交互面；重连 → 重开流并重投。
- 真机：桌面卡是否真的关，属于**桌面可见行为**，最后要一次真机/桌面确认（约 1 轮）。

代码入口回指（落地时补）：`connector/src/dsh/interaction-client.ts`、`interaction-claims.ts`、
契约 §6.2。
