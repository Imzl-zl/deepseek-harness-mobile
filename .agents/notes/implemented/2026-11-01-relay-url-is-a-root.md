# Agent Note: 手机侧的中转地址一律存根地址

Status: implemented

## Problem

电脑侧 profile 的 `relayUrl` 常写成 `wss://dsh.0t0.me/ws/connector` —— 那是**连接器**
拨号的路径，而且连接器自己会拼（`connector/src/transport/relay-link.ts`：
`base.pathname = '/ws/connector'`）。可二维码把配置里的值原样带出来
（`connector/src/pairing.ts:219`），于是**手机收到的 `relay` 就带着那条路径**。

手机这一侧压根不用那条路径：它拼的是 `/ws-ticket`（`httpBaseOf`）与
`/ws/device?ticket=`（`deviceUpgradeUrl`），而且两处都已经"只取 scheme + authority"。
所以功能上能用，但 `url` 是端点**身份**的一半（`endpointIdOf`）——
`wss://host/ws/connector` 与 `wss://host` 就成了表里的**两条端点**：

- 同一台中转出现两行（一行来自二维码、一行来自"内置中转"或手填）；
- 竞速时它们互相顶掉（中转对同一设备只留一条数据通道，`relay/src/server.ts` 的 `replaced`），
  症状是"连上了又断、反复重连"。

用户看到的正是这个不一致：「我怎么看以前不是这样，是 `wss://dsh.0t0.me/ws/connector`
这样？」——两种写法都是他见过的，界面没告诉他哪个是手机该用的。

## Decision

**中转端点在进入端点表时就规范成根地址**（`scheme://authority`），路径与参数一律丢掉。
规范只在 `core/endpoint.dart` 的 `canonicalEndpoint` 里定义一次，
`data/endpoint_book.dart` 在**三个入口**调用它：构造表、手填、连接器自报。

直连**不规范化**：它可能真的挂在反代的某个路径后面。

准入门槛（可机械判定）：

1. 表里同时有 `wss://h` 与 `wss://h/ws/connector` ⇒ 只剩一行，且是 `wss://h`。
2. 手填带路径的中转 ⇒ 表里存根地址，落盘的也是根地址（重启不会又变两条）。
3. `endpoint.describe` 报带路径的中转、表里已有根地址 ⇒ 不新增行（同一个 id）。

## Alternatives considered

1. **只在用处剥路径（现状：`deviceUpgradeUrl` / `httpBaseOf` 已经这么做）**
   - 最强的理由：一处都不动就能连上，改动面为零。
   - 为何被否：能用不等于对。身份里还带着路径 ⇒ 表里两条、竞速互踢；而且界面把
     电脑侧的路径显示成手机的地址，用户没有判断依据。
2. **在二维码出码时就把路径剥掉（连接器侧）**
   - 最强的理由：正本清源，手机什么都收不到错的。
   - 为何被否：已经发出去的二维码、已经落盘的旧数据不会因此变好；而"手机收到的值
     是规范形状"这件事本来就该由**手机**这一侧的入口保证（协议不承诺 `relay` 不带路径，
     `endpoint.dart` 的老注释也写了"万一带了路径"）。
3. **把 `relayUrl` 配置校验收紧成"不许带路径"（连接器拒绝启动）**
   - 最强的理由：配置错误早发现。
   - 为何被否：`/ws/connector` 是**电脑侧**的合法写法，而且连接器自己会拼 —— 收紧
     只会把一批能跑的配置打成启动失败，属于新增边界。

## Consequences

- 收益：同一台中转只占一行，竞速不再互踢；界面显示的地址就是手机真正拨的根地址。
- 代价：旧落盘里的带路径条目在下一次落盘时被改写成根地址 —— `hidden` / `succeeded`
  等按 id 记的账对那条地址会**失效一次**（表现为"以前藏掉的又出现/以前成功过的不再算"）。
- 代价：判定散在三个入口调用同一个函数；将来若出现"中转真的挂在子路径后面"的部署，
  这条决定要重开（现在没有这种部署）。

## 判据

- `app/test/endpoint_discovery_test.dart` 新增 3 条（折叠 / 手填存根地址 / 自报不新增）。
- 全文 **1659 项**全绿；`node app/tools/verify-platform-boundary.mjs` 700 项通过。

## 代码入口回指

- `app/lib/core/endpoint.dart` 的 `canonicalEndpoint`。
- `app/lib/data/endpoint_book.dart` 的 `_canonicalTable` / `addManualEndpoint` /
  `mergeDiscoveredEndpoints`。
- 相关：`app/lib/core/endpoint.dart` 的 `kBuiltinRelayUrl`（
  `implemented/2026-11-01-builtin-relay-is-a-choice.md`）。
