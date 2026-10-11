# 电脑侧桥接与中转:落地设计

契约见 `remote-channel.md`(本文件只写"怎么落",不重复协议定义)。参考实现对照:`D:\sudy\github\Agents-Anywhere\dsh-bridge-next`(只读)。

---

## 1. 电脑侧桥接(DSH 插件 `connector/`)

### 1.1 形态与工程配置

必须是 npm bundle(声明 `dsh.bundle.patch`),装进目标 profile 的 `node_modules`;不能是动态 Cordis 包(沙箱 trap 掉 `fetch` / `setInterval` / `require`)。

```jsonc
// connector/package.json(照参考插件的形状)
{
  "name": "@dsh-mobile/connector",
  "version": "0.1.0",
  "type": "module",
  "packageManager": "pnpm@11.13.0",
  "main": "./lib/index.js",
  "files": ["lib", "cordis.patch.yml", "README.md"],
  "dsh": { "bundle": { "patch": "./cordis.patch.yml" } },
  "peerDependencies": {
    "@deepseek-ai/cordis": "4.0.4",
    "@deepseek-ai/dsh-typert-protocol": "0.2.0-rc.2",
    "@deepseek-ai/schemastery": "3.18.4"
  },
  "devDependencies": {
    "@deepseek-ai/dsh-agent": "0.2.0-rc.2",
    "@deepseek-ai/dsh-api-session-controller": "0.2.0-rc.2",
    "@deepseek-ai/dsh-credentials": "0.2.0-rc.2",
    "@deepseek-ai/dsh-jobs": "0.2.0-rc.2",
    "@deepseek-ai/dsh-settings": "0.2.0-rc.2",
    "@deepseek-ai/dsh-storage": "0.2.0-rc.2",
    "@deepseek-ai/dsh-storage-domain": "0.2.0-rc.2",
    "@deepseek-ai/dsh-subagent": "0.2.0-rc.2",
    "@deepseek-ai/dsh-user-approval": "0.2.0-rc.2",
    "@deepseek-ai/dsh-user-questions": "0.2.0-rc.2"
    // 这十个只用于类型检查(DSH 各包已发布到 npm,不必对着源码)。
    // `dsh-settings` / `dsh-credentials` 不是可选的:适配层靠它们的类型钉住
    // `describe({ redactSecrets: true })` 这个选项名,见
    // .agents/notes/implemented/2026-10-01-connector-settings-adapter.md
  },
  "dependencies": {
    // 本插件**唯一**的运行时依赖。监听面要一个 WS 服务端,而 Node 22 的全局
    // `WebSocket` 只有客户端(没有服务端实现)。`ws` 是纯 JS、无原生依赖。
    // 它只在 `listenPort` 配置时才被 import —— 见 .agents/notes/implemented/2026-10-02-listener-face.md
    "ws": "8.18.3"
  },
  "engines": { "node": "^22.19.0 || >=24.0.0" }
}
```

```yaml
# connector/cordis.patch.yml —— 全部接入样板就这 4 行
- insert:
    - id: dsh-mobile-connector
      name: '@dsh-mobile/connector'
      config: {}
```

**版本基线(2026-10-01 复核)**:DSH 仓库根为 `@deepseek-ai/dsh-root@0.2.0-rc.2`,对应公共 npm 上 `@deepseek-ai/dsh-*` 的 **`next` dist-tag = `0.2.0-rc.2`**。**不要用 `latest`**——它落后很多(实测:`@deepseek-ai/dsh-jobs` 的 latest 是 `0.0.1-rc.3`、`dsh-api-session-controller` 是 `0.1.2-alpha.2`、`dsh-typert-protocol` 是 `0.1.0-rc.6`,而三者的 `next` 都是 `0.2.0-rc.2`)。`@deepseek-ai/cordis` 与 `@deepseek-ai/schemastery` 用 `latest`(4.0.4 / 3.18.4)。包管理器钉 **`pnpm@11.13.0`**:connector 是独立 npm bundle、不是 DSH workspace 成员,与 DSH 根的补丁号一致买不到功能,钉一个本机真实存在的版本才能离线可复现。取舍见 `.agents/notes/implemented/2026-10-01-connector-workspace-shape.md`。

