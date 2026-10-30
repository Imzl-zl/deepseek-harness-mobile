# Agent Note: 装配层三处判据抽出成可测函数（补回归网）

Status: implemented

## Problem

2026-10-29 那轮（`2c9876f`，`2026-10-29-panel-connection-card.md`）给「手机」面板加了「连接」卡，把"凭据里没有令牌"从**拒绝挂载**降级成**只让中转通道起不来**。三处判据全部落在 `connector/src/index.ts` 的 `buildSteps()` 闭包里，而它们各自是**错了也不报错**的一类：

1. **键集合 → 重建哪条通道**：`RELAY_CONFIG_KEYS` / `DIRECT_CONFIG_KEYS` 加错一格，症状是"改个端口把中转也重启了"——掉线一次，日志里看不出来。
2. **重建的串行队列**：手改 `cordis.patch.yml` 连点两次会排两次，并发 stop/start 互踩，留下一条"显示已启动、其实没连上"的通道。
3. **`transportStart` 的两种容忍**（缺令牌 / `listenPort = 0`）：任何人把 `catch` 收紧成 `catch {}`（吞掉坏地址与端口被占），手机侧表现为"整个插件不工作"，而 `connector/tests/` 全绿 —— 因为**没有任何文件 import `src/index.ts`**，两份已有的源码扫描用例（`connection-surface.test.ts`、`admin-face.test.ts:528`）只数 `index.ts` 的文本。

当时的证明只有一次隔离实例手工 e2e（删令牌 → 重启 → 面板仍能打开 → 贴回令牌 → 中转恢复）。换句话说：上轮写进决策笔记的准入门槛 5，**没有回归网**，只有一次现场观察。

## Decision

把三处判据搬出装配闭包，各自成为一个纯模块；装配层只做接线，并在被约束的入口回指本篇：

| 判据 | 落点 | 网 |
|---|---|---|
| 键集合 → 哪条通道；重建串行与失败原因 | `connector/src/transport/rebuild.ts`（`REBUILD_KEYS` / `channelsToRebuild` / `createRebuildQueue`） | `tests/transport-rebuild.test.ts` |
| 起传输的两种容忍（判据 + 起停顺序） | `connector/src/transport/startup.ts`（`toleratesRelayStartFailure` / `createTransportStarter`） | `tests/transport-startup.test.ts` |
| 面板读取投影（快照 + 通道 + 令牌状态 → `ConnectionState`） | `admin/connection-card.ts`（`readConnectionState`） | `tests/assembly-wiring.test.ts` |
| 上面三处**真的被装配层用上、且实参接对** | —（读 `index.ts` 源码，断言**实参**而不只是名字） | 同 `tests/assembly-wiring.test.ts` |

准入门槛（可机械判定，均已跑过变异校验）：

1. `REBUILD_KEYS` 的键集合被逐键钉住（四格中转 / 两格直连 / 四个无关键不触发 / 段拼点而非前缀匹配）。
2. 容忍判据**只认 `RelayTokenError`**：五条反例（端口被占、坏地址、字符串、`undefined`、`null`）都必须返回 `false`。
3. 起传输顺序与"容忍之后直连照常起"由替身记录的调用序列钉住；真故障时**不继续起下一条**（半挂比不挂更难查）。
4. 重建队列："同一时刻最多一次在跑"（`maxInside === 1`）+ 事件顺序 + 失败落成一句可显示原因 + 下一次开始清空 + 非 `Error` 归一。
5. 读取投影的每一格错法各有一条：没有 settings → `revision: undefined`；没有 `relayTokenRef` → **不碰凭据面**；`listenPort` 不是数字 → 回配置活读的值（不是 0）；布尔格只认真 `true`；注册表为空 → 如实"未运行"；通道按 id 找不按位置。
6. 抽取物必须在 `index.ts` 里被**调用**（四个调用点 + `'loader/volatile-update'` 事件名），**而且实参接对**：
   `startRelay: startRelayChannel` / `startDirect: startDirectChannel` 不许对调、
   `listenPort: () => config.listenPort()` 不许写成常量、`channels: transportChannels?.channels() ?? []`
   不许换成空数组、`tokenStatusOf` 不许接别的存、`for (const channel of channelsToRebuild(paths))` 不许绕开 `paths`、
   写/清令牌各有一处 `rebuildQueue.enqueue('relay')`。这六条都是"能过 `tsc`、也过其余用例"的接错方式。
   断言前先**去注释 + 压空白**，所以普通重排/换行不会假阴；它仍是文本级（证明不了运行时行为），
   但已从"名字还在"升到"接的是哪个东西"。
7. 变异校验（一次性，条数写进提交）：容忍判据 `return true` → **2 红**（判据 + 真故障整体抛出）；`channelsToRebuild` 恒返回两条 → **6 红**；投影退化成 `Boolean(...)` + 端口兜底 0 → **2 红**。其余用例正确地仍绿。

