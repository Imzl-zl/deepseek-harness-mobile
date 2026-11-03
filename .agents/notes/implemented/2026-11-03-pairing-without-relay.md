# Agent Note: 配对不再强制经过中转（局域网也能出码 + 配对）

Status: implemented

## Problem

配对 v2 有两处硬绑定把「中转」写死成了前提：

1. `connector/src/pairing-offer.ts` 先 `register(offerId)` 到中转，失败就抛 ——
   关掉中转（或没有令牌）= **出不了码**；
2. 二维码载荷只有 `relay` 一个地址（`connector/src/pairing.ts` 的 `offer()`），
   手机拿到码之后唯一能做的事是去中转换票。

而中转在配对里实际只做两件事：**保管 offer** 与**转告连接器"有候选要连进来"**。
两件事在局域网里都不需要服务器 —— 连接器自己持有 offer（`pairing.ts` 的
`offer()` / `allows()`），自己也已经在 `0.0.0.0:8790` 上监听（0.1.14 起默认开）。
于是"同一张桌子上的手机"也必须先经过一台公网服务器才能配上对，中转一关就彻底配不了。

## Decision

1. **载荷加 `lan`**：`pairing.ts` 的 `offer()` 增一格 `lan: ["ws://192.168.x.x:8790", …]`，
   地址由装配层用 `describeEndpoints()` 的 direct 那组算（**不另写一套**：二维码里的地址
   与 `endpoint.describe` 报给手机的必须是同一个集合）。空就不写这一格，老载荷形状照旧。
2. **监听面认出配对连接**：`transport/listener.ts` 的 `accept()` 收 `UpgradeRequest`（只有 URL），
   `index.ts` 用 `pairing-lan.ts` 的 `readPairingRequest()` 判 `?pair=<offerId>&cand=<候选>`，
   命中就 `makeConnection({ purpose:'pairing', candidate })`；放不放行仍只由
   `pairing.allows(candidate)` 判（`device-connection.ts` 的 `peerOf`）。
3. **出码不再强制登记**：先照旧试着登记；失败时**有 `lan` 就降级出码**（warn 留声），
   没有就照旧抛（"只有中转"的场景下，一张扫了也配不上的码比不出码更坏）。
   中转可用时仍然登记 —— 同一张码在跨网场景照样能用。
4. **手机端先拨局域网**：`beginPairing()` 按 `dialOrder()`（同网段优先）顺序拨 `lan`，
   第一条通了就直接跑现有的握手/提交帧（**帧本身一个字节没改**）；全拨不通才回落换票。
   配对成功后把 `lan` 种成 `direct` 端点（`main.dart` 的 `_onPaired`），否则关掉中转后
   第一次连会"没有端点可拨"。
5. **名册上报失败不再算配对失败**（`pairing-endpoint.ts`）：设备行已落盘、令牌已签发，
   而"中转还没收到名册"是可恢复的（下次连上中转整份重放）。纯局域网配对根本没有中转，
   这条上报**必然**失败 —— 把它当失败会让最后一步前功尽弃。
6. **顺手修掉接受路径的定时器泄漏**：不自愈的连接在对端断开后没停 `scheduleTick` /
   `scheduleFlush`（`stop()` 只在卸载时调），每断一条漏两条定时器链。局域网配对意味着
   手机频繁连/断，这个漏点与"重连几次"成正比；它在测试里的表现是整个进程不退出。
7. **建连超时按地址分档**：局域网/回环那一跳 3 s、其余 10 s（与 `transport_factory.dart`
   的 direct/relay 同一组数与同一条判据）。少了这一档，跨网配对会先为每一条死掉的
   局域网地址等满 10 秒才轮到中转。
8. **确认卡如实说走的是哪条路**：`PairingAttempt` 带 `dial` / `dialUrl`，卡片按它显示
   "局域网 · ws://…" 或 "中转 · 根地址"。走局域网却写"中转"，会让人以为中转必须开着。

## Alternatives considered

