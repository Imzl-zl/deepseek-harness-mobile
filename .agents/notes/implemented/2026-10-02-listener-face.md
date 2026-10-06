# Agent Note: 监听面不是"多开一个端口"——它先逼出三个决定，其中一个修掉了既有的静默 bug

Status: implemented（2026-10-02 落地：`connector/src/transport/listener.ts` + `config.ts` + `index.ts`）

## Problem

### 一、三个岔口一直没有定夺，所以监听面一直没写

`proposed/2026-10-01-listener-forces-per-connection-state.md` 把前置问题定成"两个必须先定的事实"
（`ws` 依赖 + 单槽 `connection`），并停在那里。随后 `2026-10-01-per-connection-scope-is-an-extraction.md`
把第二件事解决了（每连接装配抽成 `createConnectionScope(port, deps)`，实测只有 4 个成员），
于是**只剩 `ws` 那个决定**。本轮定了它，监听面才落得下来。

### 二、写之前先量：`attach()` 少了两个定时器（既有 bug，不是新代码的 bug）

监听面本身只是"接 WSS 并交给 `attach`"，所以先照 `proposed/` 的说法读了一遍 `attach()`
（`transport/connection.ts:579`）。读出来的是：它重置了分帧器、计数器、密码器、窗口、握手状态，
**但没有起 `scheduleTick()` / `scheduleFlush()`** —— 那两个周期任务只在 `start()` 里起
（`:664-665`）。而 `connection-accept.test.ts` 原来只验了两件事（已打开的 socket 直接进握手、
断开后不拨号），**没有一条会碰到定时器**，所以这个缺口一直没有变红。

先复现再改（临时用例，已删）：接受一条 socket、`markHandshakeDone()`、`send({t:'ev'})`
→ `send()` 回 `true`，客户端**一行都没收到**。两种后果都是静默的：

- **可攒批的帧永远发不出去**：`ev` / `live` / `job` 进了 batcher 就再没人 flush
  （`send()` 照样回 `true`，所以调用方以为发出去了）；
- **半开永远判不出来**：`keepalive.tick()` 不被调用 ⇒ 连接死了也不收口。

这一条如果留到监听面落地之后才暴露，症状会是"直连连上了、握手也过了，但事件一条都收不到" ——
与 `attach` 的另外两处（"连上了但什么都不发生"、"莫名其妙连去中转"）属于同一类最难查的故障。

## Decision

**把"要不要监听"与"监听在哪"分成两层，并把 `attach()` 的定时器补上。**

1. **装配层判断要不要监听**：`config.ts` 的 `listenPort` 默认 `0`，`index.ts` 里
   `if (listenPort !== 0)` 才调 `startListener`。于是"没配"与"不监听"是同一件事。
2. **监听面自己收 `port: 0` 表示"由系统分配"**（不是"不监听"）：这样测试能要一个临时端口。
   把两种语义挤进同一个 `0`，会让 `startListener` 没法被单测直接用。
3. **`attach()` 与 `start()` 共用 `startTimers()`**（幂等：重复 `attach` 会先取消旧的定时器）。
4. **`ws` 进 `dependencies`**（本插件第一个运行时依赖）。
5. **TLS 不在插件里终结**，由外部（Tailscale `tailscale serve` / 反向代理）终结。
6. **监听面不做应用层鉴权**：鉴权就是 §4.1 的握手本身。

准入门槛（可机械判定）：

1. **默认关**：`tests/listener-config.test.ts` 断言 `listenPort` 的默认值是 `0` 且
   `listenHost` 默认 `127.0.0.1`（变异校验：把默认值改成 `8787` → 1 项红）。
2. **接受路径的两个定时器都在**：`tests/connection-accept.test.ts` 断言"可攒批的帧真的出线"
   与"半开判得出来"（变异校验：`startTimers` 改成空操作 → 4 项红）。
3. **每 accept 一条装配一次**：`tests/listener.test.ts` 断言两条连接不串台
   （A 的 `pong` 不出现在 B 的线上）。
4. **真握手 + 真 AEAD 双向**：手机替身（`support/phone.ts`，独立实现）直连监听面走完三帧，
   然后 `req` 上行、`res` 下行，两侧各自用自己的密钥解 —— 且**断言解出来的内容**
   （`{ ok, result }` 信封里的 `protocol` / `caps`），不只是"能解开"。
5. **未配对的设备在 `hello` 处被拒**：关闭码 `4003`（`protocol/not-paired`）。
6. **卸载收口**：`listener.close()` 后 `active === 0`，客户端收到 close。
7. **产物形态**：`lib/index.js` 里 `ws` 是 `import { WebSocketServer } from "ws"`（外部化），
   且 `node -e "import('./lib/index.js')"` 能加载出 `apply` / `Config`。

## Alternatives considered

1. **把 `ws` 留在 devDependencies，只在测试/开发模式下启用监听**
   - 最强的理由：不引运行时依赖，插件继续保持"零 runtime dep"这个很值钱的属性。
   - 为何被否：那等于"真机直连不是产品能力"。契约 §14.6 的验收顺序是**先 Tailscale 直连跑通、
     再切中转复跑同一组用例**，而 Node 22 的全局 `WebSocket` 只有客户端（没有服务端实现）——
     自己实现 WS 握手与分帧不必讨论。两条路都堵死时，这个选项就不成立了。
