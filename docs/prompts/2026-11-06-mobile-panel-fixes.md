# 新会话提示词：手机面板六条 + 中转两条（2026-11-06 真机反馈）

> 用法：把下面 `---` 之间整段贴进新会话。它自带定位证据，不需要再问一遍背景。

---

仓库 `D:\sudy\myproject\dsh-mobile`，分支 `main`（`e374ece` 之后）。产品已发 `v0.2.9`，
生产中转 `dsh.0t0.me`（华为云 `115.175.66.247`，`/opt/dsh-mobile`，docker compose +
`relay/docker-compose.server.yml`）。**用户刚在真机上试完这一版，报了 8 条问题**，
本会话就做这 8 条，一条一条来，每条都要有回归用例或可复跑的命令。

## 铁律（沿用项目根 `AGENTS.md`）

- 改源码**只用编辑工具**，禁止 shell 字符串替换。
- 非平凡改动留决策笔记，代码与笔记**同批提交**（`decision-notes` 技能）。
- 引用 DSH 行为给 `packages/...:行号`；查不到就写「未找到」，禁止猜。
- **宿主语义优先**：不新增 DSH 没有的边界；确需偏离先改 `docs/` 再改代码。
- 发版 CI 会跑：`node protocol/verify-*.mjs`、`cd relay && pnpm typecheck && node --test`、
  `cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test`、
  `cd app && dart analyze --fatal-infos lib test integration_test && flutter test`、
  `node app/tools/verify-platform-boundary.mjs`。
- 改 `connector/` 或 `relay/` 后本地必须跑对应那两条；改线上中转要按
  `docs/cookbook/relay-on-a-server.md` §6.6（**先查令牌表有没有两条记录指向同一个
  `connectorId`**，命中就清掉一条的绑定，否则中转拒绝启动）。

## 六条面板问题（电脑侧「手机」面板，UI 在 `connector/client.js`）

**1. 「上报给手机的地址」把没用的地址全列出来了（设计问题，优先）**

现状：`connector/src/transport/listener.ts:143-167` 刻意**枚举全部非内部网卡**
（IPv4 + IPv6 GUA），注释写明"不按网卡名过滤，真正的答案在顺序"；`connector/src/endpoints.ts:55-70`
再把默认路由那条排第一。真机看到的是：WLAN 2（192.168.2.58）、VMware VMnet1
（192.168.40.1）、VMware VMnet8（192.168.235.1）、三条 IPv6 GUA（`2408:8220:...`），
每行一个「删除」。用户原话："有的系统虚拟机地址，有的其他地址，根本用不上吧？能用的就是主机的
IP 地址吧？这不是多余？"

要做：重新定"默认上报哪些地址"。已知事实：默认路由那条已经有唯一来源
（`connector/src/lan-address.ts:40` 的 `defaultRouteIPv4()`，内核选路，不发包）。
候选：① 默认只上报默认路由那条 + 中转，其余折叠成「更多地址（N）」且默认不上报；
② 保持全报但**按可达性分层**（同网段/loopback 之外的标灰并默认不报）；
③ 只报 IPv4、IPv6 收到折叠区。**注意 `endpoints.ts:59-69` 已有 `advertise` 覆盖
（用户点名 hide/extra），改动要兼容它**，并且在 `docs/subsystems/remote-channel.md`
的端点自报一节写清"默认上报什么、为什么"。

**2. 版本行显示「—」**

`connector/client.js:1846-1848`：`updateInfo === null ? '—' : updateInfo.current` —— 而
`updateInfo` 只有**用户点「检查更新」之后**才有（`connector/src/admin/update.ts:71-95`
的 `check()` 是用户触发的网络查询）。本机版本根本不需要联网：`connector/src/index.ts:179-187`
的 `connectorVersion()` 读得到。要做：打开面板就能看到本机版本，`latest`/`hasUpdate`
仍归"点一下才查"。

**3.「已配对设备（3）」：一个手机怎么会是三条？**

用户原话："我的手机三个是真的三个吗？我直连过两个啊？你怎么识别的手机？"

已知：设备身份是**每次配对新铸**（`docs/subsystems/pairing-v2.md`、
`implemented/2026-10-08-pairing-v2-and-device-connections.md`），同一台手机重配就是一行新记录；
三行都叫「我的手机」，`配对于` 分别是 10/31、11/3、11/4，`最后活跃` 全「从未交互」，
`状态` 全「未运行」。要做：① 让用户能认出"哪一行是我现在这台"（设备短码/指纹，
`peerOf` 与握手里的 deviceId 都有）；② `最后活跃` 与 `状态` 的语义要说清或换字段
（`connector/src/admin/routes.ts:108` 是 `lastInteractiveAt`，交互才更新；`状态` 是内存态
presence，重启即清 —— 这解释了"从未交互/未运行"）；③ 是否按手机聚合（同一 stable id）
要先在 `docs/` 里定，再决定要不要协议层变化。

