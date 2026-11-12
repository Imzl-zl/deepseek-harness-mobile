# 电脑侧桥接与中转:落地设计

契约见 `remote-channel.md`(本文件只写"怎么落",不重复协议定义)。参考实现对照:`D:\sudy\github\Agents-Anywhere\dsh-bridge-next`(只读)。

---

## 1. 电脑侧桥接(DSH 插件 `connector/`)

### 1.1 形态与工程配置

必须是 npm bundle(声明 `dsh.bundle.patch`),装进目标 profile 的 `node_modules`;不能是动态 Cordis 包(沙箱 trap 掉 `fetch` / `setInterval` / `require`)。

包清单以 `connector/package.json` 为准，本文件不复制它（复制品一定会漂移）。固定的规则只有这几条：

- 全部 `@deepseek-ai/dsh*` 包钉**同一个精确版本**，不写 `^` / `~`；`@deepseek-ai/cordis` 与 `@deepseek-ai/schemastery` 各钉自己的精确版本。
- `engines.dsh` 的下界就是被测版本，上界写成 `<下一条线>-0`（见本节末段与 `.agents/notes/implemented/2026-11-05-connector-engines-upper-bound.md`）。
- 运行时依赖只有 `ws`：监听面要一个 WS 服务端，而 Node 22 的全局 `WebSocket` 只有客户端、没有服务端实现（`.agents/notes/implemented/2026-10-02-listener-face.md`）。
- 其余 DSH 包只用于类型检查；`dsh-settings` / `dsh-credentials` 不是可选的，适配层靠它们的类型钉住 `describe({ redactSecrets: true })` 这个选项名（`.agents/notes/implemented/2026-10-01-connector-settings-adapter.md`）。
- 包管理器钉 `pnpm@11.13.1`：connector 是独立 npm bundle、不是 DSH workspace 成员，与 DSH 根的补丁号一致买不到功能，钉一个本机真实存在的版本才能离线可复现（`.agents/notes/implemented/2026-10-01-connector-workspace-shape.md`）。

```yaml
# connector/cordis.patch.yml —— 全部接入样板就这 4 行
- insert:
    - id: dsh-mobile-connector
      name: 'dsh-mobile-connector'
      config: {}
```

**版本基线**：DSH 侧版本以 `connector/package.json` 的 `engines.dsh` 下界为准，取 npm 的 `next` dist-tag，不用 `latest`（后者落后于 `next`）。`@deepseek-ai/cordis` 与 `@deepseek-ai/schemastery` 各自取自己的版本。

**兼容性只看 `engines.dsh`**（`packages/boot/app-boot/src/plugin-compatibility.ts:57-61`）；只有缺它时才逐条比对 `@deepseek-ai/dsh*` peer（`:62-73`），匹配用 `semver.satisfies(..., { includePrerelease: true })`（`:51-53`）。不匹配的 bundle 被跳过并记入 `skippedBundles`（`profile.ts:687-712`）。上界写成 `<X.Y.Z-0`：`<X.Y.Z` 会放行整条预发布线，由 `connector/tests/manifest-compat.test.ts` 钉住。

宿主版本线是**多条并行**、窗口 N-1：每个 DSH minor 线各有一个兼容的插件版本，靠 npm 版本不可变 + 宿主逐版本判定共存。版本矩阵与抬线步骤见 [`cookbook/release.md`](../cookbook/release.md) §3，取舍见 `.agents/notes/implemented/2026-11-05-dual-track-host-version-lines.md`。

配置(Schemastery,`.volatile()` 的字段会进手机端通用表单):

| 字段 | 默认 | 说明 |
|---|---|---|
| `relayUrl` | 内置中转 `wss://dsh.0t0.me/ws/connector` | 中转地址(wss)。**电脑侧**这条是连接器拨的地址,路径由连接器自己拼(`base.pathname = '/ws/connector'`);二维码把它原样带出去,手机收到后规范成根地址(见 `app-channel-client.md` §6.2)。空着就是内置中转(读取处兜底 `relayUrlOrDefault()`,schema 默认值只管构造期),面板「连接」卡里可换成自部署地址 |
| `relayTokenRef` | — | 连接器令牌的凭据引用(本体走 `ctx.credentials`) |
| `listenPort` | 8790 | **直连拓扑**的监听端口;**默认开**(局域网直连是"中转不通时的唯一活路")。显式 `0` = 关(卡片里的「停用直连」写的就是它);端口被占只让这条通道停在未运行,不拦挂载 |
| `listenHost` | `0.0.0.0` | 监听地址。默认 `0.0.0.0`(手机才连得进来);要走 Tailscale 时显式写 tailnet 地址 |
| `pushDigest` | `'rich'` | `rich` / `doorbell` |
| `frameLimitBytes` | 8388608 | 单帧上限 |
| `refetchThresholdBytes` | 1048576 | 大对象阈值 |
| `windowFrames` / `windowMaxBytes` | 10000 / 16777216 | 增量缓冲上界 |

