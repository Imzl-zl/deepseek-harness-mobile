# Agent Note: 交互走 gateway 的 client 通道 —— 手机是附加 client，不是 host answerer

Status: implemented

## Problem

上一版的交互链路是：连接器在 **host 的 waterfall** 里 `prepend` 一个 answerer，claim 之后由它等手机回答
（`ff4c551` / `a32aac7`，笔记 `2026-10-23-in-flight-interaction-is-host-held.md`）。这条路的三个后果
都不是产品要的：

1. **claim 之后桌面看不到**（旧契约 §6.2 原话"手机接管期间审批不在电脑上出现"）。桌面那一路是
   `api/remotes` 的转发应答者（`api/remotes/src/index.ts:57-75`），我们在它前面，它根本收不到。
2. **手机先答，桌面卡关不掉**：桌面卡的寿命是它自己那条 invocation；唯一的"别处已答"信号是
   gateway 的 `cancel`（`api/gateway/src/index.ts:738-744`），而它只在**这条 pending event 被某个
   client 结算**时发。我们不是 client，手机答了没人结算它。
3. 于是"桌面先答手机能撤、手机先答桌面撤不了"—— 不是关闭逻辑不对称，是**手机没走 DSH 的
   client 通道**。

DSH 自己的多客户端模型恰恰是"所有 client 都收到、谁先答谁赢、其余收 `cancel` 撤卡"：
`api/gateway/src/index.ts:571`（新 client 注册时重投）、`:676-679`（新事件投给所有 client）、
`:696-699`（重复/迟到结果是 no-op）、`:717-721`（断线只撤投递）、`:734-745`（结算时给其余 client 发
`cancel`）。

## Decision

**连接器不再做 host answerer；它作为 gateway 的一个 owner client 接入 `$events` 转发流**，
与浏览器标签页同一条路。手机仍然是我们的通道，但它的答案以**该 eventId 的 result** 回给 gateway：

- 桌面弹卡（原生，不变）；手机也弹（我们的卡）；
- **手机先答** → 连接器回 `{kind:'result', value}` → gateway 结算 → 给桌面 client 发 `cancel` → 桌面卡关；
- **桌面先答** → gateway 给连接器发 `cancel` → 连接器撤手机 claim → 手机卡由 `approval/decided` /
  `tool/result` 事件关；
- 两边由**同一个触发**关闭。

### 落地形态

- 新 `connector/src/dsh/interaction-client.ts`：owner peer
  （`ctx.get('connection').createPeer({principal:{kind:'owner'}})`，
  `packages/client/connection/src/rpc-host.ts:140`；`interactions` 默认 `'answer'`，
  `packages/client/connection/src/peer.ts:40`）+ `$events` 循环
  （`packages/api/gateway/src/types.ts:92-109`）+ 结果 POST
  （`$events/result`，`createSharedFetchHandler('/api').fetch(request, peer)`，`rpc-host.ts:207-232`）。
- **没有"接管档位"**：手机连着就是 client，收到就参与。只有两种情况**委托**（`{kind:'next'}`）：
  ① 会话没登记给手机；② 没有稳定身份（审批没有 `callId` / 提问认不出唯一的 tool call）。
  委托是 DSH 的语义（`user-approval/src/types.ts:81-82`），也是网关的规则：**只有所有投递都
  `next` 之后**才交还 Host（`packages/api/gateway/tests/gateway-stream.host.spec.ts:1402`），
  所以一个 client 委托之后事件不结算、另一个 client 的卡照旧能答。
  **三档 `approvalTakeover`（never / foreground / always）被删掉**：它是"抢"时代的产物 ——
  抢到桌面就看不到，才需要"什么时候抢"。现在两边都收到、谁先答谁赢，没有"谁接管"这回事；
  不想让手机参与就停掉传输通道（手机连不上 = 没有投递）。
