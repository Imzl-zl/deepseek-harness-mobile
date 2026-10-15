# Agent Note: 端点是一等公民 —— 中转与局域网直连共用一次配对

Status: implemented

## 落地形状（2026-10-14，与上面的判据一一对应）

手机侧：

- `core/endpoint.dart`：`Endpoint` / `EndpointKind`、`endpointToJson` / `endpointFromJson` /
  `parseEndpointList` / `mergeEndpoints`，以及 `isPrivateOrLoopback`（替换 `checkedRelayUri`
  原来的回环-only 判定）。
- `core/endpoint_transport.dart`：`EndpointTransport`（`endpointsOf` 现读 + 按序拨 +
  一轮一次 + 不降权 + 只吞 `TransportException`）。**回落住在传输层**，连接层一行未改。
- `platform/transport_factory.dart`：`transportFor` —— `core/` 与 `platform/` 之间唯一
  的一座桥（`core/` 禁 import `platform/`）。
- `platform/pairing_store.dart`：`endpoints` 键 + `saveEndpoints`；老凭据一次性迁移
  （从 `relayUrl` 造一条 relay 端点）。
- `data/app_model.dart`：端点表与 `activeEndpoint` 的所有者；`mergeDiscoveredEndpoints`
  （没有变化不落盘）、`preferEndpoint`（手动改序）、`_discoverEndpoints`
  （`connector/unsupported` 不当故障）。
- `lib/main.dart`：`EndpointTransport` + 每中转端点一个 `PairingClient`（按地址缓存）。

连接器侧：

- `transport/listener.ts`：`Listener.urls`（`os.networkInterfaces()` 枚举非内部网卡，
  通配地址才枚举，具体地址就用它；IPv6 括起来；link-local IPv6 跳过）。
- `endpoints.ts`：`describeEndpoints`（纯函数）+ `createEndpointsPort`。
- `protocol/methods.ts`：方法面 21 → 22（`endpoint.describe`）。
- `dsh/caps.ts`：`caps.direct`（**唯一不由服务存在性决定**的能力位 —— 看监听面起没起来）。
- `handlers.ts` / `index.ts`：按能力位挂 `endpoint.describe`。

**还没做的**：手机设置页的端点列表 UI（`AppModel` 已把 `endpoints` / `activeEndpoint` /
`preferEndpoint` 备齐，UI 是纯展示层工作）。有自动发现与自动回落，所以这一块是
"可见可改"而非"必须操作"。

## Problem

用户的实际场景：电脑带着不方便，想用手机操作；电脑手机常在同一个 WiFi 上，
局域网延迟远低于公网中转。于是要一个"同一局域网直连"的配置。

现有代码已经具备直连的**全部基础设施**，但缺三样，且缺的方式会让它不好用：

1. **连接器直连监听面已存在且完整**（`connector/src/transport/listener.ts`：
   每 accept 一条就装配一次、`heals: false`、不终结 TLS、不做应用层鉴权），
   但配置默认 `listenPort: 0`（关）、`listenHost: 127.0.0.1`（只本机）——
   打开它就能被局域网连上。
2. **手机侧只有一个端点**：`PairedCredentials.relayUrl` 是单个字符串，
   传输层写死 `TicketedWebSocketTransport` → `deviceUpgradeUrl()` →
   永远拼 `/ws/device?ticket=<票>`。直连不要票、不要那条路径，
   于是手机**根本无法表达"直连"这种拨号**。
3. **`checkedRelayUri` 把明文 `ws://` 限定在回环**（`core/endpoint.dart:20-27`），
   局域网私网地址会被拒。

不写下这个设计，后来者会把这三处各自打补丁（在手机侧加一个 `if (isLan)`、
在连接器里加一个 `directUrl` 字段），得到"两种连接方式各有一套判据"——
而那两套判据迟早不一致，症状是"手机存着一个连不上的地址且不知道另一条路存在"。

## Decision

**端点（Endpoint）是一等公民，配对只做一次，路由是独立的一维。**

判据（可机械判定）：

1. **一次配对产出的是身份，不是路由**。`PairedCredentials` 里与端点相关的
   **只有** `relayUrl` 一个字段；其余九个（`pcSignPubHex` / `pcDhPubHex` /
   `pairingId` / `masterSeedHex` / `devSignPubHex` / `devDhPubHex` /
   `pcId` / `devId` / `deviceToken` / `refreshToken`）全部只参与握手与换票，
   与从哪条路连过来无关。所以换端点**不重扫码、不重新派生密钥**。
2. **拨号方式按 `kind` 分派，且只有一处分派**。`core/endpoint.dart` 新增
   `Endpoint { kind, url, label }` 与唯一的 `transportFor(endpoint, ticket)`：
   `relay` → 现有 `TicketedWebSocketTransport`（不改一行）；
   `direct` → 裸 `WebSocketTransport`（无票、无路径）。
   分派点唯一，加第三种端点只加一个分支。
   它由 `EndpointTransport`（见判据 5）调用，**不**由装配点直接调用 ——
   否则"端点表"与"选哪个传输"会分成两处。