**设备数不设上限,这里也没有 `deviceLimit` 这类字段**:这是契约定的(`remote-channel.md` 规模标定表
「设备上限 | 不设上限」)。理由:每设备一把密钥 ⇒ 吊销粒度小;重新配对即新身份,记录随用户主动重配而增加,
清理走管理面。所以配对路径上**没有**"第 N 台拒绝"这个判据;一个只进手机端通用表单、却没人读的数
不该出现在 schema 里。取舍见 `.agents/notes/implemented/2026-10-29-drop-inert-device-limit.md`。

### 1.2 目录结构

```text
connector/
├── package.json  cordis.patch.yml  tsconfig.json
├── src/
│   ├── protocol/    帧与 AAD(§3)、密码学与握手(§4)、流控(§4.3)、恢复(§5.4)、itemId(§5.2)、幂等(§5.6)、错误码(§3.1)
│   ├── dsh/         薄适配层:只做映射,不重建语义(§2.2 适配表)
│   ├── transport/   出站 WSS:退避、心跳、半开、攒批、拨号接线;以及直连监听面(listener.ts,可选)。
│   │                 `backoff.ts` 是**零依赖的纯叶子**:`dsh/` 可以引它(§1.2 分层规则)
│   ├── store/       ctx.storage domain KV + schema 迁移(§1.4)
│   ├── push/        摘要生成与 60 s 合并,投递给中转
│   └── 根部         挂载级装配 / 每连接装配 / 配置 / 生命周期顺序引擎 / 日志与指标
└── tests/           跑 protocol/fixtures 与 protocol/vectors(与 Dart 侧同一批)
```

**逐文件清单不写在这里**:它是源码的投影,抄一遍必然漂移(本节就曾漏掉握手与别名两个模块)。层与职责是稳定信息,文件看 `src/` 本身。

分层规则(判据在 `connector/tests/layering.test.ts`,每条规则自带为什么与自检样本):

- `protocol/` 与 `store/` **不 import 任何 DSH 类型** —— 它们要能在纯 Node 下跑 fixtures;
- `dsh/` 可以引 `transport/`,**但目标必须是纯叶子**(那个模块自己不再 import 任何东西)。
  今天只有一个:`transport/backoff.ts`(退避计时,零 I/O、零依赖) —— `dsh/interaction-client.ts`
  用它重连 `$events` 流,而 `transport/connection.ts` 用的是**同一个事实**("多久重连一次"),
  复制一份才是两处表达。带依赖的模块(`connection.ts` / `relay-link.ts` / `listener.ts` …)
  **一次都不许引**:那会让适配层间接认识"socket 怎么开",而这条规则要挡的正是那个耦合。

这条规则 2026-11-12 之前写的是「`dsh/` 不 import `transport/`」, **从来没被机械执行过**,
而且当时就与 `transport/backoff.js` 那个 import 矛盾。定案(判据从"目录名"换成"目标有没有依赖")
与被否方案见 `.agents/notes/implemented/2026-11-12-doc-drift-three.md`。

### 1.3 生命周期

```text
mount
 ├─ 读配置 → 缺 relayUrl / 令牌只留声(都不拦挂载)
 ├─ store.open():迁移到当前 schema → 载入 devices / aliases / dedupe
 ├─ 发布服务 ctx.provide('dshMobileConnector', api)     ← 手机端能力门控读它
 ├─ 接 gateway 的 `$events` 转发流(owner client,见 §1.5)
 ├─ load-identity:取(或首次生成)本机身份种子(§12.1)
 ├─ 装每连接的活物:createConnectionScope(port, deps)(见下"装配分层")
 ├─ 通道注册表(transport/channels.ts):两条通道各自 start ——
 │   中转拨号(relay-link,自愈)+ 直连监听(仅当 listenPort 配置时)
 └─ 订阅策略:只为"手机已订阅的会话"建立 follow

dispose
 ├─ 断开 `$events` 流并停掉退避计时器 → 释放 in-process owner peer
 ├─ 停止接受新请求 → 等待在途请求(min(请求超时, 5 s))
 ├─ flush:缓冲落盘(不丢已 ack 的窗口)+ 去重表落盘
 ├─ 两条通道各自 stop:监听面停止接受 + 关闭已接受的连接;拨号发 close
 └─ store.close()
```

- **传输面按"方式"分开关**(`transport/channels.ts`,2026-10-17):每条通道有 id / 标签 / start / stop / running,管理面 `GET /api/dsh-mobile/transport` 列通道、`POST /api/dsh-mobile/transport/{id}/{start,stop}` 各停各的(**路由按注册表生成** —— 加第三种方式不改管理面与 UI 形状)。停一条不碰另一条:停拨号只关控制面与它的数据连接,停监听只关已接受的直连。批量启停是 UI 的顺序调用,不设服务端批量端点(两条各自的成败要能分别报回来)。

