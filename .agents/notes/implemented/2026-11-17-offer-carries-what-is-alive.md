# Agent Note: 出码只写"此刻活着的路"，不再问"这张码给谁用"

Status: implemented

## Problem

2026-11-13 把出码做成「同一 WiFi / 任何网络」二选一之后，出现了三类自相矛盾的场景：

1. **选择与能力混在一起**。用户以为"选了 WiFi 就能走 WiFi"，而码里能不能写局域网，
   只取决于监听面此刻有没有一条可上报的地址。选了一档而那条腿不成立时，系统只能报错。
2. **主按钮不看能力**。`connector/client.js` 的「出配对码」只判 `busy`，不判"有没有路"，
   于是操作者先点、再读红字；而红字说的还是错的（下一条）。
3. **"直连可用"有两份判据**。面板判能不能点用 `connection.direct.running`（监听在跑），
   服务端判能不能出码用 `lanUrlsOf().length > 0`（监听在跑 **且** 选得出一条可上报地址）。
   监听开着但拿不到默认路由 IPv4、或主地址被用户 `hide` 时，按钮能点，点了报
   「直连监听没开」—— 一句与事实相反的话（2026-11-17 用户原话："我明明开着，它说没开"）。

根因不是文案，是**把"能力"做成了"选择"**：码里写哪几条地址是电脑的事实，不是用户的偏好。

## Decision

1. **删掉「这张码给谁用」**。`admin/routes.ts` 的 `/pair` 不再读 `purpose`；
   `offerPairing()` 也不再收它。码里写哪几条路只由能力决定：
   直连有可上报地址就有 `lan`，中转控制面 `connected` 就有 `relay`。
2. **判据收成一处**：`pairing-offer.ts` 的 `planPairingOffer({lanAvailable, relayConnected, lanReason})`。
   两条都没有时抛错，且**分档说清**直连是"监听没开"还是"开着但没有可上报的主地址"
   （`lanReason` 由装配层给，它才知道 `listener` 是不是 `null`）。
3. **`withRelay` 改由能力驱动**：中转连上了才登记；没连上不登记、`routes` 只留 `lan`。
   登记失败时仍按原规则降级（有 `lan` 就出码并标 `lanOnly`，没有就不出码）。
4. **面板只报通道事实，不预测码内容**：一行「通道：直连监听中 · 中转未连接」，
   两条通道都没开时主按钮禁用。删掉两档 chip 与 5 个 i18n 键，新增 5 个
   （含 `/connection` 还没读回来时的「正在读取通道状态」—— 那时不扣按钮，
   让服务端按真值回答）。文案统一为「状态 + 后果 + 动作」，不写实现细节。
   - **为什么不再写"本次二维码：…"**：码里能不能写直连还要看"有没有可上报的地址"，
     那要刷新默认路由才知道（`refreshLanHint`），面板在出码前无从得手；写出来就是
     第二份判据，回到本次要修的那个缝隙。预测与事实分开：出码前报通道，
     出码后报码里实际有什么（`pairRelayReady` / `pairLanOnly` / `pairRelayOnly`）。
5. **手机侧不变**：仍按 `device.route_policy` 自动拨号。选哪条属于手机，不属于出码这一屏。

## Alternatives considered

1. **保留二选一，只把主按钮按能力禁用**
   - 最强的理由：用户仍能表达"这一次只要局域网"（例如不想让中转知道这次 offer 的存在）。
   - 为何被否：`offerId` 不含任何秘密（秘密只存电脑侧哈希），登记只让中转能路由候选；
     而"是否登记"由"中转是否连上"这一事实决定更诚实。保留选择等于每次让用户回答一个
     系统自己就知道的问题，答错就得到一张配不上的码。
2. **出两张码（局域网一张、中转一张）**
   - 最强的理由：一眼就知道该扫哪张，电脑侧也不用在载荷里解释"少了什么"。
   - 为何被否：同一时刻会有两条一次性邀请，过期、清理、面板画哪张都要两套；
     而用户仍要判断"我这次该扫哪张"——把判断题搬到更显眼的地方，不是消除它。
3. **半删：UI 保留二选一但 `/pair` 忽略 `purpose`**
   - 最强的理由：兼容旧面板，连接器与界面可以分批升级。
   - 为何被否：界面还在承诺一个不存在的选择，点了没反应比报错更难查。
4. **让 `issuePairingOffer` 直接收能力（`relayConnected` / `listenerRunning`）**
   - 最强的理由：一条路径从判据到降级全在一个函数里，少一层参数转换。
   - 为何被否：那会把"监听面是否为空"这种装配层事实塞进出码核心，破坏它"脱离 DSH 与网络可测"
     的边界（`pairing-offer.ts` 文件头）。`planPairingOffer` 只收两个布尔与一句原因，仍可纯单测。

