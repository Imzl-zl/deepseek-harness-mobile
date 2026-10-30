# Agent Note: 独占准入（`device/busy`）、占用位与控制面 `?id=`

Status: implemented

实现 `proposed/2026-10-29-one-phone-many-computers.md` 落地顺序第 4 步的**前半**（通道准入）。
前半三篇：`implemented/2026-10-30-endpoint-and-ui-state-host-scoping.md`（归属）、
`implemented/2026-10-30-pairing-slots.md`（凭据）、
`implemented/2026-10-30-dial-racing-and-buffer-trim.md`（通道）。
同一提交的 App 侧只用到了新的错误码；**切换状态机与 15 s 预算**在
`implemented/2026-10-30-device-switch-and-budgets.md`。

## Problem

前三步让"一台手机记住多台电脑"成立之后，**电脑侧仍然是谁来都服务**：

1. 连接器每 accept 一条就装配一套方法面（`transport/listener.ts`、`relay` 的每设备数据通道），
   `presence` 记多台 online/foreground。于是两台手机可以**同时**读写同一台电脑：
   审批落给谁不确定、"在 A 的会话里点批准实际批到 B"这类错投第一次成为可能。
2. 被拒时手机拿到的是**坏信号**：没有"被占用"这个码，只能落成 `not-paired`（→ 清凭据回配对页，
   一次误连就把配对删了）或超时（→ 无限退避重连，用户看转圈）。方案决策 6 明确要
   "拒绝并说明原因，不踢人"。
3. `connectorId` 与中转**令牌 id** 不一致时没有任何一处会报：二维码里的 `pcId` 与中转眼里的
   id 是两个值，症状是"路由把通知发给错的一台"，而两端日志都正常（决策 1 的遗留面）。
   连接器拨控制面时根本没带自己的 id（`transport/relay-link.ts` 只拼 `/ws/connector`）。

## Decision

### 1. 新错误码 `device/busy` + 新客户端动作 `busy-wait`

四处门禁**同批**（漏一处的后果不是"走 default"，是被降级成 `internal` → 用户对着
永远重试也不好的操作反复点）：

| 门禁 | 改动 |
|---|---|
| `connector/src/protocol/errors.ts` | `ERROR_TABLE` 加 `'device/busy': 'busy-wait'`；`ClientAction` 联合加 `'busy-wait'` |
| `app/lib/core/errors.dart` | `ErrorCode.deviceBusy` + `ClientAction.busyWait`（`error-table-parity.test.ts` 逐字比对） |
| `docs/subsystems/remote-channel.md` §3.1 | 表里加一行（"不踢人：不自动重连，显示占用者，给手动重试与切回上一台"） |
| `connector/tests/flow.test.ts` | 封闭 + 满射的条数 **35 → 36**；`tests/methods.test.ts` 方法数不变（52） |

动作刻意**不是** `backoff-retry`：那会让手机在后台一遍遍撞门，占用者一走就无声连上 ——
"连哪台、什么时候连"是用户的动作（决策 9：宿主没有"自动挑一台电脑"这回事）。
也**不是** `re-pair`：凭据是好的，清凭据会把另一台电脑的配对一起删掉。

### 2. 占用位就是 `presence.serving()`，不另立状态

`presence.devices()` 本来就只含"配对且未吊销、在线"的设备（`presence.ts` 的文件头约束 2），
所以占用位就是它的 `online` 那一条。新增的读取面只有一行语义：

```ts
serving(): DeviceState | undefined   // devices() 里 online 的那一条（独占下至多一条）
```

- **停用 / 删除自然不占位**：`revokedAt` 存在或行没了 ⇒ `pairedAtOf` 回 `undefined` ⇒
  `devices()` 不列它 ⇒ 占用位空。这就是"占坑 DoS"的判据（一台停用的旧手机在名册里留着，
  不能永久挡住新手机）。