- **没有看护计时器**：DSH 的审批没有"等多久"这个概念（浏览器的卡一直挂到有人答或 `signal` 中止，
  `packages/client/ui-approval/src/client/index.ts:59-69`），所以连接器也不造超时、不记"未处理"。
  一条 claim 只有三种结局：手机答了、gateway 发 `cancel`（别人先答 / asker 取消）、本插件卸载。
  没人答就一直等 —— 与桌面那张卡完全同构。
- **删掉 host answerer**：`connector/src/dsh/interactions.ts` 整个文件、`interaction-face.ts` 的
  `registerApprovalAnswerer` 及其词汇（`ApprovalAsk` / `ApprovalAnswerer` / `ApprovalRegistry` /
  `ApprovalTakeoverSource` / `UnhandledApproval` / `ApprovalAnswererDeps`）。**不留第二套路径**。
- **缺 `typertGateway` / `connection` → 不做手机交互**（不转发、不 claim）：`createInteractionClient`
  回 `null` 并留一条 warn。这是"手机能不能答"这件事的**唯一**表达处。

## 实际落地时多做的决定（提案里没有）

1. **端口入参收窄成 `ClaimRequest { sid, callId, redeliver? }`**。提案说"复刻现有映射
   （toolName / reason / displayReason / questions）"，但那些字段在端口里**零使用** ——
   手机上的卡片内容全部来自会话事件（`approval/asked`、`ask_user_question` 的 `tool/call`）。
   把同一批字段再拷一份到内存里的请求上，就是让同一个事实有两个来源；同步它们的唯一办法是永远只用一处。
2. **`settleClaim` 与 `cancelClaim` 都"先摘表再收束"**。变异校验时抓到：只调
   `watchdog.cancel()` 而不摘表的版本里，`cancelClaim` 之后紧跟的 `settleClaim` 仍返回 `true`
   （认下一条已经不属于任何人的答复，手机拿到 `ok` 而答案被丢）。现在两者同一个顺序，
   判据在 `interaction-claims.test.ts`。
3. **删掉"自创边界"：看护计时器 / 未处理记录 / 离线兜底 / 沉默**。
   - `interaction-claims.ts` 现在**不接受任何依赖**（`createInteractionPort()`）：没有 `guardMs`、
     没有 `schedule`、没有 `presence`。签名本身就是"没有超时"这条约束。
   - `Watchdog` / `WatchdogEnd` / `DEFAULT_APPROVAL_GUARD_MS` / `UnhandledInteraction` /
     `METRIC.failClosed` 一并删除：它们是 host answerer 时代的产物（那时"没人答"必须变成
     `unavailable`，否则工具会挂死）。现在我们是 client，"没人答"就是**原生的一直等**。
   - 为什么这一条非改不可：`next()` 是 DSH 的委托语义，而"任何回话都会撤掉桌面那张卡"只在
     **我们是最后一个投递**时成立 —— 多客户端场景下委托是安全的
     （`gateway-stream.host.spec.ts:1402`）。把"沉默"当设计，等于自己发明了一套与宿主不一致的语义。
4. **删掉三档开关与仲裁判定**（`approvalTakeover` / `decideTakeover` / `fixture 16` /
   `protocol/reference/takeover.mjs` / `store` 里那张从没人写的 `takeover` 表 /
   `approvalWatchdogMin` 这个从没人读的配置项）。用户原话："两边都会弹，谁答不都一样，
   这两个有啥意义"——对，档位是为"抢"服务的；现在没有抢。**协议断言数因此从 486 掉到 454
   （fixture 16 那一份）**：两侧同时删、仍对等，`AGENTS.md` / `tools.md` / `memory.md` 三处同步。
   这条是**唯一一处违反"门禁只许升"的地方**，理由是契约规则本身被删了，不是漏测。
   顺带删掉的还有 `presence.devices()` 的消费方（它现在只喂管理面的列表），
   以及客户端里的 `TakeoverSource`（换成 `sidOf` 一个函数）。
5. **`unregisterPairingCommand` 的注销挪到 `start-transport` 的 undo**。它原先挂在
   `register-answerers` 的 undo 上 —— 一个从没被赋过值的变量 + 一个不拥有那次注册的步骤
   （注册发生在 `start-transport` 里）。挪完之后"谁注册谁注销"只剩一处。