2. **单活动连接：新 socket 进来就踢掉旧的**
   - 最强的理由：改动最小，`currentDeviceId` 这个单值也不会失真。
   - 为何被否：`per-connection-scope` 那篇已经否过一次，理由在这里更硬 —— §5.5 的裁剪点是
     "**全部配对设备**水位的最小值"，退化成"最后一条连接确认就裁"是**丢事件的方向**。
     而且每连接装配已经抽好了，"多设备"现在是免费的。
3. **监听面自己也做一层令牌鉴权**
   - 最强的理由：纵深防御；端口暴露在 tailnet 上时，多一层门槛看起来更稳。
   - 为何被否：会得到**两套"谁能连"的判据**（监听面的令牌 + 握手里的设备表），
     而它们迟早不一致 —— 更糟的是第二套没有契约依据，改一处会漏另一处。
     握手本身就是鉴权（未配对 → `protocol/not-paired`），这也是唯一与中转路径同构的做法。
4. **插件里终结 TLS（配置里放证书路径）**
   - 最强的理由：部署更省事，一个进程搞定。
   - 为何被否：证书续期是部署侧的事，插件不该持有私钥；更关键的是那样会引入
     **一条"跳过 TLS"的分支**（自签/明文开关），而它一旦被误开就是明文上线。
     与 §2.5 中转"反向代理终结 TLS"同一条口径。
5. **顺手把去重噪音改成"真的按会话去重"（订阅面上做）**
   - 最强的理由：`per-connection-scope` 那篇的代价段写的就是"需要在订阅面上做会话级去重"，
     照它做看起来是完成未尽事项。
   - 为何被否：读代码后判断**不需要新机制**。两条连接各自 `follow` 同一会话是正常形态
     （每台设备从自己的水位订阅），而缓冲本来就只该留一份 —— 它拒绝重复是**对的**。
     真正的问题只是它用 `warn` 播报一件正常的事，于是每台设备每批事件刷一行、把真告警淹掉。
     所以改的是**日志级别**（`warn` → `debug`），不是加一层去重表。
     教训与 `per-connection-scope` 那篇同一条：**清单是上一轮的判断，理由在代码里**。

## Consequences

- 收益：直连拓扑可用了（契约 §14.6 第一跳的代码侧前置就位）；`attach()` 的两个静默缺口被补上，
  而且现在有两条断言盯着（此前三条断言全都碰不到定时器）。
- 收益：`index.ts` 的 `start-transport` 变成"建挂载级依赖 → 建工厂 → 拨号 + 起监听"，
  两条路径共用同一个 `makeConnection` —— 接受路径的 `dial` 是**抛错**的，
  所以"监听模式下桥接莫名其妙连去中转"会让用例直接红。
- 代价：**插件有了第一个运行时依赖**（`ws` 8.18.3，纯 JS、无原生依赖）。
  这是"真机直连"与"零 runtime dep"之间的取舍，选了前者。
- 代价：监听面是**明文 WS**。安全性完全落在"外部终结 TLS"这个部署约定上 ——
  插件里没有任何东西能保证操作者真的配了 TLS。写进文档是唯一的手段（§1.7）。
- 代价：`listener.test.ts` 的端口用 `port: 0`（系统分配），所以它不受固定端口冲突影响；
  但同一套件并发跑多条监听面时依赖系统分配的正确性。
- **仍未做**：真机联调（Tailscale 可达性、`tailscale serve` 的证书）、
  监听面的限流（中转有令牌桶，直连侧没有 —— 但目前也没有对外的暴露面承诺）、
  手机端 Dart 客户端（直连的另一半）。

## 落地时改动的文件

| 文件 | 做了什么 |
|---|---|
| `connector/src/transport/listener.ts` | **新增**：`startListener`（接 WSS → 每 accept 装配一次 → `attach`） |
| `connector/src/transport/connection.ts` | `attach()` 起定时器；`start()` 与它共用幂等的 `startTimers()` |
| `connector/src/session-buffer.ts` | 重复 `seq` 从 `warn` 降为 `debug`（正常形态，不是告警） |
| `connector/src/config.ts` | 新增 `listenPort`（默认 0）/ `listenHost`（默认 `127.0.0.1`） |
| `connector/src/index.ts` | `makeConnection(dial)` 工厂；拨号与接受共用；监听面装配 + dispose 收口 |
| `connector/package.json` | `ws` 从 devDependencies 提到 dependencies |
| `connector/tests/listener.test.ts` | **新增** 4 条：真握手 + 双向 AEAD、不串台、卸载收口、未配对被拒 |
| `connector/tests/listener-config.test.ts` | **新增** 3 条：默认不监听、可覆盖、端口越界被拦 |
| `connector/tests/connection-accept.test.ts` | **新增** 2 条：可攒批帧出线、半开判得出来 |
| `connector/tests/session-buffer.test.ts` | 重复/倒退 `seq` 改成断言"不记且不告警" |
| `docs/subsystems/connector-and-relay.md` | §1.1 配置表 + §1.7 监听面 + 生命周期图 + `ws` 依赖 |
| `docs/subsystems/remote-channel.md` | §2 记下直连拓扑 |

证据：`tsc --noEmit` 0 错、`pnpm test` **285 项**全绿（275 + 新增 10）、`pnpm build` 出产物
（`lib/index.js` 里 `ws` 是外部 import，加载出 `apply` / `Config`）。
三处变异校验：① `startTimers` 变空操作 → 4 项红；② 去重改回 `warn` → 2 项红；
③ `listenPort` 默认改成 `8787` → 1 项红。协议门禁不受影响（486 / 26 / 49 / 17 全绿）。
