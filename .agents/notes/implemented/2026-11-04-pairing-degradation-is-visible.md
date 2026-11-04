# Agent Note: 配对的双路由 —— 降级可见 + 拨号顺序偏好

Status: implemented

## Problem

2026-11-03 的「配对不再依赖中转」让出码在**登记中转失败**时降级成"只有局域网"的码
（有 `lan` 就照出，否则拒绝）。但降级只进了一条 `warn` 日志：

- 用户拿到的二维码**看起来正常**，出门 / 切流量之后才发现配不上；
- 手机那侧的失败文案是"请让电脑重新出码"，而真因是"这张码根本没登记上中转"——
  两个完全不同的动作被说成同一件；
- 电脑侧的命令输出只说"局域网直连：…"，没有"所以跨网不行"这句。

另一件事同一条链：手机**永远先拨局域网**，即使当前网络与码里的地址不在同一网段。
出门在外每扫一张码都要先为一张局域网地址白等一个传输超时。

## Decision

1. **一条码，一个降级标**：载荷加 `"lanOnly": true`（契约 §12.1），不做两张码；
   仍然"有 `lan` 就出码"（断网 / 中转没开时得能配），只是不再静默。
   - **正反两面都说**：`lanOnly` 缺省/false 的唯一含义是"中转登记成功"。只在失败时
     说话仍然回答不了用户真正的问题（"我现在在局域网里出码，等会儿出门还能不能用"），
     所以登记成功时命令、面板、配对页都要明说「出门 / 用流量走中转（已登记）」；
     没有局域网地址时说「只有中转这条路（已登记）」。
   - 电脑侧：`issuePairingOffer` 登记失败且 `lanUrls` 非空时返回 `markOfferLanOnly(offer)`
     （新对象，不改原件）；斜杠命令文案、插件面板（`/api/dsh-mobile/pair` 回
     `lanOnly` + `lanAvailable`）与 `warn` 日志三处说同一句话。
   - 手机侧：`PairingOffer.lanOnly` **只认字面 `true`**；配对页扫完就摆出
     「此码只能在同一 Wi-Fi 下使用（出码时没登记上中转）」；`beginPairing` 对降级码
     **不换票**（那条路这次注定 409），局域网也不通时直接说"只能在同一 WiFi"。
2. **显式拨号顺序偏好**：`device.pairing_prefer` = `auto` / `direct` / `relay`，默认 `auto`。
   - `auto`：知道本机 IPv4、且码里某张 `lan` 与它同一 /24 时先直连；否则**先中转**。
     拿不到本机 IP 时保持旧行为（先直连）—— 不猜。
   - `direct` / `relay`：无条件先试那一条。
   - **三条都只是"先试"**：失败仍回落另一条；没有"选了直连就永远不试中转"。
3. **配对页显示两条路 + 当前正在试哪条**：扫完（解析成功）即显示
   「这张码有两条路：局域网直连（N 个地址） · 中转」；连接过程中显示
   「正在试：换票…」/「正在试：局域网直连…」（就是 `onStage` 的那句）。
4. **同批改掉钉住旧行为的用例**：connector 的「登记失败但有局域网地址」现在断言
   载荷带 `lanOnly`、命令文案说"只能同一 WiFi"，并新增"登记成功时没有这一格"。

## Alternatives considered

1. **出两张码（一张局域网、一张中转）**
   - 最强的理由：用户一眼就知道该扫哪张，电脑侧也不用在载荷里解释"少了什么"。
   - 为何被否：同一台电脑同一时刻会有**两条一次性邀请**，于是手机扫哪张、电脑侧该认
     哪张、面板画哪张、过期清哪张都要两套；而"中转那张登记失败"时用户仍要读文案
     才知道第二张为什么不能用。一张码 + 一个布尔，语义面反而更小。
2. **用 `relay: null` 代替 `lanOnly`**
   - 最强的理由：字段本身就表达"没有中转这条路"，不需要额外布尔。
   - 为何被否：手机解析器把 `relay` 当**必填字符串**（公钥信任与换票都读它），改类型要动
     一个已经稳定的字段；而且事实是"地址还在，只是这次 offer 没登记上"，不是"没有中转"。
     加一个可选布尔不动老字段，老客户端自然忽略。
3. **登记失败就不出码**（回到 11-03 之前）
   - 最强的理由：永远不会发出"只能局域网"的码。
   - 为何被否：断网 / 中转没开时用户就配不了对，而那正是局域网直连要解决的场景。
     保留出码、把代价说清楚，是这两者之间唯一诚实的做法。
4. **不做拨号顺序偏好（硬编码先局域网）**
   - 最强的理由：少一个设置项、少一个落盘键。
   - 为何被否：出门在外每张码先等 N 个局域网超时（每个 3s），且用户无法表达
     "我的中转更可靠"。代价只是一个 `device.` 键，且失败仍回落，不会把谁配死。
