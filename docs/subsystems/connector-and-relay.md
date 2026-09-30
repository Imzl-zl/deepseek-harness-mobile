# 电脑侧桥接与中转:落地设计

契约见 `remote-channel.md`(本文件只写"怎么落",不重复协议定义)。参考实现对照:`C:\sudy\github\Agents-Anywhere\dsh-bridge-next`(只读)。

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
  "packageManager": "pnpm@11.7.0",
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
    "@deepseek-ai/dsh-jobs": "0.2.0-rc.2",
    "@deepseek-ai/dsh-storage": "0.2.0-rc.2",
    "@deepseek-ai/dsh-user-approval": "0.2.0-rc.2",
    "@deepseek-ai/dsh-user-questions": "0.2.0-rc.2"
    // …按需追加;DSH 各包是已发布的 npm 包,用它们做类型检查,不必对着源码
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

**版本基线(2026-09-30 核实)**:DSH 仓库根为 `@deepseek-ai/dsh-root@0.2.0-rc.2`,对应公共 npm 上 `@deepseek-ai/dsh-*` 的 **`next` dist-tag = `0.2.0-rc.2`**。**不要用 `latest`**——它落后很多(例如 `@deepseek-ai/dsh-jobs` 的 latest 是 `0.0.1-rc.3`、`@deepseek-ai/dsh-api-session-controller` 是 `0.1.2-alpha.2`)。`@deepseek-ai/cordis` 与 `@deepseek-ai/schemastery` 用 `latest`(4.0.4 / 3.18.4)。包管理器与 DSH 一致:`pnpm@11.7.0`。

**兼容性只看 `peerDependencies`**(`packages/boot/app-boot/src/plugin-compatibility.ts:68`);不匹配会被静默跳过并记入 `skippedBundles`(`profile.ts:675-681`)。写 `engines.dsh` 没有任何效果(`packages/util/package-manifest/README.md:93`)。peer 用**精确版本**(照参考插件),DSH 升级时要同步改;peer 的比较语义未逐行核实,第一次装进 profile 时按 §4 里程碑 2 确认。

配置(Schemastery,`.volatile()` 的字段会进手机端通用表单):

| 字段 | 默认 | 说明 |
|---|---|---|
| `relayUrl` | — | 中转地址(wss) |
| `relayTokenRef` | — | 连接器令牌的凭据引用(本体走 `ctx.credentials`) |
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
│   ├── index.ts              # 插件入口:装配、发布服务、dispose
│   ├── config.ts             # Schemastery 配置(上表)
│   ├── protocol/             # ← 与 protocol/fixtures 一一对应,无 DSH 依赖
│   │   ├── frame.ts          #   帧编解码 + AAD 规范化(§3)
│   │   ├── crypto.ts         #   握手、HKDF、AEAD、fc 计数器(§4)
│   │   ├── flow.ts           #   流控窗口(§4.3)
│   │   ├── recovery.ts       #   恢复判定与快照分页(§5.4)
│   │   ├── items.ts          #   itemId 推导与 upsert(§5.2)
│   │   ├── dedupe.ts         #   幂等表(§5.6)
│   │   └── errors.ts         #   封闭错误码(§3.1)
│   ├── dsh/                  # 薄适配层:只做映射,不重建语义
│   │   ├── sessions.ts       #   follow / page / prompt / cancel + seq→条目
│   │   ├── interactions.ts   #   approval / userQuestions(claim-or-delegate)
│   │   ├── jobs.ts           #   ctx.jobs 投影(按 owner 过滤)
│   │   ├── subagents.ts      #   listChildren / listDescendants
│   │   ├── settings.ts       #   settings.* / credentials.*(单向写面)
│   │   └── caps.ts           #   能力门控(服务是否存在)
│   ├── transport/            # 出站 WSS:退避、心跳、半开检测、批量合并
│   ├── store/                # ctx.storage domain KV + schema 迁移(§1.4)
│   ├── push/                 # 摘要生成与 60 s 合并,投递给中转
│   └── observability.ts      # 结构化日志 + 指标
└── tests/
    ├── fixtures.test.ts      # 跑 protocol/fixtures(与 Dart 侧同一批)
    └── vectors.test.ts       # 跑 protocol/vectors(跨端互操作)