3. **端点集合由连接器自报，手机只缓存不推断**。新增方法 `endpoint.describe`
   （能力位门控，与 `session.modelCatalog` 同一个 pattern）：返回它**实际绑定到的**
   地址（`server.address()` + 非内置网卡地址，不是配置里写的那个字符串），
   外加它知道的中转地址。手机连上后拉一次，覆盖本地缓存。
   地址枚举用 Node 内置的 `os.networkInterfaces()`（连接器侧无新依赖），
   每条带上网卡名做 `label` —— 切 WiFi / 插网线时列表自己变。
4. **发现结果是"下次拨号的提示"，不是"立刻重连的命令"**。手机只在
   **下一次建连**时用刷新后的端点表；正在用的连接不因此被换掉。
5. **拨号失败自动换下一个端点，成功者成为 active**。换下一个之前不再重试当前
   这个；本进程内握手未完成的端点降权（避免半坏直连反复横跳）。
   持久化的 active 只由"完整服务过一次建连"的端点取得。
   **回落住在传输层内部，连接层一行不改**：连接层只认识一个
   `ChannelTransport`，`connect()` 抛错就进退避重连**同一个** transport
   （`core/sync_client_impl.dart:206`）——所以把回落写进连接层是错的，
   它会"重试同一个死地址"。正确形状是一个新类
   `EndpointTransport implements ChannelTransport`：持有有序端点表 +
   `transportFor` 工厂，`connect()` 按序试到第一个握手完成，
   `send` / `close` 委托给当前活跃的那个（与现有
   `TicketedWebSocketTransport` 持 `_inner` 是同一个手法）。
   装配点从"传一个 `TicketedWebSocketTransport`"换成"传一个 `EndpointTransport`"。
6. **明文 `ws://` 只允许非公网地址**。`checkedRelayUri` 的回环判定扩成
   "回环 + RFC1918 + CGNAT(100.64/10) + link-local + unique-local"。
   公网仍必须 `wss`。取舍见 Consequences。

DSH 侧依据（只读参考源码）：直连监听面的鉴权就是握手本身，
未配对设备在 `hello` 处被 `protocol/not-paired` 拒（关闭码 4003），
与中转面同一套装配（`index.ts` 的 `makeConnection` 两条路共用），
所以**不存在第二套"谁能连"的判据**。

## Alternatives considered

1. 把直连地址写进二维码（`{"v":2, ..., "direct": "ws://ip:port"}`）
   - 最强的理由：零新方法、零新能力位，配对那次顺手就拿到了；
     手机侧只要多存一个字段。
   - 为何被否：二维码是**一次性**的，而 IP 是会变的（DHCP、切 WiFi、
     插网线）。用户的核心场景恰恰是"电脑不在身边"——那时没法重新出码，
     于是一个过期 IP 会让手机永远拨一个死地址，而它不知道还有中转这条路。
     更根本的：这把**临时路由提示**塞进了**永久凭据包**，两种生命周期混在一起。
2. mDNS / Bonjour 零配置发现
   - 最强的理由：真正的零配置，电脑一上线手机就看见，不需要任何信道。
   - 为何被否：App 侧要引入一个 mDNS 依赖，而项目对 App 依赖有硬闸门
     （`cryptography` 是目前唯一非 SDK 依赖，选型闸见
     `.agents/notes/implemented/2026-10-02-mobile-core-crypto-choice.md`）；
     Node 侧也要一个广播器。为"少写一个方法"引入两个依赖不划算。
3. 手机设置里手填直连地址
   - 最强的理由：实现量最小，连接器一行不改（只要开监听）。
   - 为何被否：用户得自己知道电脑的局域网 IP 和端口；IP 一变就得手改一遍。
     这与"切换直接切"的目标相反——它把发现成本转嫁给用户。
4. 扩 `sync.hello` 的应答，把端点表塞进去
   - 最强的理由：确实零新方法，且每次建连都会刷新。
   - 为何被否：`sync.hello` 的职责是"前后台态 + 订阅集声明"（契约 §5.4），
     把路由信息混进去会让一个方法答两件不相关的事；且它无法被能力位门控——
     手机没法知道"这台连接器到底有没有开直连"，只能靠应答里有没有字段猜。

## Consequences

- 收益：换端点不重扫码（用户的核心诉求）；直连地址随连接器实际绑定地址
  自愈，IP 变了下一次经中转连上就刷新；拨号分派只有一处，加第三种端点
  （蓝牙 / Tailscale-only / 云中转）只加一个分支；中转始终是可回落路径，
  直连是优化而非依赖。
- 代价：
  - **契约面变宽**：方法面 20 → 21（`endpoint.describe`），
    契约 §5.7 的方法表、§7 的能力位、`AGENTS.md` 里"方法面 12/20"的计数
    都要同步；两侧各加一套测试。
  - **明文暴露面从回环扩到私网**：同一网段的人能看见帧的大小与时序
    （元数据），但**不能伪装任一端**——握手是双向 Ed25519 签名 + X3DH +
    AEAD，电脑公钥在配对时钉死（契约 §12.1）。这是刻意的取舍：
    局域网直连的意义就是低延迟，为它上 TLS 要么让插件持有证书私钥
    （`listener.ts` 明确不做），要么每台设备配一张自签证书再让手机信任它
    （那是另一套 PKI）。**公网路径仍强制 `wss`，这条不放宽。**
  - 手机侧要加一小块设置 UI（端点列表 + 当前用哪个）。有自动回落，
    所以这块 UI 是"可见可改"而非"必须操作"。