## Consequences

- 收益：一个按钮、一条判据；不会"先点再读红字"；报错不再把"没有地址"说成"没开"。
- 收益：命令与服务端共用 `planPairingOffer` 的同一句话；面板只报通道事实，
  不再维护第二份"码里有什么"的预测。
- 收益：出码次数不再影响中转登记量 —— 中转的 `register` 每次会
  `forgetConnector(connectorId)` 覆盖同一连接器的旧登记（`relay/src/pairing-registry.ts:43`），
  所以"中转在线就一定登记"不会积累条目。
- 收益：命令出码与面板出码的**地址新鲜度统一**了（`dsh-mobile-pair` 的 handler 现在也先
  `refreshLanHint`）：以前换 WiFi 后命令出码可能带死地址，面板不会。
- 代价：失去"中转在线也强制只出局域网码"的选项；中转在线时 offer 一定会登记。
- 代价：旧面板发来的 `{purpose}` 被忽略且**不报错**——静默接受一次行为变化
  （连接器与面板同包发布，实际只在本地开发/缓存的旧页面上出现）。
- 边界（实测修正）：`content-type: application/json` + **空 body** 在当前 DSH 桥接上
  仍回 200（容忍），所以面板改发 `{}` 是**边界防御**，不是修一条已经在发生的故障；
  保留它的理由是代理、其它宿主或未来的网关可能严格解析空 body。
- 边界：监听在跑、但没有可上报地址时，面板的通道行仍写「直连监听中」（事实），
  点出码会被服务端拒绝并给出分档原因。这是有意的：显示面不复制判据；
  若把 `lanReady` 也搬进 `/connection`，面板读到的 `lanHint` 仍可能比出码那一刻旧，
  等于用一个"更细但更旧"的事实换掉一个"粗但对"的事实。
- 边界：手机侧已由 `2026-11-17-pairing-route-choice-on-phone.md` 接着落：配对页同时探两条、
  由用户选这次走哪条。本批只定"电脑不再替用户押一条路"。

## 判据

- `cd connector; pnpm exec tsc --noEmit` → 0；`pnpm build` → ok。
- `pnpm test` → **870 项（869 过 / 1 跳过）**：基线 862 + 新增 8（判据 5 条；
  面板 2 条「两条都没开时按钮禁用并说明缺哪条」「只有直连时说明中转未连接且仍可点」；
  端点 1 条「旧面板的 `{purpose}` 被忽略且不报错」）。
- `node --check connector/client.js` → ok。
- 变异校验：把 `planPairingOffer` 的 `lanReason` 分支去掉、始终写"直连监听未启动" →
  恰好「没有可上报地址必须复述原因」那一条红（两次改动后各跑过一次）。

### 隔离实例实测（2026-11-17，不碰 desktop profile）

- `$env:DSH_HOME='D:\tmp\dsh-mobile-home'`；profile `dsh-mobile-test`（连接器以 junction
  指向仓库，`pnpm build` 的产物即被测代码）；`dsh --profile dsh-mobile-test --no-open --port 3099`。
- 通道真值：relay `running:true / connected:false`（`ECONNREFUSED 127.0.0.1:8787`），
  direct `0.0.0.0:18791`（避开日常实例占用的 8790）。
- `POST /api/dsh-mobile/pair`（`{}` body）→ **200 + SVG**，`lanOnly:true` / `lanAvailable:true`。
- 同一端点、只带 `content-type` 的空 body → **200**（见 Consequences 的边界修正）。
- 旧面板形状 `{purpose:'lan'}` → **200**，参数被忽略。
- `POST /transport/direct/stop` 后出码 → **400**，正文逐字为
  「无法生成配对码：直连监听未启动；中转未连接。请先启动直连监听或中转拨号。」
  —— **不是空正文**，历史那个"400 且 body 为空"的坑在这条路径上不复现。
- `POST /transport/direct/start` 后出码 → **200** 复原。

## 代码入口回指

- `connector/src/pairing-offer.ts` —— `planPairingOffer` / `PairingCapacity`。
- `connector/src/index.ts` —— `offerPairing` 只传能力，不再传目的。
- `connector/src/admin/routes.ts` —— `/pair` 不读请求体。
- `connector/client.js` —— `routeLine`（通道事实）与无参 `pair()`（空对象 body）。
- `docs/subsystems/pairing-v2.md` §3 —— 码里写哪几条由能力决定。
- `docs/subsystems/remote-channel.md` §12.1 —— 四种情况的两侧文案。
- 被取代的部分：`.agents/notes/implemented/2026-11-13-connection-route-model.md` 的
  「两个用途二选一」；三层模型（能力 / 策略 / 当前）本身不变。