6. **能力位（`repo.info` 的 `caps`）没改**。`caps` 表达的是"宿主有没有这个服务面"；"手机能不能答"
   由装配处表达。能加载本插件的 profile 必然带 web-app（`sessionController` 是必需服务），
   两个键总是同时在场 —— 折进 `caps` 只会让同一件事有两处说法。

## 证据

### 代码与门禁：0 个真机回合

- **连接器 618 → 611 条**（净 −7：**删掉的断言都跟着被删掉的行为走**，不是放宽）。
  新增 `connector/tests/interaction-client.test.ts` **26 条**：假 gateway（可控帧流 + 结果捕获）+
  **真端口**。五条验收判据各有对应用例：
  1. 手机答 → 发 `{kind:'result'}`，`value` 与 `interaction.respond` 的批次逐字一致（审批还断言
     `rpcId` / `method` / `clientId` / `eventId` / **回写用的是我们那个 peer**）；
  2. 桌面 `cancel` → 手机 claim 撤掉、不再重投、不回话；
  3. 不参与（会话没登记 / 没有 callId / 认不出题目身份）→ 回 **`{kind:'next'}`**；
  4. 缺 `typertGateway` / `connection` → 不挂交互面（不建 peer、不开流、不 claim）；
  5. 流断开 → 退避重连，重投的同一 `eventId` 仍能被处理（结果带**新** clientId）。
  另加：重投载荷（`approval/asked` / `tool/call` 的原 seq）、legacy 提问身份、计划审查不 warn、
  首帧不是 `ready` 就拆流、同一 eventId 不重复 claim、答完之后再投递要重新 claim、答完之后迟到的
  cancel 不追发、**换代窗口里不发明 outcome**、审批与提问并存、卸载撤在途 claim、结果没被接纳不重试。
- **删掉的断言（随行为一起删，都有出处）**：看护计时器 6 条（`timeout` / `guardMs` /
  `disconnect` / `replace` / 迟到丢弃 / 二次 `awaitAnswer`）+ 端口侧 5 条（看护超时、离线兜底 ×2、
  先到先赢里被撤的半边等）+ 三档仲裁 3 条（`never` / 没前台订阅 / 档位损坏）。
  它们断言的正是"自创边界"，边界删了，断言没有对象可断。
- **protocol 门禁 486 → 454**（fixture 16 那 32 条随后删除；15 条 fixture）。这条**破了"只许升"**，
  原因同上：契约规则本身被删。`AGENTS.md` 的"fixtures 断言数须 = N"跟着改成 454。
- **变异校验两组**（做完即还原）：
  ① 把 `cancelClaim` 变成空操作 → **6 条红，全部是"撤掉在途 claim"那几条**
  （client 的 cancel / 重连 / 卸载 + port 的 cancelClaim ×2、先到先赢），其余全绿；
  ② 把结果 POST 的 `eventId` 写死 → **3 条红，全部是断言 eventId 的结果路径**，其余全绿。
- **DSH 侧证据全是源码行号 + 它自己的用例**：gateway 的 `:571` / `:676-679` / `:696-699` /
  `:717-721` / `:734-745`；**fan-out 与"第一个 result 结算、另一个收 cancel"由 DSH 自己的测试盯着**
  （`packages/api/gateway/tests/gateway-stream.host.spec.ts:1320-1369`：同一条 `eventId` 投给两个
  client、第二个的结果结算了 pending、第一个收到 `{type:'cancel', eventId}`）—— 这条是本轮模型
  最硬的外部证据,不是我们复述自己的假设。浏览器的撤卡链路
  `api/gateway/src/client/remote-events.ts:148-149`（cancel → abort 投递信号）+
  `packages/client/ui-approval/src/client/index.ts:59-69`（`pending.result` 抛 → `finally { remove() }`）；
  owner peer 与结果面 `client/connection/src/rpc-host.ts:140,207-232`、`peer.ts:40`。
