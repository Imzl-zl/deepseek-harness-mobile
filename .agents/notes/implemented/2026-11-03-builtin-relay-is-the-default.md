# Agent Note: 内置中转是默认值，且"连不上"必须说得出原因

Status: implemented

## Problem

2026-11-03 装完插件、面板能打开之后，还剩两个"开箱即用"的问题：

1. **新用户仍要自己写地址**：`relayUrl` 没有默认值，装插件又不写 config 段 ——
   上一批只做到"缺地址也能打开面板"，用户还得在卡片里选一条才真正有中转。
   用户原话：「是不是用户安装开箱即用，你不要让用户安装了还要改配置啥的」。
2. **连不上时界面不说话**：真机现场面板一直是「重连中 0/1 台在线」，点出码只回
   `HTTP 400`（空正文）。实测根因：连接器存的那张令牌是**旧中转签的**，用真令牌打
   `wss://dsh.0t0.me/ws/connector?id=local` 的升级请求回 **HTTP 401**（正文空）。
   而 `ws` 的 `error` 事件只有一句 "Received network error or non-101 status code"，
   分不出 401 / 404 —— 前者要换令牌、后者要改地址，操作者拿不到任何下一步。

## Decision

1. **`relayUrl` 的 schema 默认值 = 内置中转**（`BUILTIN_RELAY_URL`，
   `wss://dsh.0t0.me/ws/connector`）。它是**默认值不是强制**：卡片里随时能换成自部署地址，
   换完立刻重建中转通道；显式写空串仍然算"没配"（不会又被默认值填回去）。
2. **升级被拒要说人话**：`relay-link.ts` 接 `ws` 的 `unexpected-response`，把状态码交给
   `describeUpgradeFailure` → `relayError` → 「连接」卡的 `detail`；连上的那一刻由
   `onFailure(null)` 清掉。重连期间保留上一次的原因，否则永远只有「重连中」三个字。
3. **出码失败必须带正文**：`POST /api/dsh-mobile/pair` 的异常以前直接抛给 DSH 桥接，
   回一个空正文的 400；现在在路由里 `try/catch` 归一成 `badRequest(error)`。

## Alternatives considered

1. **不给默认值，只靠面板"没配时预选内置中转"**（上一批的形态）
   - 最强的理由：拨向哪台中转应当由用户显式确认，默认值等于替他做决定。
   - 为何被否：新装用户的第一步仍然是"打开面板点一下"，而用户的验收标准是"装完即用"。
     默认值不等于强制 —— 卡片里改一下就换走，且没有令牌时那一拨只会拿到 401，不发任何数据。
2. **默认值只写在浏览器/手机侧的预设里，schema 不给**
   - 最强的理由：不污染电脑侧配置，自部署用户不会被写进一条自己的地址。
   - 为何被否：面板预设、手机端预设、出码时用的地址是三处，各写一份必然漂；
     而 `relayUrl` 本来就是"用时取一次"的 volatile，schema 默认值是唯一一处真值。
3. **只把 401 打进日志，不上面板**
   - 最强的理由：不动 UI。
   - 为何被否：`ctx.logger` 到不了 CLI 的 stdout（老账，见 `tools.md` 的 Pitfalls），
     面板是唯一现场；这次真机就是靠"界面什么都不说"卡住的。
4. **用全局 `WebSocket`（undici）代替 `ws`**
   - 最强的理由：少一个依赖。
   - 为何被否：undici 的 WebSocket 不暴露非 101 应答的状态码，也没有 `terminate()`；
     拿不到 401 就写不出第 2 条。

## Consequences

- 收益：装完插件就有中转地址，只差一张令牌；缺令牌/令牌过期/地址写错在「连接」卡里
  各是一句能照做的话。
- 代价：**自部署用户首次启动会向内置中转发一次升级请求**（无令牌 → 401，不发送任何数据）；
  要彻底避免得在装插件时就问一次，那是宿主没有的交互。
- 代价：`unexpected-response` 被接管后必须自己 `request.destroy()`，否则请求半挂、
  `close` 不来，退避重连也不会发生 —— 这条由 `relay-link.ts` 的注释与 `describeUpgradeFailure`
  的用例按住。
- 代价：`relayUrl` 的类型从 `Volatile<string | undefined>` 收窄成 `Volatile<string>`，
  代码里那些 `?? ''` 变成防御性冗余（保留：显式空串仍是合法输入）。

## 判据

- connector `pnpm test` → **832 项全绿**（新增：状态码翻译 4 种互不相同、默认值三格
  —— 默认地址/直连关/明文关、显式空串不被填回、出码失败 400 带正文）。
- `tsc --noEmit` 0、`pnpm build` 过；relay `pnpm typecheck` 0、`node --test` **152 条**。
- 现场判据：真令牌打 `wss://dsh.0t0.me/ws/connector?id=local` → **HTTP 401**（正文空），
  即"中转不认这张令牌"，与面板上要显示的那句话一致。

## 代码入口回指

- `connector/src/config.ts` 的 `BUILTIN_RELAY_URL` 与 `relayUrl` 默认值。
- `connector/src/transport/relay-link.ts` 的 `describeUpgradeFailure` 与 `onFailure`。
- `connector/src/index.ts` 的 `onFailure` 接线与 `channels()` 的 `detail`。
- `connector/src/admin/routes.ts` 的 `PAIR_PATH` 失败归一。
