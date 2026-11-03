# Agent Note: 管理面不能依赖配置合法 —— 缺 relayUrl 不再拦挂载

Status: implemented

## Problem

2026-11-02 用户装完 `dsh-mobile-connector` 之后，DSH 里的「手机连接」面板全红：

- 顶部 `读取失败：HTTP 404`；
- 「连接」卡停在 `…`，状态「离线 0/0 台在线」，**中转与局域网端口都不显示**；
- 点「出配对码」同样失败。

根因链（全部有现场证据）：

1. DSH 的插件管理装插件只写 `dsh.profile.bundles` + `dependencies`，**不写 `cordis.patch.yml` 的 config 段**。
   实测：`~/.dsh/profiles/desktop/package.json` 里 `dsh-mobile-connector` 在 bundles 里，
   同 profile 的 `cordis.patch.yml` 里 `dsh-mobile` 出现 **0 次**（10-19 的备份里也是 0 次）。
2. `relayUrl` 的 schema 没有默认值（`connector/src/config.ts:46`）。实测 `Config({})` 通过，
   但 `relayUrl.get()` 是 `undefined` —— 加载器不会在挂载前拒掉它。
3. `validate-config` 于是抛 `relayUrl 未配置：拒绝挂载`，`lifecycle.ts` 中止 mount 并回滚。
4. `mountAdminFace` 挂在 `start-transport` 步里（`connector/src/index.ts`），**一步都没跑到** →
   `/api/dsh-mobile/*` 没有一条路由 → 落 DSH 共享通道的精确查表兜底，正文就是 `not found`。
   客户端 bundle 走另一条路（按 `dsh.client` 扫描），所以**界面能开、接口全 404**。

用装好的构建跑探针（假 ctx，只记录 `connection.fetch.register`）：

```text
A) relayUrl 缺省（= 该 profile 的真实形状）
   注册的管理面路由数 = 0
   挂载错误 = mount 阶段有 1 个步骤失败：
             validate-config(relayUrl 未配置：拒绝挂载，而不是连上一个不完整的中转)
B) relayUrl = wss://dsh.0t0.me/ws/connector
   越过 validate-config，进到 open-store
```

**这是同一类问题的第三次**：10-17 是挂载顺序（4 个 POST 路由 404）、10-29 是"删了令牌就把面板锁在门外"、
11-02 是热重载撞上存储后端关闭。三次都表现为"面板 404"，而 404 的面板什么也修不了。
不变量一直没写下来：**管理面是改配置的界面，它不能依赖配置是否合法。**

## Decision

`relayUrl` 空着 = "还没配"，**不再拦挂载**：

1. `validate-config` 只留一句日志就返回（地址写了但不合法仍抛 `relayUrlOf` 的错）。
2. `transport/startup.ts` 多第三种缺席：`relayConfigured()` 为 false 时**连 `startRelay` 都不调**
   （拨一个空地址只会得到更难读的错误），只把 `RELAY_UNCONFIGURED` 这句人话交给 `onTolerated`。
3. 装配层把这句话写进 `relayError`，于是 `channels()` 的 `detail` 直接显示
   「未配置中转地址（relayUrl 空）」—— 操作者在「连接」卡里选「内置中转」或填地址保存即可。

准入门槛（可机械判定）：

1. `relayUrl` 空 ⇒ `startRelay` 一次都不调、`onTolerated` 收到 `RELAY_UNCONFIGURED`、整体不抛。
2. `relayUrl` 空且 `listenPort = 0` ⇒ 两条通道都不调，整体不抛（"刚装完插件"那条路径）。
3. 坏地址 / 端口被占 ⇒ 照旧整体抛出，不接着起下一条。
4. 装配层必须接上 `relayConfigured`，且源码里不许再出现 `relayUrl 未配置：拒绝挂载`。

## Alternatives considered