**兼容性只看 `peerDependencies`**(`packages/boot/app-boot/src/plugin-compatibility.ts:68`);不匹配会被静默跳过并记入 `skippedBundles`(`profile.ts:675-681`)。写 `engines.dsh` 没有任何效果(`packages/util/package-manifest/README.md:93`)。peer 用**精确版本**(照参考插件),DSH 升级时要同步改;peer 的比较语义未逐行核实,第一次装进 profile 时按 §4 里程碑 2 确认。

配置(Schemastery,`.volatile()` 的字段会进手机端通用表单):

| 字段 | 默认 | 说明 |
|---|---|---|
| `relayUrl` | — | 中转地址(wss) |
| `relayTokenRef` | — | 连接器令牌的凭据引用(本体走 `ctx.credentials`) |
| `listenPort` | 0(不监听) | **直连拓扑**的监听端口;`0` = 关(只走中转,行为与不监听完全一致) |
| `listenHost` | `127.0.0.1` | 监听地址。直连要走 Tailscale 时显式写 tailnet 地址;默认只在本机 |
| `deviceLimit` | 8 | 允许配对的设备数 |
| `approvalTakeover` | `'foreground'` | `never` / `foreground` / `always`(契约 §6.2) |
| `approvalWatchdogMin` | 10 | 看护超时(分钟) |
| `pushDigest` | `'rich'` | `rich` / `doorbell` |
| `frameLimitBytes` | 8388608 | 单帧上限 |
| `refetchThresholdBytes` | 1048576 | 大对象阈值 |
| `windowFrames` / `windowMaxBytes` | 10000 / 16777216 | 增量缓冲上界 |

### 1.2 目录结构

```text
connector/
├── package.json  cordis.patch.yml  tsconfig.json
├── src/
│   ├── protocol/    帧与 AAD(§3)、密码学与握手(§4)、流控(§4.3)、恢复(§5.4)、itemId(§5.2)、幂等(§5.6)、错误码(§3.1)
│   ├── dsh/         薄适配层:只做映射,不重建语义(§2.2 适配表)
│   ├── transport/   出站 WSS:退避、心跳、半开、攒批、拨号接线;以及直连监听面(listener.ts,可选)
│   ├── store/       ctx.storage domain KV + schema 迁移(§1.4)
│   ├── push/        摘要生成与 60 s 合并,投递给中转
│   └── 根部         挂载级装配 / 每连接装配 / 配置 / 生命周期顺序引擎 / 日志与指标
└── tests/           跑 protocol/fixtures 与 protocol/vectors(与 Dart 侧同一批)
```

**逐文件清单不写在这里**:它是源码的投影,抄一遍必然漂移(本节就曾漏掉握手与别名两个模块)。层与职责是稳定信息,文件看 `src/` 本身。

分层规则:`protocol/` 与 `store/` 不 import 任何 DSH 类型;`dsh/` 不 import `transport/`。依赖方向单向向下,便于`protocol/` 在纯 Node 下跑 fixtures。

### 1.3 生命周期

```text
mount
 ├─ 读配置 → 校验 relayUrl / 令牌存在
 ├─ store.open():迁移到当前 schema → 载入 devices / aliases / dedupe
 ├─ 发布服务 ctx.provide('dshMobileConnector', api)     ← 手机端能力门控读它
 ├─ 注册 answerer(TakeoverGate 判定,见 §1.5)
 ├─ load-identity:取(或首次生成)本机身份种子(§12.1)
 ├─ 装每连接的活物:createConnectionScope(port, deps)(见下"装配分层")
 ├─ transport.start():出站连接(退避)→ 握手(§4.1 三帧)→ serving
 ├─ 监听面(仅当 listenPort 配置时):每 accept 一条就装配一次,交给 attach(socket)
 └─ 订阅策略:只为"手机已订阅的会话"建立 follow

dispose
 ├─ 停止接受新请求 → 等待在途请求(min(请求超时, 5 s))
 ├─ flush:缓冲落盘(不丢已 ack 的窗口)+ 去重表落盘
 ├─ 监听面停止接受 + 关闭已接受的连接
 ├─ transport.stop():发 close,关闭 WS
 └─ store.close()
```