5. **让 `auto` 永远先局域网（等于 `direct`）**
   - 最强的理由：行为最简单，少一层"同 /24"判断。
   - 为何被否：那样 `auto` 与 `direct` 完全等价，设置项名不副实；`auto` 的意义正是
     "同一个 WiFi 才值得先试直连"。

## Consequences

- 收益：降级在**扫码之前**就可见；手机不再把"不在同一 WiFi"说成"重新出码"；
  出门配对不再先为局域网白等超时。
- 代价：载荷多一个可选布尔；配对页多一块提示；`device.` 多一个键（`ui-state.md` §2 已列）。
- 代价：`lanOnly` 只描述**这一次出码**没登记上，不描述中转整体不可用 —— 配对成功后
  中转端点照样进端点表（它下次仍可能是通的）。
- 边界：偏好只改顺序，**不消除超时**；局域网 N 条全死时仍要等 N 个传输超时。
  `auto` 在拿不到本机 IP（权限 / 移动网络）时仍先直连 —— 保守，不猜。

## 判据

- connector：`pnpm exec tsc --noEmit` → 0；`pairing-offer.test.ts` 的降级用例改成断言
  `payload.lanOnly === true`、文案含「只能在同一 WiFi 下使用」、日志含 `lanOnly`；
  另断言登记成功时载荷里**没有**这一格，且命令输出含「出门 / 用流量走中转（已登记）」；
  `admin-face.test.ts` 的出码应答包含 `lanOnly` 与 `lanAvailable`。
- app：`pairing_vectors_test`（只认字面 true）、`pairing_flow_test`（降级码不换票 /
  降级码照常配对 / 中转优先先换票 / 中转优先失败回落 / 自动 + 不同网段先中转）、
  `pairing_page_routes_test`（提示与「正在试」）、`ui_state_test` + `ui_state_wiring_test`
  （`device.pairing_prefer` 落盘与恢复）。
- 变异校验：把 `issuePairingOffer` 的 `markOfferLanOnly(offer)` 换回 `offer`，
  **恰好那条降级用例红**（本次实测 1 红 / 4 绿）。
- 真机：同一 WiFi 出码（两条都在）→ 配对 → 关 WiFi / 切流量 → 连接自动落到 relay，
  不用重扫；另测一张"中转没登记"的码，配对页应显式说"仅局域网"。
- **隔离进程实测（2026-11-04，不碰 desktop 的 DSH 与现有配对）**：
  - 本地中转（`ws://127.0.0.1:18787`，`connectorAuth: open`）+ 独立 `DSH_HOME` 的
    `c-isolated` profile（仓库 connector 的 junction，`listenPort: 18790`）。
  - 正常出码：面板回 `lanOnly: false`；二维码解回的载荷有 `lan`（三条，WLAN 在前）、
    没有 `lanOnly`。
  - **停掉本地中转再出码**：面板回 `lanOnly: true`，载荷 `lanOnly: true` 且 `lan` 仍在。
  - 用 App 的**真实 Dart 代码**（真 `WebSocketTransport`、HTTP 缝"一调就抛"）扫降级码：
    **零 HTTP**、`PairingDial.lan`、提交拿到设备令牌。
  - 正常码 + 把 `lan` 换成一个死地址（同 /24）：先直连失败、**换票一次**、回落
    `PairingDial.relay`、提交成功 —— 两条路的回落是真的。
  - 手机侧：新 debug APK 已 `adb install -r`（`firstInstallTime` 不变 = 配对数据保留）；
    **手机 UI 的两条场景没跑**：进配对页要清掉这台手机现有配对凭据，且当时手机锁屏。
    页面文案与"正在试"由 `pairing_page_routes_test` 的两个 widget 用例钉住。

## 代码入口回指

- `connector/src/pairing.ts` 的 `PairingOffer.lanOnly` 与 `markOfferLanOnly`。
- `connector/src/pairing-offer.ts` 的 `issuePairingOffer` / `offerForScanning`。
- `connector/src/index.ts` 的 `offerPairing`；`connector/src/admin/routes.ts` 的 `offer`；
  `connector/client.js` 的 `pairLanOnly`。
- `app/lib/core/pairing.dart` 的 `PairingOffer.lanOnly`；
  `app/lib/core/pairing_flow.dart` 的 `PairingPreference` 与 `beginPairing`；
  `app/lib/ui/pairing_page.dart` 的 `_OfferRoutes`；
  `app/lib/data/ui_state.dart` 的 `UiKey.pairingPrefer`。
- 契约：`docs/subsystems/remote-channel.md` §12.1；键方案：`docs/subsystems/ui-state.md` §2。