- **幽灵占用靠 keepalive 半开收口**（`transport/keepalive.ts`），这里**不加定时器**。
- `devices()` 与 `serving()` 共用同一份 `snapshot()` —— "有效"的判据只有一处。

### 3. 准入点在握手 `acceptHello`，判据是"**别的** devId"

`protocol/handshake-driver.ts` 新增可选 `occupantOf(devId)`，位置在 `peerOf` 之后、
生成临时密钥与回 `hello-ack` **之前**：先确认"这台设备是谁"，再判"现在轮不轮得到它"，
被拒的对端不该拿到我们的临时公钥。

判据实现在 `src/exclusive.ts`（`createExclusiveAdmission`）：

- 返 `undefined` = 放行；
- 返**占用者的展示名** = 拒。

**同一 `devId` 必须放行**：换网重连靠中转对同一 `(connectorId, deviceId)` 的 `replaced`
语义（`relay/src/server.ts`），连接器再拦一道就会出现"换个 WiFi 连不上自己"（决策 10）。
`relay/src/core.ts` 的"旧设备连接必须先关闭"是**另一条**不变式，别混。

**配对通道不参与独占**（`device-connection.ts`）：新手机扫码时电脑可能正被别人用着，
而配对只写一行名册、不占用服务位。

### 4. 拒绝的关闭理由带占用者（契约 §4.1 先改）

手机在握手阶段没有方法面、没有 `res`，唯一可读的是关闭码与理由，所以"被谁占着"只能跟在这个
字符串里。形状定成 `协议码` 或 `协议码 说明`（`protocol/close-reason.ts`）：

- 码是**第一个空格之前的全部字节** —— 手机按它查封闭表（切坏了会归成 `internal`）；
- 总长 **≤ 120 字节**：WS 关闭理由硬上限 123（RFC 6455 §5.5），超了 `ws` 抛 `RangeError`，
  **整条关闭路径失效**（连接反而留在那里）；截断按码点做，不切断多字节字符；
- 换行压成空格（关闭理由是一行）。

### 5. 控制面 `?id=`：自报身份，**必带**

- 连接器（`transport/relay-link.ts`）新增必填 `connectorId`，**只给控制面**拼 `?id=`；
  数据面 URL 不带（那条靠 `dev` + `channel` 认领）。
- 中转（`relay/src/server.ts` 的控制面分支）：**缺失与不一致都是 403**。
  **没有"老连接器"这回事**（协议未发版，见 `implemented/2026-10-30-drop-legacy-compat.md`）。

### 6. 面板："此刻在服务"一档 + 显式"接管"（走既有停用写路径）

- 管理面设备行多一格 `serving`（`admin/routes.ts` 的 `AdminDeviceRow`，装配层喂
  `presence.serving()?.id`）。
- `connector/client.js`：那一行状态词追加 `· 在服务`，动作区多一个「接管」按钮。
  「接管」= **停用占用者**（`POST /devices/enabled {enabled:false}`）—— 不另立"踢人"接口，
  接管是操作者的显式动作（决策 6/9）。停用/删除会**立刻收掉那台设备的连接**（占用位
  释放与下线是同一件事），所以「接管」名副其实。

准入门槛（可机械判定，均已跑过）：

1. **独占可区分**（门槛 4 的电脑侧一半）：设备有效但已有别的设备在服务 ⇒ 一帧不发、
   `established` 为 0、失败原因是 `device/busy` 且杀在 `peerOf` 之后
   （`tests/handshake-driver.test.ts`「已被别的设备占用」、`tests/exclusive.test.ts`）。
2. **同一设备重连放行 / 另一台被拒**（门槛 8c 的连接器一半）：`exclusive.test.ts`
   的「同一台设备换网重连」与「别的有效设备在服务：拒绝并给出占用者的名字」
   （后者同时断言占用者本人仍可重连）。
3. **停用 / 删除不占位**（门槛 8e）：`presence.test.ts` 的「占用位」与
   `exclusive.test.ts` 的「已停用 / 已删除的行不占位」。