## Alternatives considered

1. **造一个假 `ctx` 直接 import `src/index.ts` 跑真实挂载**
   - 最强的理由：测的是真装配，连 `apply()` 的 `ctx.effect` 顺序、`provide` 的 disposer、storage domain 的打开/关闭都能一起覆盖 —— 那是"接线"这个词最完整的含义。
   - 为何被否：要跑的挂载路径会碰上 `ctx.storageDomain` / `ctx.credentials` / `typertGateway` / `sessionController` / `sessionProjections` 等一整套宿主接口，假 ctx 的形状必须与 DSH 一致才不自欺；一旦漂移，红的是替身而不是产品，等于把"手工 e2e 不可靠"换成"替身不可靠"（顺序引擎那层已经用假步骤证明过，见 `lifecycle.ts`）。剩下的价值在**判据本身**，不在"再装一遍"。也正合用户那句"不要为了可测性把 ctx/服务塞成全局"。
2. **只加源码文本断言，不抽函数**
   - 最强的理由：零结构改动，照 `connection-surface.test.ts` 数一遍就行，diff 最小。
   - 为何被否：文本断言只能证明"某句话还在"。`if (!(error instanceof RelayTokenError)) throw error` 改成 `catch {}` 之后，文件里仍可能出现 `RelayTokenError`（注释里就有），而行为已经变了。
3. **只抽键集合，队列留在 `index.ts`**
   - 最强的理由：键表是唯一真正"纯"的部分，抽它风险最小、收益最直接。
   - 为何被否：串行与"失败落成原因"和键表是同一个 bug 面（连点两次互踩就在这半步），留一半等于网漏一半 —— 而且漏的正是没有编译期保护的那一半。
4. **给闭包加 `@visibleForTesting` 导出**
   - 最强的理由：不用搬代码，测试拿到的是线上那一份对象。
   - 为何被否：导出装配闭包等于把"挂载期局部状态"升成模块级 API；而要驱动它，测试仍得自己造 `stopRelayChannel` / `startRelayChannel` 的真 socket 依赖，比抽纯函数贵得多。
5. **顺手把空转的 `deviceLimit` 一起处理**
   - 最强的理由：都是装配层的事，一次改完省一轮门禁。
   - 为何被否：本轮只补网、不改行为。混进来之后 diff 里"哪些是纯搬移、哪些是新行为"就说不清了，而任务 4 要单独决定实现还是删。

## Consequences

- 收益：三处判据从"一次现场观察"变成门禁；`connector` 用例 **719 → 748**。删令牌不再需要起隔离实例才有证据；坏地址、端口被占、连点两次 rebuild 这几种错法各自有一条会红的用例。
- 收益：`index.ts` 少了一段 60 行的政策代码，`transport/` 下多了两个"只讲规则"的文件 —— 读 `startup.ts` 比读装配闭包更容易看出"为什么缺令牌还能挂"。
- 代价：政策与接线分家后，回答"缺令牌时插件到底会不会挂上"要看两个文件（`index.ts` 的 `transportStart = createTransportStarter(...)` + `startup.ts` 的判据），比原来多一跳。
- 代价：第 6 条准入门槛是**源码文本**检查（已升到实参级），仍属下限检查 —— 它保证"接的是哪个通道/注册表/存"，
  但证明不了运行时行为；真正的运行时证据仍是 `transport-*` 两组替身用例与真机验收。
- 代价：`createRebuildQueue` 只暴露一个 `failure()`。当前只有中转在用这个出口（`「连接」卡` 的 `relayError`）；将来若要"每条通道各自的错误"，接口要改（不能靠往里塞第二个可选参数糊过去）。
- 代价：`transport/startup.ts` 是**第一个** `transport/ → dsh/` 的 import（只为拿 `RelayTokenError` 这个本插件自己的错误类；
  `docs/subsystems/connector-and-relay.md` §1.2 的分层规则禁的是 `dsh/ → transport/` 与 `protocol/ → DSH`，这条不在其中）。
  代价是 `transport/` 因此传递依赖 `@deepseek-ai/dsh-credentials`（`relay-token.ts` 的运行时 import）。**不要**为了消掉这个边
  把判据改成注入的布尔参数 —— 那正是第 2 条被否方案（文本/参数比行为弱一档）。真要收窄，就把 `toleratesRelayStartFailure`
  搬进 `relay-token.ts`（错误类型所在处），而不是绕开行为断言。
- 仍未覆盖（有意）：真 socket 的起停（`tests/listener.test.ts` + 真机组）、`transportStart` 在真 fiber 里的执行时机 —— 那是"装配顺序"，由 `lifecycle.ts` 与真机验收各自的网负责。