**4. 管理员降不了用户**

`relay/src/admin/page.ts:721-726` 直接 post `/admin/api/users/role`；
`relay/src/server.ts:581` 有 `if (admins.length <= 1) return adminJson(409, { error: 'last-admin' })`。
用户把某个账号设成管理员后，面板上只剩这一个管理员，于是**降级被 409 拒**，而
`page.ts:571` 的 toast 直接把 `data.error` 原样弹出来 —— 用户看到的是 `last-admin`。
要做：① 最后一个管理员不可降级时，按钮禁用并给一句人话（"至少保留一个管理员"）；
② 所有错误码都要翻成人话（`last-admin` / `rate-limited` / `device-limit` …），别把 code 当文案。

**5. 「改电脑数」填 2 报「要一个 1–100 的整数」**

`relay/src/admin/page.ts:727-739` 的 validate 是
`/^\d+$/.test(raw) && Number(raw) >= 1 && Number(raw) <= 100`，
`relay/src/ui/kit.ts:168-172` 用 `input.value.trim()` 调它。纯逻辑对 `"2"` 是通过的，
所以真机那次输入里不是 ASCII `2`（全角 `２` 最可能，`trim()` 不会救）。
要做：① 先复现并确认到底是哪种字符（把实际收到的东西说出来，别只说"要整数"）；
② 归一化全角数字 + `inputmode="numeric"`；③ 补一条 Kit 单测钉住"全角 2 也算 2"。

**6.「默认电脑数 2」但行里显示 `1 / 1`**

`relay/src/admin/page.ts:776`：`row.activeConnectors + ' / ' + row.connectors` —— 这是
**在线数 / 已绑定数**，不是**已用 / 上限**。表头写 `#电脑`，用户自然读成 1/2（上限 2）。
要做：列语义二选一并写清（建议：`已绑定 / 上限` + 另一个 `在线` 列已有），上限取
`maxConnectors ?? auth.defaultMaxConnectors`（`page.ts:728` 已经这么算过一次，别写第二份）。

## 两条中转/配置问题

**7. `connector` 的 `pcId` 默认 `local` 在多租户中转上必撞**

`connector/src/index.ts:169` 的 `DEFAULT_CONNECTOR_ID = 'local'`（首装写进存储，之后不变，
参与握手 transcript）。账号模式下中转把令牌绑到 `?id=` 并**校验每个 `connectorId` 只有一条
记录**（`relay/src/token-table.ts:157-162`），于是两个用户的电脑同时报 `local` 时：
第二次绑定失败，**下一次重启直接拒绝启动**（2026-11-06 生产上就是这样停了 4 分钟）。
候选与取舍已写在 `.agents/notes/proposed/2026-11-06-connector-pcid-collides-across-tenants.md`
（新装随机 id / 由 `pcSignPubHex` 派生 —— 后者等于全部重新配对）。本会话要**定方案并落地**，
同时把 `connector/src/index.ts:166-168` 那段注释改成新口径。

**8. `0.1.21` 的三条链真机 e2e 仍未做**

`proposed/2026-11-05-022-rollout-handoff.md` 的"未验证"第 1 条：投影 / 子代理 / 审批三条链
在真宿主上从没跑过一次真实往返，而 `0.1.21` 已经是 npm `latest`。用户机器是
`DSh 0.2.2-rc.1` + 插件 `0.1.20`（`~/.dsh/profiles/desktop/package.json` 是 `^0.1.20`，
会放行 `0.1.21`）。要做：真机跑一遍三条链，结果写回笔记；有问题就 `npm deprecate` + 补丁版。

## 建议顺序与验收

1. 先做 2、5、6、4（细节、半天内能收，都能写单测/widget 测）。
2. 再做 1、3（要先在 `docs/` 定判据，再改代码，涉及端点自报与设备身份两处契约）。
3. 7、8 各自独立：7 要先定方案；8 要动真机（要用户配合扫码与模型请求，**先报价**）。

每条验收都要求：跑该子系统门禁（relay: `pnpm typecheck && node --test`；connector:
`pnpm exec tsc --noEmit && pnpm build && pnpm test`），并做**一次变异校验**（故意破坏
新加的不变量，确认恰好那几条红）。线上中转要动的话，按 §6.6 的顺序，并在动之前备份
`relay/relay.config.json`。

---