- **订阅是显式的**:`session.subscribe` 才建立 `follow`;`session.unsubscribe` 关闭它。不订阅 50 个会话(每个 follow 都是 DSH 侧的开销)。
- **基线快照用 `page()` 分页构造,不重开 `follow`**:`page()` 本身按消息对齐、有页预算、冷安全(`packages/api/session-controller/src/history.ts:77-112`),正好对应契约 §5.4 的 `cursor = "b:<beforeSeq>"`;重开 follow 会多建一个订阅并触发 promote 路径。
- **不读会话落盘文件**(格式为 v4 且仍在演进,见 `../channel-review-notes.md` §2.7):一律走服务层。

#### 装配分层:挂载级 vs 每连接

一次挂载可以有**多条连接**(直连拓扑下每条手机 socket 一条)。分界只有一条判据:
**构造物是否需要"往某一条连接里出帧"**。

| 层级 | 构造物 | 位置 |
|---|---|---|
| 挂载级(每挂载一份) | 配置与校验、`store.open()`、`ctx.provide('dshMobileConnector')`、answerer 注册、本机身份、会话与任务适配器、幂等表、配对核心、出码命令、**增量缓冲** | `src/index.ts` |
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

### 1.5 审批接管(TakeoverGate)

```ts
// 与契约 §6.2 一一对应;判定输入全部来自已认证设备的上报
function shouldClaim(req: ApprovalRequestEvent, state: TakeoverState): boolean {
  const mode = state.deviceModeOf(mostRecentForegroundDevice())   // 只看前台设备
  if (mode === 'never') return false
  if (mode === 'always') return state.onlineDevices().length > 0
  return state.foregroundSubscribersOf(req.agent.session.id).length > 0   // 默认档
}
```

- 并列设备按"最近与该会话交互"→"配对最早"排序(确定性,便于测试)。
- claim 后启动看护计时器;超时 / 断开 / 会话被替换 → 返回 `'unavailable'`(fail-closed)并推通知。
- **绝不**出现"始终允许 / 本次会话允许":DSH 只认 `'allowed-once' | 'rejected'`。

### 1.6 每设备数据连接与控制面

完整协议见 [首配 v2 与独立数据连接](pairing-v2.md)。

- 连接器用一条 `/ws/connector` 控制连接接收设备上线/下线通知、重放名册。
- 每次手机连接获得独立的 `channelId`，电脑为它拨 `/ws/connector?dev=<deviceId>&channel=<channelId>`；中转同时校验连接器归属和当前代次。
- 配对候选也有独立数据连接，只允许受限配对；候选握手不能激活普通业务方法。
- 数据帧成对转发；不按 `sid` 广播，不按请求 `id` 解复用。连接、密钥、计数器、流控和订阅一同销毁重建。
- 推送摘要仍在电脑侧生成、合并；控制连接断开时关闭相关数据连接，双方退避后重新认证。


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

监听面**不做应用层鉴权** —— 鉴权就是 §4.1 的握手本身:未配对的设备在 `hello` 处被拒
(`protocol/not-paired`)。这是有意的:在监听面上再加一层令牌,会得到两套"谁能连"的判据,
而它们迟早会不一致(且第二套没有契约依据)。

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
| 每身份请求 | **令牌桶**:容量 60、每秒补 6(默认值,可由配置 `rateLimit` 覆盖)。**按身份限流,不按 IP** —— 中转在反代之后时按 IP 会把所有客户端归成一个(一个人把大家限住)。超限回 HTTP **429** + `retryAfterMs`(`null` 表示**不会自行恢复**,即零补充的硬配额) |
| 每设备连接 | 1 条(新连接顶掉旧连接:旧的那条以关闭码 4000 收口) |
| 每电脑连接 | 1 条(同上) |
| 配对尝试 | 走**同一套按身份限流**(配对请求本身已由设备令牌认证,所以那时有身份可用);配对码一次性 |
| WS 升级 | **与 HTTP 端点共用同一个桶**:升级比换票贵得多(长连 + 内存状态 + 一次握手),不共用的话换票被限住后转手刷升级即可绕过 |
| 帧速率 | **待定**:上线前按 §2.5 压测确定 —— 不许拿估算当结论(本表的默认值同理,它们只是"默认不敞开") |
| 吊销 | 令牌摘要**软吊销**(`revokedAt` 留行,重签即轮换):被吊销的令牌认证即失败(401);设备侧握手引用到已吊销设备时,由**电脑侧**回 `protocol/revoked` |
| 审计 | 连接建立/断开、配对、吊销、限流命中;只记元数据,不记内容 |

### 2.5 部署、成本与合规(上线前置)

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
