# 交接：DSH 0.2.2 抬线（已发布，三条链仍未验）

Status: proposed

## 后记（2026-11-06）

`v0.2.9` 标签把 `0.1.21` 一并发到了 npm。这**不是意外**：`publish-connector.yml:19` 同时监听
`v*` 与 `connector-v*`，而 npm 发布那一步没有标签守卫（守卫只加在"版本与标签一致"那一步），
注释写明"两个标签指向同一次发布"。所以只要 `connector/package.json` 是 `0.1.21`，打任何
`v*` 都会发它 —— 下面"未发版"的结论在本次发版后作废，**"未验证"第 1 条仍然有效**。

## 一句话

`0.1.21` 的清单、代码、文档、笔记都已提交并全绿；发布由 `v0.2.9` 带出（见上）。
发版策略仍是**攒齐一批统一发一版**（2026-11-05 用户定），不为单个改动单独发。

## 仓库状态

```
e3afdd6  chore(connector): repository.url 用 git+ 形式，发布时不再被 npm 自动改写
6acd249  docs(notes): 补 0.2.2 兼容核对的双轨实测
4dcacc4  feat(connector): 抬线到 DSH 0.2.2-rc.1，插件兼容性改走双轨版本线
```

当时的仓态（**已被 `v0.2.9` 发版取代**）：工作树干净、本地领先 `origin/main` 3 个提交未 push、
npm `latest` 是 `0.1.20`。下表是当时的口径（`pnpm test` 847 / `flutter test` 1742 /
boundary 728），**现在的数字看 `tools.md`**（836 / 1761 / 833）。

## 已验证（可复现）

| 项 | 命令 / 位置 | 结果 |
|---|---|---|
| 类型 | `cd connector && pnpm exec tsc --noEmit` | 0 错（对 0.2.2-rc.1 类型） |
| 单测 | `pnpm test` | 847/847 |
| 手机单测 | `cd app && flutter test` | 1742/1742 |
| 分析 | `dart analyze --fatal-infos lib test` | 无问题 |
| 多端边界 | `node app/tools/verify-platform-boundary.mjs` | 728 项 |
| lockfile | `pnpm install --frozen-lockfile` | `Already up to date` |
| 打包 | `npm publish --dry-run` | 7 文件 / 196.9 kB |
| 真宿主加载 | 隔离 0.2.2 宿主 `--dump-config` | 组合出 bundle，无 `skipping` |
| 真宿主运行 | `GET /api/dsh-mobile/status` | 13 个能力位全 `true` |
| 双轨判定 | 两代宿主各装一次 | 0.2.1 拒 `0.1.21` 并回滚；0.2.2 接受 `0.1.21`；**0.2.2 也接受 `0.1.20`**（旧上界漏洞） |

## 未验证（发版前应补）

- **三条链真实往返**：投影 / 子代理 / 审批。真宿主上只做到"插件起来、能力位全亮"，没有一次手机⇄电脑的真实数据往返 —— **发版之后仍未验**（`v0.2.9` 已把 `0.1.21` 带到 npm `latest`）。
2. **手机侧 `name` 只过了单测**：行首从会话 UUID 变成 `agent-1` 是可见变化，没上真机看过。
3. **`path` 没做**：它在 `listDescendants()` 的返回里，而我们的目录走 `subagentCatalog` 投影，那条调用面没接。层级已由树表达。
4. **0.2.2 其余 19 条是"读源码判不命中"**，不是运行时证明。
5. **`protocol/verify-*` 与 relay 门禁本轮没跑**（代码没动它们，但发版 CI 会跑）。

## 三条链怎么测（隔离环境已就绪）

- 测试根目录：`D:\sudy\myproject\dsh-e2e-022`（仓库外，约 700 MB）
  - **0.2.2 宿主**：`node_modules\.bin\dsh.cmd`，`DSH_HOME=<root>\home`，profile `e2e`（web 模板 + 本插件）
  - **0.2.1 宿主**：系统 CLI `D:\soft\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd`，`DSH_HOME=<root>\home021`，profile `e2e021`
  - 端口覆盖：`<root>\port.patch.yml`（网页 13080、连接器 18790）
- **手机要连 0.2.2，必须先把 `port.patch.yml` 的 `listenHost` 改成 `0.0.0.0` 再重启宿主**，否则手机根本拨不到（现在是 `127.0.0.1`）。
- 配对路径：浏览器开 `http://127.0.0.1:13080/?token=…`（token 在宿主启动日志里）→ 管理面出码 → 手机扫码。
- 验什么：统计条（投影链）、右抽屉子代理面板（catalog v3 + `name`）、审批卡（interaction 链）。

## 发版步骤

1. 跑完整门禁：`node protocol/verify-fixtures.mjs && verify-loopback.mjs && verify-vectors.mjs`；`cd relay && pnpm typecheck && node --test`；`cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test`；`cd app && dart analyze --fatal-infos lib test integration_test && flutter test`
2. 决定入库方式：这个仓库两种历史都有（`(#3)`/`(#2)` 走 PR，`0a5556c` 直接提交）。走 PR 就先推 `feat/…` 分支。
3. 打 `connector-v0.1.21`（CI 校验 `标签 == package.json` 后 OIDC 发布；npm 上已有同版本则幂等跳过）。
4. 发完更新 `memory.md`（它只写闭环后的现状）。

## 一个必须知道的风险

`0.1.20` 的上界是旧写法 `>=0.2.1-rc.5 <0.2.2`，`includePrerelease` 下**放行 0.2.2 的预发布**（实测）。所以在 `0.1.21` 发出之前，任何已经升级到 0.2.2 的用户按包名装到的都是 `0.1.20`，而它从没在 0.2.2 上验过。攒批的代价，不是错，但别忘。