- **配置热改的后果只有两处判据**(`transport/rebuild.ts` 与 `transport/startup.ts`):前者由 `REBUILD_KEYS` 决定"哪些键变了重建哪条通道"(中转四格 `relayUrl` / `allowInsecureLocal` / `allowInsecurePublic` / `relayTokenRef`,直连两格 `listenPort` / `listenHost`;其余 volatile 字段改完下次读写自然生效,不重建),重建走**串行队列**(同一时刻只有一次停/起;失败落成保存回执里的 `relayError`,GET 视图不含错误格);后者决定"起传输时哪些缺席可容忍"—— 凭据里没有连接器令牌、`listenPort = 0`、`relayUrl` 空着三种,其余失败(坏地址 / 端口被占)整体抛出。两侧各有回归用例(`tests/transport-rebuild.test.ts` / `tests/transport-startup.test.ts`),装配层是否真的接上由 `tests/assembly-wiring.test.ts` 读源码盯;面板读取投影(`readConnectionState`)的每格判据在同一份用例里。
- **订阅是显式的**:`session.subscribe` 才建立 `follow`;`session.unsubscribe` 关闭它。不订阅 50 个会话(每个 follow 都是 DSH 侧的开销)。
- **基线快照用 `page()` 分页构造,不重开 `follow`**:`page()` 本身按消息对齐、有页预算、冷安全(`packages/api/session-controller/src/history.ts:77-112`),正好对应契约 §5.4 的 `cursor = "b:<beforeSeq>"`;重开 follow 会多建一个订阅并触发 promote 路径。
- **不读会话落盘文件**(格式为 v4 且仍在演进,见 `../channel-review-notes.md` §2.7):一律走服务层。

#### 装配分层:挂载级 vs 每连接

一次挂载可以有**多条连接**(直连拓扑下每条手机 socket 一条)。分界只有一条判据:
**构造物是否需要"往某一条连接里出帧"**。

| 层级 | 构造物 | 位置 |
|---|---|---|
| 挂载级(每挂载一份) | 配置与校验、`store.open()`、`ctx.provide('dshMobileConnector')`、交互客户端(owner peer + `$events` 流)、在途 claim 表、本机身份、会话与任务适配器、幂等表、配对核心、出码命令、**增量缓冲** | `src/index.ts` |
| 每连接(每条 socket 一份) | 入站帧处理、方法面与处理器表、会话订阅、任务输出订阅、翻页器、配对端点 | `src/connection-scope.ts` 的 `createConnectionScope(port, deps)` |

- **`deps` 全是挂载级的,`port` 是每连接唯一的输入**。窄端口的成员集合是 `ConnectionPort`(3 个):
  `send` / `whenWritable` / `state`。加第 4 个会被 `tests/connection-surface.test.ts` 拦下
  (扫源码断言恰好这 3 个)。
  v1 曾有第 4 个 `sendPairingFrame`(明文配对帧的收窄入口:不封箱、不盖 `fc`、握手期也能发);
  配对 v2 把它删了 —— `pair-commit` / `pair-result` 是受限握手**之后**的封箱帧,
  与业务帧走同一条 `send()`(§1.6、`pairing-v2.md` §2)。
- **每次连接的订阅断连即终止**(连接离开 `serving` 时);`connection-scope.ts` 的 `servingEnded`
  也作废该连接的已认证设备身份 —— 水位按设备记(§5.5),而身份只能来自握手。
- **增量缓冲是挂载级的**:它的存在理由是断线重连后按 `since` 接着收,跟着连接走会退化成每次灌快照;
  裁剪点是"全部配对设备水位的最小值"(`remote-channel.md` §5.5),而设备横跨连接。
  连接离开服务态**不**清缓冲 —— 未确认区间留到该设备重新确认,或超限转为"只走快照"
  (上界 10000 条 / 16 MiB)。

### 1.4 存储(`ctx.storage` domain KV)

**表结构的唯一出处是契约 §8.1**(`remote-channel.md`),本节只写**使用纪律**:

- schema 版本与迁移写在 `kv:meta.schema`;低于当前版本按**逐代**迁移升上来,不把兼容分支写进主路径;高于当前版本**拒绝启动**并报 `connector/unsupported`。
- **`meta.schema` 与 storage domain 自己的 `version` 是两个独立的号**:前者是我们的业务 schema,后者是 `defineDomain` 声明的**介质格式**版本(配 `compatibleVersions`,见 `packages/storage/storage-domain/src/spec.ts:35-72`)。混用会让迁移逻辑在介质格式变化时误判。
- 窗口帧**先入内存、后批量落盘**(每 500 ms 或每 64 帧一次);`lastPersisted` 与去重表**同步落盘** —— 它们决定正确性,滞后就会在崩溃后重放。
- **任何落盘失败都必须降级为「要求快照」**,而不是静默丢帧。
- **不使用** DSH 的会话落盘格式(v4 且仍在演进,见 `../channel-review-notes.md` §2.7)。