4. **切走即释放**（门槛 5 的判据面）：`presence.offline` 之后 `serving()` 立刻为空
   （`presence.test.ts`）—— 关闭是同步的，下一次心跳之前就空。
5. **关闭理由形状**：`device/busy 我的手机`、换行压平、≤120 字节、码完整
   （`exclusive.test.ts`）。
6. **`?id=`**：一致放行、不一致 403、**不带也 403**（`relay/tests/server.test.ts`）。
6b. **中转转发关闭码**：电脑侧 4003 + `device/busy …` 原样到手机
   （`relay/tests/server.test.ts`「数据面的关闭码要转给另一端」）。
6c. **停用/删除即下线**：停用、显式删除、按状态批量（只对真删掉的）各自触发 `disconnect`
   （`tests/device-admin.test.ts`）。
6d. **换网重连不丢服务位**：旧连接迟到的 `offline` 不删新连接记录（`tests/presence.test.ts`）。
7. **面板**：只有那一行带「在服务」与「接管」，对话框后果句逐字
   （`tests/client-panel.test.ts`）。

变异校验（一次性，条数写进提交）：
- `exclusive.ts` 去掉"同一 devId 放行"→ 恰 2 红（换网重连那条 + 占用者本人仍可重连那条）；
- `close-reason.ts` 不截断 → 恰 1 红（关闭理由形状那条）；
- 中转不转发关闭码 → 恰 1 红（4003 那条）；
- `presence.offline` 忽略令牌 → 恰 1 红（换网重连不丢服务位）；
- `device-admin` 不调 `disconnect` → 恰 1 红（停用/删除即下线）；
- `exclusive` 只看 `serving()` 第一条 → 恰 3 红（别的设备在服务 / 两台同时在线 / 名字短码）。

## Alternatives considered

1. **`device/busy` 复用 `backoff-retry`（不新增客户端动作）**
   - 最强的理由：错误码表只加一个码，不用动 `ClientAction` 枚举与两侧的集合比对。
   - 为何被否：退避重连会在占用者离开的那一刻**无声连上**，而"什么时候切过来"是用户的动作；
     而且用户看到的是"重连中…"而不是"被谁占着"。
2. **独占判据放连接层（`transport/connection.ts` 的 `serving` 判定）**
   - 最强的理由：那里已经有连接状态，不必给握手驱动加选项。
   - 为何被否：握手成功才进 `serving`，到那时密钥已派生、`hello-ack` 已发出 ——
     对端要等一次完整的握手才知道自己被拒，而我们的临时公钥已经给了它。
3. **占用位另立一份 `Map<devId, since>`（或加一个 `seat` 字段）**
   - 最强的理由：读写都在一处，"谁占着、从什么时候起"查询最直接。
   - 为何被否：那就是第二份与 `presence` 会漂移的状态；停用过滤、断开作废、
     幽灵收口三条现在只需要在一处成立。
4. **把占用者名字放进 `res` 错误（方法面）**
   - 最强的理由：复用既有的错误载荷，关闭理由保持纯码。
   - 为何被否：被拒时还没有方法面（握手没完成），发不出 `res`。
5. **规则改成"新连接赢，踢掉占用者"**
   - 最强的理由：用户永远不会被幽灵连接卡住。
   - 为何被否：正在另一台手机上操作的人会被无声踢下线（症状是"手机自己断了"）。
     幽灵连接用半开检测 + 面板显式接管（方案 Alternatives 5 已否过一次）。
6. **`?id=` 不一致时报 401（与坏令牌同码）**
   - 最强的理由：不新增状态码，中转侧只有 401/403 两种升级失败。
   - 为何被否：401 的语义是"令牌不认识"，而这里是令牌认识、自报的身份不对 ——
     两者排查方向相反（换令牌 vs 改 `connectorId`）。

## Consequences

