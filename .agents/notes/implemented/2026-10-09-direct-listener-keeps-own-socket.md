# Agent Note: 直连监听面保留自起监听，不改用 DSH 的 registerUpgrade

## Problem

`connector/src/transport/listener.ts` 自己起 WebSocket 监听，设计文档假设「TLS 由外部终结
（tailscale serve / 反向代理）」。2026-10-09 读 DSH 源码发现 `packages/host/webserver` 原生支持
`node:https`（`src/index.ts:13`）与 `WebUpgradeRoute`（`:55-61`），于是产生疑问：
直连拓扑是否应该改成「把升级路由注册到 DSH 自己的 web server」，从而让 TLS 由 DSH 原生提供、
废掉我们自己的监听？

## Decision

**不改。保留 `listener.ts` 自起监听作为直连的唯一形态，把 registerUpgrade 这条路记为
「将来某类条件下的更优解」并写进文档。**

调研确认插件**能**注册（`ctx.get('webServer').registerUpgrade({path, handler})`，
`packages/host/webserver/src/index.ts:349-355`，返回 disposer；先例：
`packages/experimental/inspector/src/host/plugin.ts:111` 与
`packages/api/gateway/src/index.ts:249`）。但换过去要付三笔代价，本期都不值得：

1. **TLS 是监听器级的，插件碰不到**。它由 DSH 启动参数 `--tls-cert` / `--tls-key` 决定
   （`packages/bundle/web-app/src/startup.ts:79-80`，解析在 `:101-106`），
   开了就是**整个 3080 端口**（SPA + `/api` 桥 + 我们的路由）一起上 TLS。
2. **绑定地址也是监听器级的，且默认回环**（`packages/bundle/web-app/cordis.patch.yml:183`）。
   要让手机从 tailnet 连进来，使用者必须显式 `--host <具体 IP>`（`:263-270` 拒绝通配地址），
   **那会把 DSH 的浏览器面一起暴露到那个网段**。现在的 `listener.ts` 只暴露我们自己一个端口，
   而 `listenHost` 还能由插件自己选（`connector/src/index.ts:625`）—— 攻击面小一个量级。
3. **没有先例**：DSH 代码库里没有一个插件「在 upgrade handler 里完整实现一次 WebSocket
   服务端握手」。inspector 是裸 pipe 到上游（`plugin.ts:129-146`），gateway 用自己的 mux
   （`api/gateway/src/index.ts:259`）。我们的 `ws` + `noServer` 方案会是第一个，
   即踩的是没人踩过的路（TLS 下 `head` 是否非空这类细节无人可问）。

附带两条工程事实也让我们倾向保留：upgrade 只支持**精确路径**（无前缀，
`src/index.ts:461` 的 `upgrades.get(pathname)`，未命中直接 `socket.destroy()`，
**没有 HTTP 错误码**）；重复路径**硬抛** `webserver: duplicate upgrade route`（`:350-352`），
disposer 要插件自己收（宿主不替插件摘）。

## Alternatives considered

- **改成 registerUpgrade**：收益是 TLS 原生、少一个端口、少一个 `EADDRINUSE` 失败面、
  与 DSH 其余 web 面同一套部署口径。否决于上面三笔代价 —— 尤其第 2 条：
  为了我们一条路由把 DSH 的浏览器面拖到 tailnet 上，是本末倒置。
- **插件自起 `node:https`**：DSH 全仓没有任何插件这么干（`node:https` 的 import 只有
  `packages/host/webserver/src/index.ts:13` 一处），且没有任何 helper 把 TLS material
  递给插件 —— 等于把 `readTlsFile`（`src/index.ts:240-251`）重新发明一遍。
- **删掉 `listener.ts`**：直连面就没得用了。而它现在能跑、自包含、按 `listenPort !== 0`
  决定是否起（`index.ts:573`），没有维护负担。

## Consequences

- `connector/src/transport/listener.ts` **原样保留**，`listenPort` / `listenHost` 配置项不动。
- `docs/subsystems/connector-and-relay.md` §1.7 记下两条路与取舍，以及
  「什么时候该重新考虑 registerUpgrade」：**当直连要成为主路径**（不再走中转）、
  且使用者本来就在跑带 TLS 的 DSH web server 时。
- 「TLS 由外部终结」这个假设**不是错的**，只是陈述不完整：它是可选项之一
  （tailscale serve / 反向代理），且是攻击面最小的那个。
- 未验证的部分如实留下：`ws` 的 `handleUpgrade` 在 `noServer` + TLS 下的 `head` 行为、
  upgrade 请求是否经过 gzip 中间件（读代码看不会：gzip 只包 HTTP 路径，
  `src/index.ts:411-425`，upgrade 走独立 `server.on('upgrade')`，`:448`）——
  这两点只在真走那条路时才需要验。