1. **把候选公钥放进 `hello` 帧**（最自然的形状：手机连上就自报身份）
   - 最强的理由：候选身份本来就在握手帧里过线，URL 里再带一份是重复；
     `hello` 加两个字段就能让 `?pair=` 只带 offerId。
   - 为何被否：`hello` 的 transcript 是 `dsh-mobile/v1|hello|ephPubA|devId|nonceA|…`
     （`protocol/handshake-frames.ts:17`），加字段等于改协议版本 —— 而本次范围明确
     不含握手，`protocol/` 的 454/26/49 与跨端密码学向量必须继续成立。
     现有形状下电脑侧在 `hello` 那一刻就要用对端静态公钥验签与派生
     （`handshake-driver.ts` 的 `peerOf(hello.devId)`），所以公钥必须在**建连之前**可得。
2. **候选走升级头（`X-DSH-Pair: <base64url>`）**
   - 最强的理由：不进 URL、不进任何代理日志，`IOWebSocketChannel` 本来就支持 `headers`。
   - 为何被否：自定义升级头在反代/网关后面会被吞掉一部分，而这一跳要能被任何 WS 客户端
     拨通（真机、node 替身、将来的其它端）；query 是 WebSocket 规范里唯一必然到达服务端的
     位置（`ws` 的 `connection(socket, request)` 给的就是 `request.url`）。候选里只有公钥
     与设备名，都不是秘密。
3. **有 `lan` 就跳过登记**
   - 最强的理由：省一次网络调用，也不再有"登记失败"这个分支。
   - 为何被否：中转可用时，登记让**同一张码**在跨网场景也能用（手机不在同一 WiFi）。
     跳过等于自断一条路，而代价只是"先试一次"。
4. **名册失败仍算失败，只对局域网连接豁免**
   - 最强的理由：中转那条路上，名册没到 = 手机拿着令牌也换不到票，"配对成功"是个半真。
   - 为何被否：要把"这条配对是不是经中转来的"一路透到 `pairing-endpoint.commit`，
     多一个只有两个取值的参数；而失败本身的代价更贵 —— 手机丢掉刚签发的令牌、用户重扫，
     电脑侧却已经写了一行（同一台手机攒出第二行）。现在的行为是"配对成功 + 名册稍后重放"，
     手机侧那段时间看到的是可恢复的 `device-unknown`（"稍后重试，不必重新配对"）。
5. **局域网与中转并发拨（竞速）**
   - 最强的理由：跨网时省掉局域网那几次超时。
   - 为何被否：中转那条要先 HTTP 换票，并发会在"局域网已经通了"时白花一次换票，
     还会让失败原因变成两条路的混合；而同网段优先的**顺序**拨已经把第一条命中率
     拉到最高（电脑侧也把默认路由的地址排在最前）。

## Consequences

- 收益：关掉中转也能出码 → 扫码 → 配对 → 之后纯局域网直连；跨网那条路一个字节没变。
- 收益：`pair-result` 的失败分支不再有"电脑已保存授权，但中转尚未确认"这一档
  （它对应的状态现在直接算成功），手机侧那条 `relayOffline` 分支随之删除。
- 代价：**候选身份进 URL**（两把公钥 + 设备名，都不是秘密，但会进电脑侧/反代的访问日志）。
- 代价：二维码载荷变大（每个局域网地址约 25 字节）；手机多一次"先拨局域网"的等待 ——
  死地址按 3 s 一档收口（局域网/回环），同网段优先再把它压到第一条。
- 代价：接受路径断开时**停掉两个周期任务**（原来会一直空转）。这是行为变化：
  已关闭的连接不再"假装还在调度"。
- 代价：`PairingOffer` 多一格 `lanUrls`，所有手搓 `Pairing` 替身要补 `lanUrls: []`
  （`admin-face.test.ts` 两处）。

## 判据

- `cd connector; pnpm exec tsc --noEmit` → 0；`pnpm build` → ok；
  `pnpm test` → **844 项**（基线 831 + 新增 13）。
- `node protocol/verify-fixtures.mjs` 454 / `verify-loopback.mjs` 26 / `verify-vectors.mjs` 49 全绿
  （本次没动 `protocol/`）。
- **变异校验**（每条恰好红 1 条）：
  - 去掉 `?pair=` 与候选 `offerId` 的一致性检查 → `pairing-lan.test.ts` 1/6 红；
  - 去掉"有局域网地址就降级出码" → `pairing-offer.test.ts` 1/34 红（含 admin-face）；
  - 去掉接受路径的定时器收口 → `connection-accept.test.ts` 1/4 红。
- `node app/tools/verify-platform-boundary.mjs` → 712 项全绿；
  `cd app; dart analyze --fatal-infos lib test integration_test` → 0；
  `flutter test` → **1684 项**（基线 1675 + 新增 9）。