- 收益：电脑侧第一次真的只服务一台设备；被拒的手机拿到**可区分的原因**（不是清凭据、不是转圈）。
- 收益：`connectorId` 与令牌 id 第一次有机械核对；二维码里的身份与中转眼里的身份不再能静默漂移。
- 收益：面板第一次分得清"有台设备在线"与"就是它占着这台电脑"，并给了操作者一条显式的路。
- 代价：`ERROR_TABLE` / `ErrorCode` / 契约表 / 封闭+满射四处同时动（36 个码）；
  新增一个客户端动作意味着将来每条 `switch` 都要认它（目前只有 `ConnectionRecovery`）。
- 代价：关闭理由从"纯码"变成"码 + 最多 120 字节说明"，手机侧要按第一个空格切；
  老版本 App 把带说明的理由整串当码 → 归成 `internal` → 按 `log-and-retry` 重试（不会崩，但会退避重连）。
- 代价：**停用/删除会立刻断掉那台设备的连接**（静态审查后补的，见 §7）——
  "接管"因此名副其实，但也意味着"停用一台在线设备"是一次真实的掉线（它下次回来要重新配对）。
- 未覆盖：两台设备**同时**开始握手（都在 `hello` 与 `established` 之间）时两条都会通过准入，
  窗口是一个 RTT。闭掉它需要给占用位一个"握手在途"的维度，而那正是本步刻意不加的第二份状态。
  静态审查补强了**事后**那一半：两台都在线时，第三台必拒、在位者自己仍放行（`exclusive.ts`）。

### 7. 静态审查（没有第二台真机，逐跳核对 ①→⑧）

第二台设备这条链在真机上验不了（只有一台手机），于是按"一台真机 + 代码逐跳"核对：
手机 B 出票 → 中转开通道 → 连接器拨数据面 → 握手 `hello` → `peerOf` → `occupantOf` 拒绝
→ 连接层 `socket.close(4003, reason)` → **中转转发** → 手机 B 映射 `busy-wait` → 界面。

这一跳一跳读下来抓到**两个真漏洞**（都已修 + 用例）：

1. **中转吞关闭码**：`relay/src/server.ts` 的 `observeData` 在数据面关闭时调
   `closeLink(channelId)`，用的是默认 `4000 channel closed` —— 电脑侧的 `4003 device/busy …`
   根本到不了手机。手机只会退避重连（撞门），门槛 4 在**中转路径**（多机的主要路径）上失效。
   修复：`close` 事件把关闭码/理由转发给另一端（只转 3000–4999，理由按 120 字节截断）。
   用例：`relay/tests/server.test.ts`「数据面的关闭码要转给另一端」。
2. **停用不占位 vs 连接还活着**：占用位是"在线且未吊销"，而停用只标 `revokedAt` ——
   那条 socket 还在收发，占用位却已释放，下一台手机被放进来（两台同时在服务）。
   修复：`device-admin.ts` 在停用/删除成功后调 `disconnect`，装配层按 `devId → Connection`
   收连接（映射在握手成功时登记）。用例：`tests/device-admin.test.ts`。

另外两处竞态也一并收口（不是"设计变了"，是把不变量的判据写严）：

3. **旧连接迟到的 `offline` 抹掉新连接的服务位**：同一设备换网重连时新旧两条连接重叠，
   旧连接关闭若晚于新连接握手完成，`presence.offline(devId)` 会把**新连接**的记录删掉。
   修复：`online/offline` 带**每连接令牌**（`holder`），令牌不同就不删。
4. **准入只看 `serving()` 第一条**：两台同时在线时（竞速漏网）会放过第三台。
   修复：在位者（`serving().id == devId`）放行，其余只要**有任何别的在线有效设备**就拒。

5. **行在握手中被停用/删除**：`peerOf` 是 `hello` 那一刻判的，吊销可能落在
   `hello` 之后、`established` 之前 —— 那时 `disconnect` 找不到连接（还没登记），
   而 established 之后它会带着一条"已吊销"的连接继续服务。修复：装配层的
   `onDeviceEstablished` 再判一次（行不存在或已吊销 → `stop()`）。
   这一行在**装配层**，没有单测缝（要同时按住"吊销"与"握手中"两件事），如实记在此。