1. **把 `mountAdminFace` 挪到所有可能失败的步骤之前**（结构上最彻底）
   - 最强的理由：管理面根本不该依赖装配链走到哪一步；这样任何上游失败都只是"面板显示未就绪"。
   - 为何被否（暂缓）：它依赖 `start-transport` 里创建的 `transportChannels`（2026-10-17 的顺序 bug：
     挂早了 4 个 POST 路由 404），要拆成"早挂基础路由 + 晚挂通道路由"得动三层注册；而且只要
     `start-transport` 仍然抛错，`lifecycle` 的回滚照样会把已挂的面板摘掉 —— 真正的解是
     "这条链不抛"，那是另一篇的事（见 Consequences 的遗留）。
2. **给 `relayUrl` 一个 schema 默认值（内置中转）**
   - 最强的理由：装完即用、零操作，用户永远不会看到 404。
   - 为何被否：那等于替用户选了我们自己的中转并直接拨出去。中转是**选**出来的
     （`2026-11-01-builtin-relay-is-a-choice.md`），而 schema 默认值会让自部署用户的连接器
     静默拨向 `dsh.0t0.me`。卡片里"没配时预选内置中转"是**待确认的选择**，与"默认值"不是一件事。
3. **让用户手写 `cordis.patch.yml`（本机就是这么救回来的）**
   - 最强的理由：零代码、立即生效。
   - 为何被否：把"装个插件"变成"还得会编辑 YAML"，而且面板 404 时除了翻文档没有别的入口；
     这正是本次事故里用户被困住的那一步。
4. **坏地址也一并容忍**
   - 最强的理由：地址写错同样是"能在面板里改回来"的状态，按同一条不变量也该让面板活着。
   - 为何被否（暂缓）：`relayUrlOf` 抛的是普通 `Error`，按类型容忍得先给它一个具名错误；
     而 `tests/transport-startup.test.ts` 明确钉着"坏地址整体抛出"。放宽它会同时改动
     `startup.ts` 的判据与那条用例，值得单独一篇笔记，而不是塞进这次修复。

## Consequences

- 收益：装完插件面板一定能打开；"为什么没跑"直接显示在「连接」卡（`detail`），不用翻日志。
- 收益：`relayUrl` 空着时不再去拨一个空地址，省掉一条误导性的错误。
- 代价：`validate-config` 不再是"拦住所有坏配置"的闸，只剩"地址形状"这一半 —— 名字保留，
  但它的语义已经从"校验"退到"留声 + 只校验写错的形状"。
- 代价：`StartupPorts` 多一格 `relayConfigured`，`onTolerated` 的入参从 `unknown`（错误对象）
  改成人话字符串（两处调用点 + 用例同步改）。
- **遗留（同一类，尚未修）**：坏地址、直连端口被占仍会让整次 mount 失败 → 面板依旧 404。
  彻底的做法是让 `start-transport` 的失败只落成通道状态（`detail`）而不抛出，或把管理面
  提到它前面；两者都要动 `lifecycle` 的回滚语义，另开一篇。

## 判据

- `cd connector; pnpm exec tsc --noEmit` → 0；`pnpm build` → 过。
- `pnpm test` → **828 项全绿**（新增两条：缺 `relayUrl` 时"不调 `startRelay` + 留痕"、
  "两条通道都没配也不抛"；`assembly-wiring` 增两条接线断言，其中一条是**反向**断言：
  源码里不许再出现 `relayUrl 未配置：拒绝挂载`）。
- 探针复跑：同一份配置（`relayUrl` 缺省）不再停在 `validate-config`，而是进到 `open-store`。

## 代码入口回指

- `connector/src/index.ts` 的 `validate-config` 步（缺地址只留声）与 `createTransportStarter` 的
  `relayConfigured` / `onTolerated` 两格接线。
- `connector/src/transport/startup.ts` 的第三种缺席与 `RELAY_UNCONFIGURED`。
- `connector/tests/transport-startup.test.ts`、`connector/tests/assembly-wiring.test.ts`。