```

分层规则:`protocol/` 与 `store/` 不 import 任何 DSH 类型;`dsh/` 不 import `transport/`。依赖方向单向向下,便于`protocol/` 在纯 Node 下跑 fixtures。

### 1.3 生命周期

```text
mount
 ├─ 读配置 → 校验 relayUrl / 令牌存在
 ├─ store.open():迁移到当前 schema → 载入 devices / aliases / dedupe
 ├─ 发布服务 ctx.provide('dshMobileConnector', api)     ← 手机端能力门控读它
 ├─ 注册 answerer(TakeoverGate 判定,见 §1.5)
 ├─ transport.start():出站连接(退避)→ 握手 → serving
 └─ 订阅策略:只为"手机已订阅的会话"建立 follow

dispose
 ├─ 停止接受新请求 → 等待在途请求(min(请求超时, 5 s))
 ├─ flush:缓冲落盘(不丢已 ack 的窗口)+ 去重表落盘
 ├─ transport.stop():发 close,关闭 WS
 └─ store.close()
```

- **订阅是显式的**:`session.subscribe` 才建立 `follow`;`session.unsubscribe` 关闭它。不订阅 50 个会话(每个 follow 都是 DSH 侧的开销)。
- **基线快照用 `page()` 分页构造,不重开 `follow`**:`page()` 本身按消息对齐、有页预算、冷安全(`packages/api/session-controller/src/history.ts:77-112`),正好对应契约 §5.4 的 `cursor = "b:<beforeSeq>"`;重开 follow 会多建一个订阅并触发 promote 路径。
- **不读会话落盘文件**(格式为 v4 且仍在演进,见 `../channel-review-notes.md` §2.7):一律走服务层。

### 1.4 存储(`ctx.storage` domain KV)

```text
kv:meta      { schema: 1, connectorId, relayUrl, aliasVersion }
kv:devices   { devId: { edPub, dhPub, name, pairedAt, revokedAt? } }
kv:aliases   { bySid: {sid→dshSessionId}, bySession: {dshSessionId→sid} }
kv:dedupe    { requestId: { at, status, resultRef } }          // 10000 / TTL 24h
kv:windows   { sid: { frames: [...], trimmedUpto, lastPersisted } }  // 16 MiB / 10000
kv:takeover  { devId: { mode, lastInteractedAt } }
```

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

### 1.6 中转交互与推送

- 桥接 → 中转:`wss /ws/connector`,连接器令牌鉴权;推送投递用 `POST /push/dispatch`(桥接只送**摘要**,不送内容)。
- 摘要生成在电脑侧、合并也在电脑侧(同会话同类型 60 s 折叠);中转看不懂内容。
- 中转不可达时:桥接保持退避重连,业务不受影响(手机也连不上,双向都不通)。

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
| 每设备请求 | 100 req/min,突发 20;超限 `rate-limited` |
| 每设备连接 | 1 条(新连接顶掉旧连接并通知手机) |
| 每电脑连接 | 1 条(同上) |
| 配对尝试 | 每 IP 10 次/小时;配对码一次性 |
| 帧速率 | 每设备 2000 帧/min(超出暂停转发并记审计) |
| 吊销 | `devices.revoked_at` 置位 → 下一条帧回 `protocol/revoked` 并断开 |
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
| 4 | 真机连通(Tailscale 直连) | 发一句 / 回一句 |
| 5 | 会话只读(列表 / 对话 / 轨迹) | 手机看到与桌面一致 |
| 6 | 可操作(发消息 / 打断 / 插话) | 幂等重发不产生第二条 |
| 7 | 交互(审批 / 提问 / 计划审查)+ 仲裁三档 | 三档行为与契约 §6.2 一致 |
| 8 | 任务面板 + 输出订阅 | 停止两段式、结算后裁剪行为符合 §15 |
| 9 | 推送四类 + 回前台补课 | 强杀后点通知进入即正确 |
| 10 | `relay/` 产品化(配对 / 限流 / 吊销 / 审计) | 回环用例在真实中转发下复跑 |
| 11 | 三端专属表达(iOS Live Activity / 安卓通知操作 / 鸿蒙关键节点) | 真机验收 |
| 12 | 鸿蒙目标(锁 `3.41.10-ohos-X.X.X`) | 三方库适配与 §13 清单过一遍 |