结论：`device/busy` 这条链在**代码层面**已经完整（含中转转发）；剩下真正没跑的只有
"第二台物理设备 + 切回上一台"的端到端手感，记在 memory 的下一步里。
- 未覆盖：面板的「接管」只有 zh/en 文案与对话框断言，没有真机截图门槛（真机验收见同批后半篇）。

### 8. 时序推演（可执行，不是嘴上推演）

`connector/tests/exclusive-scenarios.test.ts`：用**真** `presence` + `exclusive`
+ `device-admin`（不碰 socket），把两台设备的交错按顺序跑一遍，5 条场景：

| 场景 | 断言 |
|---|---|
| A 在服务 → B 来 | B 被拒且理由里是 A；A 的记录/在线态一点没动；A 自己重连仍放行 |
| A 换网重连（新旧重叠） | 新连接建得起来；**旧连接晚到的断开**不抹掉新连接的座位；新连接自己断了才空 |
| A 切走（主动 close） | 释放是同步的：B **立刻**能进（不必等心跳） |
| 停用/删除占用者 | `disconnect` 真的把连接收掉、占用位随之空、B 才能进；删行同理 |
| 两台同时握手（已知窗口） | **钉住现状**：两条都会进；事后第三台必拒、在位者自己放行 |

这一组的意义是"顺序一换会不会漏"：独占的 bug 几乎都不是判据写错，而是交错顺序变了
（旧连接迟到的断开、吊销与握手的先后、同时进门那一瞬）。第 2 条正是这样抓到并修掉的。

**静态审查证明不了的两件事**（如实记，不当成已验）：

- **两台同时开始握手**（都在 `hello` 与 `established` 之间）：两条都会通过准入，
  窗口是一个 RTT。事后那一半已收紧（两台都在线时第三台必拒、在位者自己放行），
  但"同时进门"这一瞬要一个"握手在途占位"维度才能闭掉 —— 而那正是本步刻意不立的
  第二份状态。门槛 8c 的用例覆盖的是"同一 devId"，不覆盖这一条。
- **"删除"与"名册未同步"在中转侧不可区分**（停用**没有**这个问题，别混）：
  - 停用：行留着、带 `revokedAt` → 401 body `device-revoked` → 手机侧
    `ErrorCode.revoked`（`pairing_client.dart:134-139`）→ `clientAction == rePair`
    → 终态、清这一台的凭据回配对页。**注意：这条链今天之前是断的** ——
    手机与中转两半都在（`implemented/2026-10-24-terminal-identity-from-pc.md`），
    但连接器上报名册时把停用行过滤掉了（`publishDevices`），中转解析名册时又把
    `revokedAt` 丢掉（`parseRegistrations`），于是 `device-revoked` 没有任何生产者，
    停用在手机侧与"名册还没同步"同一个症状。同批补上了这两处
    （`rosterEntry` 带 `revokedAt` + 解析保留它），用例见 `device-publish.test.ts`
    与 `http-face.test.ts`「名册走 HTTP 带上 revokedAt」。
  - 删除：行被名册差集删掉（`device-registry.ts` 纪律 4），令牌哈希查不到 →
    401 body `device-unknown` → 手机按 `relayOffline` 退避重试（**这是刻意的**：
    `device-unknown` 也覆盖"电脑刚启动、名册还没重放"，那种情况重试就能好）。
    中转只持有令牌哈希，**无法把这枚令牌归属到某台电脑**，所以它分不出"被删了"
    与"名册还没到"；多连接器部署时更不可能猜。手机因此会一直重试到名册再次
    出现（解禁/重配）为止 —— 这是中转投影的固有限制，不是映射写漏。
    真要区分得让名册带**墓碑**（删除过的哈希），那是契约改动，另一批做。