- **跨语言形状对拍**（两侧各写一份格式，错的那侧只会表现为"握手超时"）：Dart 的
  `pairingDialUrl()` 生成的 `ws://192.168.1.5:8790/?pair=…&cand=…`（含中文设备名）交给
  `connector/src/pairing-lan.ts` 的 `readPairingRequest()` 解回来，字段逐字相同。
- **隔离实例实测**（`DSH_HOME=D:\tmp\dsh-probe-home`，profile `probe` 零 dsh-mobile 配置，
  连接器 0.1.15 由本地 tgz 装入；**中转未运行**：没有连接器令牌，`/api/dsh-mobile/transport`
  的 relay 通道 `running:false`）：
  - `POST /api/dsh-mobile/pair` → **HTTP 200 + SVG 9535 字节**（旧行为是 400"登记失败"）；
  - SVG 用 jsQR 解回载荷：`lan: ["ws://192.168.110.79:18790", "ws://192.168.40.1:18790",
    "ws://192.168.235.1:18790"]`（默认路由那张网卡排第一，另两条是虚拟网卡）；
  - node 替身拨 `ws://192.168.110.79:18790/?pair=…&cand=…` → 握手 → `pair-commit` →
    `pair-result{ok:true}`，拿到 `deviceToken`；明文帧里没有 code/令牌；
  - 再用已配对身份（不带 `?pair=`）拨同一地址 → `repo.info` 回 `protocol:1`（真进服务态）。
  - **端口是 18790 不是 8790**：用户日常那台 DSH（14:19 启动）占着 8790，探针用面板把
    `listenPort` 改到 18790 验完，已把 profile 的 `cordis.patch.yml` 恢复成 `[]`。
    端口只是配置，机制与端口无关；单实例机器上默认就是 8790。
- **App 侧真实代码打真连接器**（一次性探针，仓库外；不是 Node 替身）：把探针实例的载荷喂给
  `PairingOffer.fromQrPayload` → `beginPairing`（`transportFor` 用真的 `WebSocketTransport`，
  `send` 做成"一被调用就抛"），阶段是「局域网直连… → 等待你确认」，拨的是
  `ws://192.168.110.79:18790/?pair=…&cand=…`，`PairingDial.lan`，`commit` 拿到 22 字符设备令牌
  （电脑侧多出一行「Dart 直连探针」）。**HTTP 一次都没调** —— 局域网那条路确实不碰中转。
- 配对成功后种进端点表的那几条有单测（`pairing_vectors_test.dart` 的「配对成功后的端点表」）：
  直连在前、中转在后、每条都盖 `hostId`；老载荷只剩中转一条。
- **未验证**：新配对流程在**安卓真机**上没跑（2026-11-03 用户选择用接口验，不折腾手机）。
  这一层剩下的只是 Android 运行时（明文策略 / 权限），而同一套 `WebSocketTransport`、
  同一个 `ws://<私网IP>:端口` 形状**已经在真机上跑着**（手机 192.168.110.28 → 8790 的既有直连）。
  要补的话只需一次「重新配对 → 扫本机出的码」—— App 目前没有"再添加一台电脑"的入口，
  进配对页只能走「重新配对」，它会清掉手机对本机的凭据。

## 代码入口回指

- `connector/src/pairing.ts` —— 载荷的 `lan` 与 `PairingOffer.lanUrls`。
- `connector/src/pairing-lan.ts` —— `?pair=` / `cand` 的请求形状与 `pairingDialUrl`。
- `connector/src/pairing-offer.ts` —— 登记失败时"有 lan 就降级"。
- `connector/src/transport/listener.ts` —— `accept(UpgradeRequest)`。
- `connector/src/index.ts` —— `lanUrlsOf` / `bindingOfUpgrade`。
- `connector/src/pairing-endpoint.ts` —— 名册失败不再算配对失败。
- `connector/src/transport/connection.ts` —— 不自愈的连接断开时停表。
- `app/lib/core/pairing.dart` —— `lanUrls` 解析与 `pairingDialUrl`。
- `app/lib/core/pairing_flow.dart` —— 先局域网、全不通才回落；`PairingDial` 让确认卡如实说路径。
- `app/lib/main.dart` —— 配对成功后把 `lan` 种成 direct 端点；配对传输按地址分档超时。