迁移规则:每次 `store.open()` 读 `meta.schema`;低版本按**逐代迁移**升到当前版本(不写兼容分支到主路径);高于当前版本则拒绝启动并报 `connector/unsupported`。

写入纪律:

- 窗口帧**先入内存、后批量落盘**(每 500 ms 或每 64 帧一次);`lastPersisted` 与去重表**同步落盘**(它们决定正确性)。
- 任何落盘失败都必须**降级为"要求快照"**而不是静默丢帧。

### 1.5 审批 / 提问的转发(owner client)

连接器**不在 host 的 waterfall 里注册应答者**。它建一个 in-process 的 owner peer,打开 gateway 的
`$events` 转发流,与浏览器标签页同一条路:

```ts
// 与契约 §6.2 一一对应;两个宿主键都可选(缺任一就不挂交互面)
const peer = ctx.get('connection').createPeer({ principal: { kind: 'owner' } })
const stream = await ctx.get('typertGateway').wireStream.open('$events', { args: {} }, uplink, peer, signal)
// ready { clientId } / waterfall { event, eventId, agentId, request } / cancel { eventId }
// → POST /api/$events/result { clientId, eventId, outcome }
```

- **没有"接管档位"**:手机连着就是 gateway 的一个 client,和浏览器完全一样,收到就参与。
  只有两种情况委托(回 `{kind:'next'}`):会话没登记给手机、或没有稳定身份(审批没有 `callId` /
  提问认不出唯一的 tool call)。委托是原生语义(只有所有投递都 next 之后才交还 Host),不是沉默。
  不想让手机参与就停掉传输通道(手机连不上 = 没有投递)。
