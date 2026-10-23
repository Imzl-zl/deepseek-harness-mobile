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

## 判据（单测 + 变异校验）

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

## 真机验证（2026-10-24，2 个轮次；同一台仪器做 A/B）

**环境**：隔离实例 `$env:DSH_HOME='D:\tmp\dsh-e2e'` + `dsh --profile mobile-e2e --port 63900 --no-open`；
中转 `cd relay; node src/main.ts --config D:\tmp\dsh-e2e\relay.config.json`（8787/`0.0.0.0`）；
装包 `flutter build apk --debug` + `adb install -r`（`firstInstallTime` 仍是 10-19 18:57 = **没卸载**）。
证据目录 `D:\tmp\dsh-e2e\shots-2026-10-24-verify\`。

**仪器**：`D:\tmp\dsh-e2e\stub-401.mjs`（占 `0.0.0.0:8787`，对任何请求回
401 + `{"error":"unauthorized"}`，形状照 `relay/src/http-face.ts:77`）。
用它而不是"真中转重启"：连接器重连后**立刻**重放名册，换票 401 的窗口只有几百毫秒，抓不住。

### ① 换票 401 不再清凭据（A/B）

| | 旧包（10-23 10:58，本篇之前） | 新包（10-24 02:27 构建） |
|---|---|---|
| 手机表现 | **回配对页** +「这台电脑已不再认可本机（可能已停用，或凭据已失效）。请重新扫码配对。」 | **停在会话页**，顶栏空心重连点，无配对页 |
| 凭据 | 被清（`FlutterSecureStorage.xml` → 65 B，mtime 02:24:27） | 保留（重开 App 直接进会话页） |
| 截图 | `15-ticket-rejected.png` | `w3a7-new-build-401.png`、`w3a8-relaunch-still-paired.png` |

新包一侧的替身日志原文（4 条换票，退避 1.7 / 4.8 / 8 s）：

```
[stub401] 2026-10-23T18:41:19.674Z POST /ws-ticket ua=Dart/3.11 (dart:io)
[stub401] 2026-10-23T18:41:21.438Z POST /ws-ticket ua=Dart/3.11 (dart:io)
[stub401] 2026-10-23T18:41:26.241Z POST /ws-ticket ua=Dart/3.11 (dart:io)
[stub401] 2026-10-23T18:41:34.319Z POST /ws-ticket ua=Dart/3.11 (dart:io)
```

换回真中转后恢复：`devices[].online` 02:42:12/16/19 = false → **02:42:22 = true**（12 s，无任何点击）；
抽屉显示「中转已连接 · 空闲」且会话列表/计数全部重载（`w3a-4b-drawer-sessions.png`）。

**判据缺口（如实记）**：**App 不打 logcat** —— `adb logcat -d` 里 `flutter` 标签 **0 行**，
`not-paired` / `relay/offline` / `notPaired` 全部零命中（`w3a-logcat-full.txt` 3968 行）。
所以"401 被读成 `relay/offline` 而不是 `not-paired`"**没有日志原文可贴**，
只有行为面（不回配对页 + 凭据未清 + 退避重试）与替身侧的 401 计数。第八条教训的同一形状：
**判据要能区分"没命中"与"没实现"** —— 这里是"没打日志"，不是"没发生"。

### ② 停用这台设备：两条链路两种结果

`POST /api/dsh-mobile/devices/enabled {"devId":"AsZSTs4sKCUzOWan87HkyQ","enabled":false}`
（`devId` 取自 `GET /api/dsh-mobile/status` 的 `devices[]`）。

- **纯中转链路**（`POST /transport/direct/stop` 关掉直连监听面，只剩中转 + `adb reverse`）：
  - 停用后手机**先是仍显示「已连接」**（既有连接没被踢掉）；杀中转才变「连接中…」（`w3b-4-relay-killed-while-revoked.png`）。
  - 中转恢复后 35 s 仍是「重连中…」，**不回配对页、不出现"不再认可本机"**
    （`w3b-5-revoked-relay-retry.png`，语义树 `ui-w3b-retry.xml` 只有 `连接状态：重连中…`，
    没有 `扫一扫` / `连接电脑` 这两个配对页元素）。
  - 原因：停用后名册里没有它 ⇒ 换票回 401 ⇒ 归 `relay/offline` 退避；中转这一跳就到不了握手层。
- **直连链路**（局域网 `192.168.2.29 → 192.168.2.47:8790`，`adb reverse` 与中转都撤掉）：
  - 停用状态下重开 App ⇒ **明说**「这台电脑已不再认可本机（可能已停用，或凭据已失效）。请重新扫码配对。」
    + 回配对页（`w3b-7-direct-relaunch-revoked.png`，`ui-w3b-direct-relaunch.xml` 同文案）。
  - 即关闭码 4003 + `protocol/not-paired` 这条终态路**实测成立**。
- **恢复**：中转链路下 `enabled:true` 后在 02:56:54 **没重新扫码**就连上（online=true）；
  直连链路验完凭据已被清（终态即清凭据），要回到可用状态得重新扫码 —— 这一步不是回归，是设计。

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
