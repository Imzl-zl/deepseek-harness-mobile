# Agent Note: 终态只有一个来源 —— 电脑侧明说"我不认你"（换票 401 不是）

Status: implemented

## Problem

"手机还配着对、只是暂时连不上"与"这台手机被电脑停用了"走同一条动作：清凭据 + 回配对页。
于是电脑那边只要停一会儿（中转重启），手机就把配对扔了 —— 用户必须重新扫码。

两处代码，同一个根：

1. **换票 401 被读成终态**：`app/lib/core/pairing_client.dart` 的 `_ticket` 把 `401 || 409`
   映射成 `ErrorCode.notPaired`（动作 `rePair`）。可中转在那个 401 里能说的只有
   "我的名册里没有这个摘要" —— 而**名册是电脑侧在每次连上中转时重放上去的**
   （`connector/src/device-publish.ts:10`、`connector/src/index.ts:925` 的
   `onConnected: publishDevices`）：中转重启后它为空，电脑重连即补。
2. **电脑明说"不认你"时反而在退避**：电脑侧握手层拒绝一台设备时抛出
   `protocol/not-paired`（`connector/src/protocol/handshake-driver.ts:164`），
   连接层以**关闭码 4003 + 该协议码**收场（`connector/src/transport/connection.ts:660`，
   理由由 `:278` 的 `fail(error.code, error)` 带出）。而手机在 `TransportClosed` 那一支
   只记了码与理由，**没有据此判终态** —— 于是真正该清凭据的信号被当成普通掉线。

一句话：**我们把"我不知道"当成了"我不要你"，又把"我不要你"当成了"再试试"**。

## Decision（已落地）

**终态（`ClientAction.rePair`）只有一个来源：电脑侧在协议里明说。**

- **换票 401 / 409 的含义按"哪一跳"分**（`pairing_client.dart` 的 `_ticket(paired:)`）：
  - `paired: false`（首配、凭公开邀请）⇒ `notPaired`：邀请/登记不对，回配对页让电脑重新出码；
  - `paired: true`（已配对、凭设备令牌）⇒ `relayOffline`（`showOffline`）：**退避重试，不清凭据**。
- **关闭码 4003 + 身份类协议理由 ⇒ 终态**（`sync_client_impl.dart` 的 `TransportClosed` 分支）：
  用 `ErrorCode.fromWire(reason)` 解理由，`clientAction == rePair` 才判终态，并记下
  `_lastProtocolError`；其它 4003（`protocol/bad-frame` / `handshake-timeout` / `internal` / 无理由）
  照旧退避。新增常量 `kHandshakeRefusalCloseCode = 4003`（带出处注释）。
- **判据仍然只有一处**：两条入口（建连失败 / 关闭帧）都用同一个式子
  `exception.clientAction == ClientAction.rePair`，终态后的副作用仍由 `ConnectionRecovery`
  （清凭据 + 回配对页）执行，连接层不认识平台、不导航。

## 判据（0 个真机回合；真机 1–2 回合**待做**，见下）

- **flutter 1141 → 1144**：
  - `sync_client_test.dart` 新增两条：「4003 + `protocol/not-paired` → 终态（不重连、留声）」、
    「4003 但理由是坏帧 / 超时 / 无理由 → 照旧退避重连」（后者是**对照面**，防止把"任何 4003"
    都当终态 —— 那会让一次坏帧清掉用户凭据）；
  - `pairing_client_test.dart` 新增一条：「**已配对**设备的换票 401 → 离线态」。
  - 假传输的 `dropFromPeer` 增加 `reason` 参数（关闭理由本来就是协议码）。
- **变异校验两组**（做完即还原）：
  ① 把 `paired ? relayOffline : notPaired` 改回恒 `notPaired` ⇒ **恰好**那条新测试红
  （`Expected relayOffline / Actual notPaired`）；
  ② 关掉 `TransportClosed` 里的终态判定 ⇒ **恰好**「4003 + not-paired → 终态」那条红。
- **没有改协议、没有加码**：用的仍是封闭表里的 `protocol/not-paired` / `relay/offline`，
  两边码表未变（`connector/tests/error-table-parity.test.ts` 仍绿）。

## 还没做的：真机验证（1–2 回合）

按"要真机先报价"的纪律**没跑**，等用户点头：

1. 中转重启 → 手机**自动恢复**、配对不掉（看 `notPaired` 不再出现、连接回到 serving）；
2. 电脑上停用这台设备 → 手机**明说**"这台电脑已不再认可本机"，并回配对页（不再静默清凭据）。

## 代价与后果

- **用户可见行为变了**：电脑停用设备后，手机要等一次握手才知道（而不是换票就清凭据）；
  在纯中转链路上，"停用"要到下一次握手才生效 —— 这是**如实**的：中转本来就不区分原因。
- **中转重启后的恢复时间 = 电脑重连并重放名册的时间**（`device-publish.ts` 的设计就是
  "每次连上都重放一遍"），期间手机显示离线/重连中，**不再丢配对**。
- **契约同步**：`remote-channel.md` §11 故障矩阵那一行、`connector-and-relay.md` §2.4 吊销行、
  `cookbook/relay-on-a-server.md` §7 的"重启后要重新配对"一并改成新形态（后两者原来写的是旧行为）。

## 代码入口回指

`app/lib/core/pairing_client.dart`（`_ticket(paired:)`）、`app/lib/core/sync_client_impl.dart`
（`kHandshakeRefusalCloseCode` 与 `TransportClosed` 分支）。

Note: 来自总账 `.agents/notes/proposed/2026-10-24-native-rules-audit.md` 的 C1、C2
（根因分段 2："把连接态当语义态"）。本篇取代同目录的 proposed 版本（原名
`2026-10-24-terminal-identity-from-relay.md`）—— 落地方案从"让中转分开说"改成
"终态只认电脑的明说"，因为中转**根本不认识** revoked（名册是电脑推的）。