- 参与之后:手机答了就回 `result`(审批只有 `allowed-once` / `rejected`,**绝不**出现"始终允许 /
  本次会话允许");桌面先答则收到 `cancel`,撤掉手机的在途 claim。**没有看护计时器** ——
  DSH 的审批没有超时(浏览器的卡也一直挂着),手机断开也不结算(claim 挂在 host 上,重连回来还能答)。

### 1.6 每设备数据连接与控制面

完整协议见 [首配 v2 与独立数据连接](pairing-v2.md)。

- 连接器用一条 `/ws/connector?id=<connectorId>` 控制连接接收设备上线/下线通知、重放名册。`?id=` **必带**且必须等于**令牌的 id**，否则 403（不一致时二维码里的 `pcId` 与中转眼里的 id 是两个值，而两端都不会报；不带就没有可核对的声明）。连接器 id 是随机 `pc-…`（`connector/src/connector-id.ts`，插件面板「连接」卡可见）；旧装的 `local` 在升级时强制迁移，已配对手机需重扫。**不做旧客户端兼容**：协议未发版，没有"不带 `?id=` 的连接器"。
- **一台中转可以服务多台电脑（多租户）**：连接器之间的边界是 `connectorId` —— 控制面按令牌认、数据面必须由票上的归属连接器来拨（`server.ts` 的 `attachData` 校验 `binding.connectorId === caller.id`）、通道按 `(connectorId, deviceId)` 键控；名册虽然按**设备 id**（不带租户前缀，正常由公钥派生不会撞）存，但 `register` 会**拒绝覆盖别人的行**（`device-registry.ts`）。唯一共享的资源是进程与带宽：没有按租户配额与计量，所以它是"可信用户共用一台"，不是"对外公共服务"。
- 每次手机连接获得独立的 `channelId`，电脑为它拨 `/ws/connector?dev=<deviceId>&channel=<channelId>`；中转同时校验连接器归属和当前代次。
- 配对候选也有独立数据连接，只允许受限配对；候选握手不能激活普通业务方法。
- 数据帧成对转发；不按 `sid` 广播，不按请求 `id` 解复用。连接、密钥、计数器、流控和订阅一同销毁重建。
- 推送摘要仍在电脑侧生成、合并；控制连接断开时关闭相关数据连接，双方退避后重新认证。
- **准入**（契约 §4.1）：握手收到 `hello`、设备有效之后即放行 —— 一台电脑可以**同时服务多台设备**，没有"被占用"这一档；已停用 / 已删除的行在 `peerOf` 处回 `protocol/not-paired`。
- 管理面设备行只有一格在线态 `online`；「停用」走既有的 `POST /devices/enabled {enabled:false}`。
- **撤销与清理分开**：活跃行只给「停用」，**删除只对已停用的行开放**（服务端对未停用的 `devIds` 整批拒绝，回 400「先停用再删除」）。理由：手机唯一能"知道被移除"的通道是换票 401 带原因，而行被硬删之后中转只剩 `device-unknown`（与"名册还没同步"不可区分）⇒ 那台手机只会一直重试。取舍见 `implemented/2026-10-30-revoke-then-purge.md`。
- **停用 / 删除会收掉那台设备已经建立的连接**（`admin/device-admin.ts` 的 `disconnect` → `Connection.stop()`）：只标 `revokedAt` 而不收连接，旧 socket 还在收发，那台手机会一直以为自己在线。按状态批量只对**真删掉**的那些收连接（在线被跳过的不踢）。
- **数据面的关闭码/理由原样转给另一端**（`relay/src/server.ts` 的 `observeData`，只转 3000–4999）：电脑侧在握手层拒绝时用 `4003 + 协议码`（码必须在封闭表里，理由的其余部分不塞说明）；中转若吞成默认的 `4000`，手机就只会退避重连 —— 撞门而没有结论。


### 1.7 直连监听面(可选,与中转并存)

契约 §14.6 的验收顺序是"先 Tailscale 直连跑通,再切中转复跑同一组用例",所以桥接要能**接受**连接,
而不只是拨号。两件事在实现上分开:

- **拨号**(`relayUrl`):桥接主动连中转。断开后**自愈**(退避重连)。
- **接受**(`listenPort`):手机直连桥接。**不自愈** —— 接受来的连接没有拨号目标,
  重新接受一条是监听面的职责;让它去拨 `relayUrl` 的症状是"监听模式下桥接莫名其妙连去中转"。

两者共用同一套**每连接装配**(`createConnectionScope`),所以"多设备"自然成立:每 accept 一条就装配一次。
`listenPort` 未配置或为 `0` 时**完全不监听**,行为与只有拨号时逐字一致。

**TLS 不在插件里终结。** 插件只监听明文 WS,由外部终结 TLS(Tailscale 用 `tailscale serve`,
自建则反向代理;与 §2.5 中转的部署口径一致)。三条理由:证书续期是部署侧的事、插件不该持有私钥、
且这样插件里**没有一条"跳过 TLS"的分支**可被误开。手机侧始终拨 `wss://`,契约 §2 的两跳都成立。

**为什么不去注册 DSH 自己的 web server**(2026-10-09 读过 `packages/host/webserver` 后的结论,
完整取舍见 `.agents/notes/implemented/2026-10-09-direct-listener-keeps-own-socket.md`):

DSH 的 `WebServer` 服务**允许插件注册升级路由**(`ctx.get('webServer').registerUpgrade({path, handler})`,
`packages/host/webserver/src/index.ts:349-355`;先例:`packages/experimental/inspector/src/host/plugin.ts:111`、
`packages/api/gateway/src/index.ts:249`)。但换过去要付三笔代价,本期都不值得:

1. **TLS 是监听器级的,插件碰不到** —— 由 DSH 启动参数 `--tls-cert` / `--tls-key` 决定
   (`packages/bundle/web-app/src/startup.ts:79-80`),开了就是**整个 3080 端口**(SPA + `/api` 桥 +
   我们这条路由)一起上 TLS;
2. **绑定地址也是监听器级的,且默认回环**(`packages/bundle/web-app/cordis.patch.yml:183`)——
   要让手机从 tailnet 连进来得显式 `--host <具体 IP>`,**那会把 DSH 的浏览器面一起暴露到那个网段**。
   现在的 `listener.ts` 只暴露我们自己一个端口,`listenHost` 还能由插件自己选,攻击面小一个量级;
3. **没有先例**:DSH 代码库里没有一个插件「在 upgrade handler 里完整实现一次 WebSocket 服务端握手」
   (inspector 是裸 pipe 到上游,gateway 用自己的 mux),我们的 `ws` + `noServer` 方案会是第一个。

另两条工程事实:upgrade 只支持**精确路径**(未命中直接 `socket.destroy()`,**没有 HTTP 错误码**),
重复路径**硬抛** `webserver: duplicate upgrade route`(`:350-352`),disposer 要插件自己收。

**什么时候该重新考虑**:当直连要成为**主路径**(不再走中转)、且使用者本来就在跑带 TLS 的
DSH web server 时。届时按上面三笔代价逐条复核对价。

监听面**不做应用层鉴权** —— 鉴权就是 §4.1 的握手本身:未配对的设备在 `hello` 处被拒
(`protocol/not-paired`)。这是有意的:在监听面上再加一层令牌,会得到两套"谁能连"的判据,
而它们迟早会不一致(且第二套没有契约依据)。

**升级请求的 URL 交给装配层**(`accept(UpgradeRequest)`):`?pair=<offerId>&cand=<候选>` 命中时
这条连接按**配对候选**建(`makeConnection({purpose:'pairing', candidate})`),没有 `pair` 就是已配对
设备的普通直连。判据仍是 `pairing.allows(candidate)` —— 过期/被新码顶掉的邀请在 `hello` 处被
`protocol/not-paired` 关掉。局域网配对因此不需要中转(`docs/subsystems/pairing-v2.md` §2、§4)。

---

## 2. 中转服务(`relay/`)

### 2.1 组件与接口

```text
relay/
├── src/
│   ├── http/                 # 配对、ticket、推送登记(Express/Fastify 皆可,建议 Fastify)
│   │   ├── pair.ts           #   POST /pair/begin, POST /pair/complete
│   │   ├── ticket.ts         #   POST /ws-ticket(一次性,60 s)
│   │   └── push.ts           #   POST /push/register, POST /push/dispatch
│   ├── ws/
│   │   ├── connector.ts      #   WSS /ws/connector
│   │   └── device.ts         #   WSS /ws/device
│   ├── window.ts             # 有界重放窗口(每会话 1000 条 / 30 min)
│   ├── auth.ts               # 令牌摘要校验、吊销、限流
│   └── store/                # SQL 迁移与仓储
└── deploy/                   # Dockerfile + compose(含反向代理 TLS)
```

### 2.2 数据表

见契约 §8.2。补充索引:`window(sid, seq)` 唯一;`devices(token_hash)` 唯一;`pairings(code_hash)` 唯一且 `expires_at` 有 TTL 清理任务。

### 2.3 不变量(必须可测)

- **中转代码里不得出现任何按事件内容分支的逻辑**——只按 `t` / `sid` / `seq` / `fc` 路由。
- 删掉 `window` 全部数据后重启,已配对设备重连必须仍能收敛(契约 §14.2 的回环用例就是这条的可执行判据)。
- 中转**不分配** `sid` / `seq` / `stream`;它只搬运。

### 2.4 限流、吊销与审计

| 面 | 策略 |
|---|---|
| 每身份请求 | **令牌桶**:容量 60、每秒补 6(默认值,可由配置 `rateLimit` 覆盖)。**按身份限流,不按 IP** —— 中转在反代之后时按 IP 会把所有客户端归成一个(一个人把大家限住)。**身份是"人"而不是"连接器"**:令牌条目配了 `owner` 就按 `user:<owner>` 分桶(同一人的三台电脑共用一个预算,否则多开一台电脑等于多领一个),没配才退回 `connector:<id>`。超限回 HTTP **429** + `retryAfterMs`(`null` 表示**不会自行恢复**,即零补充的硬配额) |
| 每设备连接 | 1 条(新连接顶掉旧连接:旧的那条以关闭码 4000 收口) |
| 每电脑连接 | 1 条(同上) |
| 配对尝试 | 走**同一套按身份限流**(配对请求本身已由设备令牌认证,所以那时有身份可用);配对码一次性 |
| WS 升级 | **与 HTTP 端点共用同一个桶**:升级比换票贵得多(长连 + 内存状态 + 一次握手),不共用的话换票被限住后转手刷升级即可绕过 |
| 帧速率 | **待定**:上线前按 §2.5 压测确定 —— 不许拿估算当结论(本表的默认值同理,它们只是"默认不敞开") |
| 按人流量额度 | **默认不限制**:计量一直在跑(面板看得到谁用了多少),上限是管理员在面板上给某个人设的(写回 `quota.owners`),`limit` 为 `null` 即"不限"。配置 `quota` 整段可省(`period` 默认 `month`、`enforce` 默认 `cut`、`defaultBytes` 不写 = 不限制)。主体是**人**:`owner`,没配退回 `connector:<id>`。**只算业务通道的双向帧**,配对候选不计量。用满时:`enforce: "cut"` 把这个人名下**所有**通道以 **4003 + `rate-limited quota`** 收口,之后换票与升级回 **429 + `retryAfterMs`**(月周期给到下一个 UTC 月边界);`"block"` 只挡新建、不踢已有;`"off"` 只记算。计数默认在内存,`persist: true` 才写 `statePath`(默认与配置同目录的 `relay.state.json`,原子替换、5 s 节流) |
| 吊销 | 令牌摘要**软吊销**(`revokedAt` 留行,重签即轮换):被吊销的令牌认证即失败(401)。**停用的行照样上报**(带 `revokedAt`,`rosterEntry`),中转据此回 `device-revoked` ⇒ 手机按 `revoked` 清这一台的凭据回配对页;**删除的行不再上报**,中转按差集丢掉它,那枚令牌只剩 `device-unknown`(与"名册还没重放"不可区分 ⇒ 手机持续重试,要区分得让名册带墓碑,属契约改动)。判据在 `relay/src/device-registry.ts` 的 `classify`,名册形状在 `http-face.ts` 的 `parseRegistrations`。真正"电脑不认这台设备"的终态信号仍是握手层的 `peerOf` 拒绝,以**关闭码 4003 + `protocol/not-paired`** 到达 |
| 审计 | 一行一个 **JSON 事件**(`relay/src/json-logger.ts`):`connector.open/close`、`roster.applied/refused`、`ticket.issued/rejected`、`channel.open/close`(带关闭码与理由)、`admission.rejected`、`delivery.failed`、`quota.rejected`、`limit.rejected`、`admin.action`、`auth.*`(注册/登录失败/发码/退出,不含邮箱与验证码)、`console.connector-*`(控制台建/停/删/重置绑定)。字段固定 `ts/level/evt` + owner/connectorId/deviceId/channelId/bytes/code/reason;单个字符串字段截到 512 字节。**不记**帧载荷、令牌、`tokenHash`、配对秘密(§12.2)。`debug` 级默认关(`DSH_RELAY_DEBUG=1` 打开);容器侧封顶 `10m × 3` 文件 |
| 管理面 | `GET /admin`(单文件内联的**独立控制台**:左侧分区导航 概览/用户/连接器/通道/用量/令牌/动态,2 s 轮询,跟随系统亮暗)与 `GET /admin/api/state`(读快照:在线连接器及其连接时长/最后心跳、活跃通道及已转发字节、按人额度、名册行数、令牌清单、**账号清单与策略摘要**、**近 60 分钟整台服务的转发字节序列**、**最近 100 条事件**(与日志同源、只含元数据)、进程已运行时长)。写操作:`POST /admin/api/quota`(改额度,**按人**写回配置或账号库)、`/admin/api/quota/reset`(重置用量)、`/admin/api/disconnect`(按连接器整条收掉,或按 `deviceId` 只收一条通道)、`/admin/api/tokens/revoke\|restore`(软吊销/恢复,吊销即下线)、`/admin/api/tokens/remove`(**硬删除,只对已吊销的开放**;活跃令牌回 409 `revoke-first`,与电脑侧"删除只对已停用的行开放"同一条规矩)、`/admin/api/users/status\|role\|limits`(账号停用/恢复/角色/电脑上限/额度)、`/admin/api/mail/test`、`/admin/api/tokens/issue`(管理员自己添加一台电脑:签发连接器令牌,**明文只在应答里出现一次**,配置只落摘要;同 id 已有活跃令牌回 409)。页面与用户控制台共用同一个反馈组件(`ui/kit.ts`:Toast + 页内弹框,遮罩与 Esc 都算取消并兑现 Promise;两个页面里**禁止** `alert`/`confirm`/`prompt`,由 `tests/ui-kit.test.ts` 拦)。管理面认证失败与登录页失败**共用一份按来源地址的连续失败计数**:连错 5 次锁 15 分钟,锁定期内连正确令牌也不放行,成功一次清零,到期自动放行(`lockout.ts`;配置 `lockout.failures: 0` 关闭)。凭据两种:配置里的 `admin`(只存 `sha256`,Bearer)或**管理员账号会话**(cookie + 双提交 CSRF);两者都没有时 `/admin*` 一律 404。认证不过的请求按来源地址分桶、通过的按 `admin:<id>` / `session:<userId>` 分桶。每个写操作留一条 `admin.action` 审计(actor/action/主体;**不含令牌**)。管理令牌用 `--issue-admin <id>` 签发(与连接器令牌同规格,明文只打印一次)。没接落盘时写操作回 501,读面照常 |

- **吊销/恢复在内存里立刻生效**（`relay/src/token-table.ts`）：摘要表不再是"启动时建死"，`revoke` 先摘认证索引再记 `revokedAt`，不重启、不波及其他连接。同一 `id` 在配置里出现两次会**拒绝启动**（吊销按 `id` 定位，重复即歧义）。轮换管理令牌仍要重启（`admin` 段只在装配时读一次）。
- **接受连接前再验一次**：`wss.handleUpgrade` 的回调是异步的，认证与回调之间可能刚好被吊销 —— 控制面与数据面各重验一次，认不出就 `close(4000, 'credential revoked')`。

### 2.5 连接器认证:必需 / 开放(可自助兑换)

配置两格,都由 owner 定,不预设人为上限:

| 字段 | 取值 | 默认 |
|---|---|---|
| `connectorAuth` | `open` = 连接器不带令牌也能连(中转当场签一张**普通**令牌);`required` = 只认管理员签发的令牌 | `open` |
| `autoEnrollLimit` | 自动签发总数上限:正整数;**`null`/不写 = 无上限** | 无上限 |

- **`POST /connector/enroll`**(HTTP 面,唯一不认证的业务路由):`{ "pcId": "<本机 id>", "name": "<电脑名,可选>" }` →
  `201 { token, connectorId: "auto-xxxxxxxx" }`;`403 connector-auth-required`(模式是 required);
  `429 auto-enroll-full`(名额用满,`limit` 非空才算);`429 rate-limited`(按来源地址分桶);
  `400 pcId-required`(不留匿名身份)。签发走 `issueToken` + `appendTokenToConfig`,条目带
  `source: "auto"`,**与手工令牌同一张摘要表** —— 认证、吊销、限流、名册、审计都只有一条路径。
- **账号模式(`auth` 段)把准入收成一条硬约束**:`connectorAuth` 必须是 `required`,匿名兑换关闭;
  连接器令牌由登录用户在 `/console` 创建,第一次连上时绑定 `?id=`。注册、会话、邮箱验证码、
  按账号限电脑数与月流量见 [中转账号与准入](relay-accounts.md)。**旧令牌不失效**;旧配置不写
  `auth` 段时,本节的开放/必需两格照旧。
- 名额只数 `source: "auto"` 且未吊销的条目:吊销一条就腾出一个名额。
- 装配面是 `RelayServerOptions.connectorEnroll`(`relay/src/server.ts`);不传 = 该路由一律 403。
  `/admin/api/state` 的 `connectorAuth` 字段暴露 `{ mode, limit, autoCount }` 供面板显示。
- 电脑侧 `relayTokenRef` **不再必填**:空着就在 `start-transport` 里调 `enrollConnector`
  (`connector/src/enroll.ts`)换一张,写进凭据格 `relay-connector`;`403` 时只记明确日志、不挡住挂载
  (否则面板打不开,用户没地方贴手工令牌)。

### 2.6 部署、成本与合规(上线前置)

- 部署:单容器 + 托管数据库;反向代理终结 TLS,WS 升级直通;健康检查 `/healthz`(读依赖就绪)。
- 容量**量级估算**(按契约 §10 参数推算,不是实测):心跳 20 B × 2 次/min ≈ 2.6 MB/月的空转流量/设备;连接内存按 100 KB/设备计,1 GB 内存约 1 万台空闲设备。**真实数字必须在上线前用压测确认**(空闲连接数、转发吞吐、窗口内存)。
- 合规:中国大陆自建中转需 **ICP 备案**(域名 + 服务器);元数据仍属个人信息(履行 PIPL 告知与最小化义务);推送另需各厂商账号、模板与分类报备。
- 不接个推(按日联网设备数月峰值预付,≤1 万设备即 3000 元/月);极光可作鸿蒙候选,但数据面仍走 Push Kit,绕不过频控。

---

## 3. 测试策略

| 层 | 怎么测 | 何时跑 |
|---|---|---|
| 语义(协议) | `node protocol/verify-fixtures.mjs`(两侧各跑同一批) | 每次改 `protocol/` 或 `src/protocol/` |
| 接线 | `node protocol/verify-loopback.mjs`(含中转清空重启 + 强制走桥接分支) | 同上 |
| 跨端密码学 | `protocol/vectors/` 的已知答案向量,TS 与 Dart 双侧 | 每次改 `crypto.ts` |
| 适配层 | 对着真实 DSH 实例跑"发一句/回一句 + 四类交互" | 里程碑 4/7 |
| 中转 | 压测(空闲连接、转发吞吐、窗口内存)+ 限流与吊销用例 | 里程碑 12 |

**变异校验**:改断言时必须破坏一条不变量确认变红;两条已知基线与补法见 `remote-channel.md` §14.3。

---

## 4. 里程碑与验收

| # | 交付 | 验收 |
|---|---|---|
| 1 | `protocol/` 扩展(前 7 条 fixture + 向量 + 参考实现) | `verify-fixtures` / `verify-loopback` / 向量 全绿 |
| 2 | `connector/` 骨架(工程形态 + store + 空协议层) | 装进 profile 后 `dsh plugin list` 可见,未跳过 |
| 3 | `protocol/` ↔ `connector/src/protocol` 对齐 | fixtures 在 connector 侧跑绿 |
| 4 | 真机连通(Tailscale 直连) | 发一句 / 回一句。**前置:监听面(§1.7,已完成)+ 手机端整条链**——没有 App 就没有东西能发起握手 |
| 5 | 会话只读(列表 / 对话 / 轨迹) | 手机看到与桌面一致 |
| 6 | 可操作(发消息 / 打断 / 插话) | 幂等重发不产生第二条 |
| 7 | 交互(审批 / 提问 / 计划审查)+ 仲裁三档 | 三档行为与契约 §6.2 一致 |
| 8 | 任务面板 + 输出订阅 | 停止两段式、结算后裁剪行为符合 §15 |
| 9 | 推送四类 + 回前台补课 | 强杀后点通知进入即正确 |
| 10 | `relay/` 产品化(配对 / 限流 / 吊销 / 审计) | 回环用例在真实中转发下复跑 |
| 11 | 三端专属表达(iOS Live Activity / 安卓通知操作 / 鸿蒙关键节点) | 真机验收 |
| 12 | 鸿蒙目标(锁 3.41 线,当前稳定 tag `3.41.10-ohos-1.0.1`,2026-08-17) | 三方库适配与 §13 清单过一遍 |
