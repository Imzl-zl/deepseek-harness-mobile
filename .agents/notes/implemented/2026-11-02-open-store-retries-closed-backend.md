# Agent Note: 装插件触发的热重载会让 open-store 撞上"后端已关"，退避重试跨过去

Status: implemented

## Problem

通过 DSH 的插件面板装 `dsh-mobile-connector` 之后，面板全红：

- 连接卡永远 `…`，状态「离线 0/0」；
- 出配对码报 `Unexpected token 'o', "not found" is not valid JSON`；
- 刷新报「读取失败：HTTP 404」。

根因链（都有源码依据）：

1. 面板的 404 正文是 **`not found`** —— 那是 DSH 共享通道的兜底
   （`packages/client/connection/src/rpc-host.ts:226-227`）：请求到了 `/api`，
   但**没有匹配的路由**。
2. 我们的路由由 `mountAdminFace`（`connector/src/admin/mount.ts:62`）注册，
   它挂在 `start-transport` 这一步里（`index.ts`，2026-10-17 起）。
3. 而 `start-transport` 之前是 `open-store`（`index.ts` 的 `open-store` 步）。
   装插件会触发 DSH 的 profile 热重载，重载那一拍 `dsh-storage-json` 的后端正在关，
   `facility.open()` 抛 `StorageError: json backend is closed`（code `closed`），
   `lifecycle.ts` 把它当成 mount 失败并回滚 —— **`mountAdminFace` 根本没跑**。
   启动日志里的原话（2026-10-31，本机）：
   `挂载失败，通道未启动 … mount 阶段有 1 个步骤失败：open-store(json backend is closed)`。

客户端 bundle 是另一条路（按 `dsh.client` 扫描），所以**界面能开、接口全 404**。

## Decision

1. `open-store` 对 `code === 'closed'` **退避重试三次**（120/240/360 ms），
   别的错误（schema 不兼容 / 权限）一次都不等，立刻抛。
2. 客户端读应答体统一走 `jsonOf(response)`：先读 `text()` 再 `JSON.parse`，
   解析失败就报 `HTTP <状态>: <正文前 80 字>` —— 不再把解析器的原话
   （`Unexpected token 'o'…`）当错误展示给用户。

准入门槛（可机械判定）：

1. 后端第一次抛 `closed`、第二次成功 ⇒ `open-store` 成功（重试生效）。
2. 后端抛非 `closed` 错误 ⇒ 立刻失败，不重试。
3. 管理面返回纯文本 404 ⇒ 面板上显示 `HTTP 404: not found`，不是 `Unexpected token`。

## Alternatives considered

1. **把 `mountAdminFace` 挪到 `open-store` 之前**
   - 最强的理由：接口先挂上，存储失败时面板至少能说"存储未就绪"，而不是 404。
   - 为何被否（暂缓）：它依赖 `start-transport` 里创建的 `transportChannels`
     （`index.ts` 2026-10-17 的顺序 bug：挂早了 4 个 POST 路由 404），
     拆成"早挂基础路由 + 晚挂通道路由"要动三层注册，收益不抵风险。
     先把触发条件（热重载那一拍）消掉。
2. **让用户每次装完插件手动重启 DSH**
   - 最强的理由：零代码。
   - 为何被否：把框架的热重载当成用户的作业；而且同一台机器上装第二个插件又会撞一次。
3. **客户端吞掉非 JSON 应答、显示"未连接"**
   - 最强的理由：界面不至于报红。
   - 为何被否：那会把"接口没挂"伪装成"网络问题"，真正的成因更难被看见
     （本次就是靠 `not found` 这三个字定位到共享通道兜底的）。

## Consequences

- 收益：装插件不再把连接器打死；真出问题时用户看到的是 `HTTP 404: not found`。
- 代价：`open-store` 多了最多 ~700 ms 的重试窗口（只在后端 `closed` 时）；
  这段时间里 mount 是挂起的，手机侧表现为"还没上线"，不会误报错误。
- 代价：客户端少了一次"直接 json()"的便利，所有读应答体都走同一个 helper。

## 判据

- connector `tsc --noEmit` 0、`pnpm build` 过、`pnpm test` **818 项全绿**
  （`client-panel.test.ts` 的应答桩统一补了 `text()`，与真 `Response` 同形）。
- flutter **1662 项全绿**（本批同时改了手机侧"断开连接"，见同批另一篇笔记）。

## 代码入口回指

- `connector/src/index.ts` 的 `open-store` 步（内联 `openDomain` 重试）。
- `connector/client.js` 的 `jsonOf`，以及各 `await jsonOf(response)` 调用点。
- `connector/tests/client-panel.test.ts` 的 `loadClient`（应答桩补 `text()`）。
