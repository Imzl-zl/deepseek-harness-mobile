# Agent Note: 连接方式收成「能力 / 策略 / 当前」三层，出码只承诺此刻活着的路

Status: implemented

## Problem

「走哪条路」在五处各判一次，没有任何一处能回答"这次为什么走中转"：

| 问题 | 现在的判据 | 位置 |
|---|---|---|
| 扫码先拨哪条 | 手机自报 IPv4 与码里地址**同一 /24** 才直连优先 | `app/lib/core/pairing_flow.dart:286-292` |
| 连上后走哪条 | 记住的端点先启动 250ms，其余错开**竞速**，先建 socket 的赢 | `app/lib/core/endpoint.dart:393`、`core/endpoint_transport.dart:18-26` |
| 码里有什么 | 默认路由那张网卡的 IPv4 ∩ 监听面地址池 | `connector/src/index.ts:701-722`、`endpoints.ts:119` |
| 出码要不要中转 | `relayUrl` + 令牌，**不看通道是否连上** | `connector/src/pairing-offer.ts:95-119` |
| 用户说的"关中转" | 只停拨号连接 | `connector/src/index.ts:1610-1627` |

四个由此产生的现象：

1. **同一 WiFi 却走中转**。码里没有局域网地址、手机 IP 取到蜂窝/VPN 网卡（`app/lib/platform/lan_address.dart:30-46` 取第一个非回环 IPv4）、或直连被防火墙丢包 —— 三种失败同一个观感。
2. **关掉中转出码**：要么报错（局域网地址为空 + 登记失败，`pairing-offer.ts:100-108`），要么码里照样带一条已经死掉的 relay（`/pairing/register` 只验令牌、不要求连接器在线，`relay/src/http-face.ts:122-132`），手机带着票去升级才卡住。
3. **配对偏好与连接顺序是两套**：`device.pairing_prefer` 只影响配对那一次，端点排序只影响连接；改一个另一个不动，用户只能记住"设置里有两个地方都像在管这个"。
4. **面板上两种开关长得一样、语义不同**：「停用直连」写的是 `listenPort: 0`（持久配置），中转开关是运行时通道（重启按配置自己起）。

## Decision

把「走哪条路」拆成三层，每层只有一个所有者：

| 层 | 所有者 | 回答 |
|---|---|---|
| **能力** | 电脑的通道注册表 | 直连在监听吗？中转控制面连上了吗？（`connected`，不是配置） |
| **策略** | 手机，`device.route_policy` | 这台手机想走哪条：`自动 / 只用直连 / 只用中转` |
| **当前** | 界面 | 这次实际走了哪条、为什么；回落必须说出来 |

出码改成"**码里有什么 = 此刻有什么**"，并把用途交回用户（一个二选一，默认按能力选）：

| 直连监听 | 中转 connected | 默认用途 | 二维码 | 登记 |
|---|---|---|---|---|
| 开 | 是 | 任何网络 | `lan` + `relay` | 登记 |
| 开 | 否 | 同一 WiFi（唯一可选） | 只有 `lan`（`lanOnly: true`） | **不登记** |
| 关 | 是 | 任何网络（唯一可选） | 只有 `relay` | 登记 |
| 关 | 否 | — | 拒绝出码，文案给修复动作 | — |

两个用途是**同一个按钮上方的一组二选一**：`同一 WiFi` / `任何网络`。不可用的那一档禁用并附一行原因
（"中转未连接"），不隐藏 —— 隐藏会让人以为这个功能不存在。用户不需要每次做决定：默认值就是"此刻能用的最大集合"。

准入门槛（可机械判定）：

1. "要不要试这条端点"只有一个过滤点（`EndpointTransport.connect()` 按策略过滤），全仓不再有第二处。
2. `auto` 下**直连整体排在 relay 之前**（remembered 只在本桶内生效），单测钉住——现在的 remembered 可以跨桶压过直连。
3. 二维码里的 `routes` 与出码那一刻 `channels()` 的真值一致；中转未 `connected` 时 `routes` 不含 relay，且不调 `/pairing/register`。
4. 迁移完成后全仓 grep `pairing_prefer` 只剩迁移代码。
5. 设置页只有一处能改策略；端点行只有"立刻用这条"（本次覆盖）与"排序"（同桶内）两种动作。

三个概念的边界（写死，避免又长成新的一团）：

- **策略** = 长期意图，跨 App 重启生效。
- **点名** = 本次覆盖（`useEndpointNow`，失败即回自动），不改策略。
- **排序** = 同桶内的先后，不能用来表达"我只想直连"。

## Alternatives considered

1. 保持"一张码永远两条路"（现状）
   - 最强的理由：在家、在外用同一张码，用户什么都不用管。
   - 为何被否：码会承诺一条已经死掉的路。中转断开时登记仍成功，手机换票 201（`relay/src/http-face.ts:69-74` 对配对用途不检查在线），升级到 `/ws/device` 才卡死；用户在外面扫了配不上，真因只在电脑侧一条日志里。
2. 出码时让用户选"这次出直连码 / 中转码"
   - 最强的理由：完全显式，没有任何猜测。
   - 为何被否：电脑自己知道哪条活着。把可判定的事实变成每次都要做的一道题，用户答错就得到一张配不上的码。