- **仍未证的那一件**：浏览器那张卡**从界面上真的消失**。机制三段都在源码里、DSH 的 fan-out 也有
  自己的用例，但"看得见的结果"要一次真机/桌面确认（约 1 个轮次）。它是本轮的尾巴，不是新设计。

### 真机 / 桌面确认（1 个轮次，2026-10-23 22:50 / 23:36 复验）

隔离实例（`DSH_HOME=D:\tmp\dsh-e2e` + `--profile mobile-e2e --port 63900 --no-open`，**不动用户当前那个
DSH**）装上本轮产物，桌面侧用 headless Chrome 里的**真 Web 客户端**（同一份 `ui-approval`），手机走
`adb reverse` 中转通道。同一轮里两边同时收到同一条审批：

- **两边都弹卡**（`D:\tmp\dsh-e2e\shots-2026-10-23-interaction-client\`：
  `final-desktop-card-before-phone-answer.png` / `final-phone-card-before-phone-answer.png`）——这条本身就是
  "桌面不再被手机挡住"的证据（旧形态下桌面根本收不到）。
- **手机点「允许一次」→ 桌面那张卡消失**（`final-desktop-after-phone-answer.png`；手机侧卡片同时收束）。
- **会话日志成对**：`approval/asked`（seq 82）→ `approval/decided`（seq 83，`outcome: "allowed-once"`）。
- **机械判据（谁答的）**：连接器管理面的 `lastInteractedAt = 1792769887625` 与
  `approval/decided.time = 1792769887626` **差 1 ms**；`presence.interacted` 只在
  `interaction.respond` 成功时写，所以这次决定**来自手机**，不是浏览器（浏览器那侧全程只被截图）。
- 反向也验过一次：桌面点「允许一次」→ 手机卡关（`phone-after-desktop-answer.png`）。这一条走的是
  会话事件（`approval/decided`），所以它证明的是"桌面先答也能让手机收束"；
  `cancelClaim` 的**撤销**作用在单测里（手机上迟到的答复不会被当成新决定）。
- 第一遍（22:50）用的是"带 10 分钟看护"的中间版本；23:36 在**按原生删掉计时器/沉默之后**的产物上
  复验了一次，结论相同。"不参与 → `next`"这条新路径只用单测覆盖，没过真机。

## Alternatives considered

1. **host answerer 扇出（`next()` + `Promise.any`）**
   - 最强的理由：改动小，桌面也能弹。
   - 为何被否：桌面先答时能撤手机 claim，但手机先答时**桌面那条 invocation 没人结算** → 幽灵卡。
     这正是本轮要消灭的不对称；`Promise.any` 只是把问题藏起来。
2. **给 DSH 桌面 UI 补监听**（`ui-approval` / `ui-user-questions` 收 `approval/decided` / `tool/result` 就关卡）
   - 最强的理由：改动最小（几行），最直接。
   - 为何被否：那是 DSH 的代码（上游），升级会被覆盖；而且它只解决"撤卡"，不解决"桌面收不到请求"。
3. **维持独占 claim（上一版）**
   - 最强的理由：简单、无幽灵卡。
   - 为何被否：桌面在手机接管时看不到 —— 产品上不接受。
4. **保留 host answerer，另写一个桌面客户端插件代理应答**
   - 最强的理由：不动 DSH。
   - 为何被否：客户端侧的 listener 是 **waterfall**（`api/gateway/src/client/remote-events.ts:241-246`），
     第二个 listener 拿不到已被 `ui-approval` claim 的请求；同 tab 内无法代理。
5. **不做（只记录，不改）**
   - 为何被否：桌面与手机的行为不对称是用户明确指出的产品问题。
6. **"不参与就沉默" + 10 分钟看护计时器（本轮先落地、随即撤掉）**
   - 最强的理由（当时的）：`next()` 似乎会把桌面那张卡一起撤掉，所以"沉默"看起来最安全；
     超时看起来是"不能无限挂"的必要兜底。
   - 为何被否：两条都是**自创边界**。① 委托是 DSH 的语义，且只有"所有投递都 `next`"才交还 Host
     （`gateway-stream.host.spec.ts:1402`）—— 多客户端下委托是安全的；② DSH 的审批**没有超时**
     （浏览器的卡一直挂着），我们加一个 10 分钟，等于改变宿主行为，还得自己发明"未处理记录"
     和 fail-closed 指标。用户当场点破："DSH 原生是啥样就啥样，不擅自加边界"。

## Consequences

- 收益：桌面**原生卡**照常弹、照常关；手机只是多一个输入；两边由同一个 gateway 触发关闭。
- 收益：`prepend` / 独占 claim / 离线不对称 / 幽灵卡这一整套被删掉；**"谁接管"这个概念连同三档开关与
  `decideTakeover` 一起消失**（契约 §6.2、fixture 16、`store` 的 `takeover` 表一并删）。
- 收益：重投（`pendingAsks`）原样保留 —— 手机重订阅时把在途 ask 事件按原 seq 再发一遍。
- 收益（去自创边界）：看护计时器 / 未处理记录 / fail-closed 指标 / 离线兜底全部删除 ——
  它们只是把 DSH 本来就会做的事（等、或由它自己兜 `unavailable`）在桥接里重写了一遍。
- **代价（原生的，不是我们加的）**：两边都没人答时回合会一直等，直到用户取消 ——
  与浏览器那张卡完全同构。写进契约 §15。
- **代价**：交互传输层是**别人的线形状**（`stream-protocol.ts`），所以逐帧校验；认不出的帧只留声
  （新增一种帧不该让我们把整条流拆掉），**已知帧但字段不全**才抛。
- **代价**：流会断（`api/remotes` 重新注册源 / peer 失效），所以要退避重连
  （1 s → 30 s，复用 `transport/backoff.ts`；第一次失败 `warn`，之后只 `debug`）。
- **代价**：新增一个 in-process 信任面（owner peer）：与插件本身同权限，不新增网络入口，
  卸载时 `peer.dispose()`。
- **被删掉的测试**：`interaction-answerer-order.test.ts`（"应答者必须 prepend"随 host answerer 一起消失）；
  `interactions.test.ts`（映射用例迁进 `interaction-client.test.ts`，断言强度不降）；
  看护计时器的 6 条与端口侧"超时/离线"5 条（**断言的行为按原生删除**，见上面的证据一节）。

## 契约与现状同步

- `docs/subsystems/remote-channel.md` §6.2 重写成"连接器是 gateway 的一个 client"
  （fan-out 表 + 没有档位 + 没有超时 + 装配前提），§6.2.1 改成"迟到应答"，
  §6.3.1 的 `open` 路径改指 `interaction-client.ts`；§8.1 删掉 `takeover` 表、
  §10 参数表删掉"审批看护超时 10 min"、§15 改成"两边都没人答就一直等"。
- `docs/subsystems/connector-and-relay.md` §1.3 生命周期图、§1.5（原 "审批接管(TakeoverGate)"）、
  配置表（删 `approvalTakeover` / `approvalWatchdogMin`）、"装配分层"那一行同步。
- `docs/design-and-tech-plan.md` 的"协议未覆盖的六条"去掉"审批仲裁"（现在没有这条规则了）。
- `docs/cookbook/channel-bootstrap.md` 的适配表、`next-session-interaction-to-phone.md` 的
  "呈示不了不许伪装成决定"一段同步；`app-channel-client.md` 的交互行同步。
- `.agents/notes/implemented/2026-10-13-answerer-must-be-prepended.md` 移入 `archived/`
  （结论不动，顶部标注被本篇取代）。

## 代码入口回指

`connector/src/dsh/interaction-client.ts`（投递与回话）、`connector/src/interaction-claims.ts`
（在途 claim 与结算单）、`connector/src/interaction-face.ts`（提问内核；**没有应答者、没有计时器**）、
`connector/src/index.ts` 的 `mount-interactions` 步。