3. 按网络自动切换（把上次成功的路当默认）
   - 最强的理由：零配置，合"上次能通这次大概率也通"的直觉。
   - 为何被否：不可解释。换网后没人知道为什么走中转；"上次成功"也不等于"此刻可用"（中转在线 ≠ 直连可达）。remembered 只保留作同桶内排序。
4. 两个通道开关就是策略（面板现状）
   - 最强的理由：一个开关一个事实，不引入第二套概念。
   - 为何被否：开关是能力（端口开不开、拨号跑不跑），策略是意图。混用正是"关掉中转却仍出带中转的码"的来源。
5. 只靠端点排序表达意图
   - 最强的理由：用户完全控制，实现最省。
   - 为何被否：排序表达不了"打不通就告诉我，别偷偷走中转"；而竞速下顺序只值 250ms 的启动差，用它承载意图是错位。

## Consequences

- 收益：一个用户概念（两条路 + 三档策略）；出码不再撒谎；"关中转"终于有确定语义；配对与连接共用一个偏好。
- 收益：`device.pairing_prefer`、跨桶的 remembered、`myIpv4` 参与"走不走直连"的判断一起收掉。
- 代价：多一个设备键与一条迁移；出码在中转重连中退化成纯局域网码，用户要等中转连上（文案必须说清）。
- 代价：面板「连接」卡按"能力 / 路由配置 / 配对"重排（`client.js` 与约 10 个文案键），`docs/subsystems/remote-channel.md` §12.1 与 `pairing-v2.md` §3 要同步改。
- 代价：协议多一个可选 `routes` 字段。旧版 App 忽略它，仍会按 `relay` 试一次（但会先试 `lan`，配对照样成立）。

## 落点（这次改了哪些文件）

1. `docs/`：`remote-channel.md` §12.1、`pairing-v2.md` §3、`ui-state.md` 的键表、`design-and-tech-plan.md` §7.8。
2. 电脑侧：`pairing.ts` 的 `routes` / `relayAvailable`；`pairing-offer.ts` 的 `withRelay`（中转那条腿不存在时不登记）；`index.ts` 的 `offerPairing(purpose)`；`admin/routes.ts` 读 `purpose`；`client.js` 出码卡两档 + 新 i18n 键。
3. 手机侧：`model/route_policy.dart` 与 `model/task_notice_policy.dart`；`core/endpoint_policy.dart`（唯一过滤点）；`endpoint_transport.dart` 的 `policyOf`；`endpoint.dart` 的 `dialOrder` 分桶；`pairing_flow.dart` 三档各走各的；`ui_state.dart` 的 `device.route_policy` 与旧键迁移；`connection_mode_page.dart`（新页）；设置页、连接面板、空态。
4. 测试：`endpoint_policy_test`（5）、`endpoint_transport_test` 的策略四条、`endpoint_switching_test` 的分桶期望、`pairing_flow_test` 的三档与冲突、`ui_state_test` 的迁移、`notice_test` 的三档、`connection_actions_sheet_test` 的收窄、`widget_test` 的两处反断言。connector 856 项（+2：只要局域网不登记、中转离线码里不含 relay）。
5. 原型：`mock/proto/app.js` 的连接 sheet 同步删「打开侧面板」、加「重新连接」；`verify-proto.mjs` 新增 4 条断言（共 34 项），并做过一次变异校验（把「打开侧面板」加回去 → 恰好那一条红）。

尚未做：真机验收（关中转出码→手机直连；关直连出码→手机中转；两条都关→报错文案；策略=只用直连时断开中转不影响连接）。

## 真机验收结果（2026-11-14，隔离实例 :3099 + 中继 :8787 + 小米 23113RKC6C）

四条全过，逐条证据：

1. **关中转出码**：`purpose=any` → 400「中转没连上：先启动中转拨号，或改出「同一 WiFi」的码」；
   `purpose=lan` → 出码且 `lanOnly:true`。手机扫该码走**局域网直连**（18791 上有来自手机 IP 的连接）。
2. **关直连出码**：`purpose=lan` → 400「直连监听没开……」；`purpose=any` → 出码，
   载荷**没有 `lan` 字段**、`routes:["relay"]`、`lanAvailable:false`。直连停着时手机自动落到中转
   （8787 上有手机连接、设备仍 online）。
3. **两条都关**：出码 → 400「两条路都没开：先启动「直连监听」或「中转拨号」其中一条，再出码」。
4. **策略**：设为「只用直连」（页面打勾 + 连接面板右侧显示当前档）后，把**直连停掉、中转开着**，
   手机**没有**回落到中转（8787 无手机连接）—— 过滤确实生效，不是"排后"而是"不试"。

### 顺带修掉的真 bug：`extra` 在监听面停着时仍上报

第 2 条第一次跑时**没有报错**：直连监听已停，二维码却仍宣称局域网可用
（`lanAvailable:true`），因为验收时我给这台机器加过 `extra`（`ws://192.168.2.41:18791`），
而 `describeEndpoints` 对 `extra` 不看监听面是否在跑。

根因是"能力"这条判据被表达了两处：`listener.urls`（跑没跑）与 `extra`（用户点名）各算一次。
修法是把它们合成一条：**没有监听面 ⇒ 一条直连地址都不报（含 `extra`）**，落在
`describeEndpoints` 里（唯一一处）。`extra` 的语义是"额外上报哪几条"，不是"凭空造一条能拨的路"。

回归用例：`tests/endpoints.test.ts` 的「监听面没起：`extra` 也一条都不报」。
connector 次日全量 **857 项**绿（+1）。
