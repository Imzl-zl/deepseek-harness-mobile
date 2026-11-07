# 交接：DSH 0.2.2 抬线（已发布，三条链已验）

Status: implemented

## 2026-11-07 真机三条链结果

环境：DSH `0.2.2-rc.1` 隔离宿主 + `dsh-mobile-connector@0.1.21` + `v0.2.9` APK（安卓，
`adb` 直连）。宿主额外挂了 `e2e-lan-model.patch.yml`：连接器 `18791`、`listenHost 0.0.0.0`、
中转指向本机死端口（**不碰生产中转**）、模型 `xfyun/spark-x2.6`。手机走 LAN-only 配对，
面板显示 `1 / 1 台在线 · 正在服务`。

| 链 | 真机证据 | 结论 |
|---|---|---|
| 投影 | 手机发「请只回复投影链路」；电脑侧完成，手机底部统计条 `10.9K tok · 缓存命中 18%`、上下文 `9%`，与电脑侧 `10.9K tok · 上下文 9%` 一致 | 通过 |
| 子代理 | 手机发子代理指令；电脑侧子会话 `7753b1e9-2683-461c-9a72-2ac375de71f5` `finished`。手机右抽屉「子智能体」出现一行：标题 `Reply exactly SUBAGENT...`（子任务标题，**不再是会话 UUID**）、副标题 `Reply with exactly the text: ...`、`78.4K tok`、绿色完成点；顶栏计数 `1` | 通过（链） |
| 审批 | 手机要求用 `write` 工具写工作区外文件；手机出现「等待审批」卡，正文 `escalate sandbox to danger-full-access: Create the requested new file at C:/Users/zhanglu/dsh-approval-write.txt outside the session workspace.`，按钮 `拒绝` / `允许一次`。点「允许一次」后 `write`/`read` 工具卡变绿，文件内容 `APPROVAL_OK` | 通过 |

审批链的一个**测试口径**：第一次让模型用 shell 写系统临时目录，Windows 宿主没有沙箱拦截，
命令直接成功、没有审批卡；换 `write` 工具写工作区外才触发 `danger-full-access` 申请。
所以"shell 能写"不等于"审批门失效"——要验审批必须走会被沙箱拦的那条路。
子代理那轮的子会话回的是"没有实质任务"的拒绝句，这是模型对梗式 prompt 的内容反应，
不是目录/面板链路的失败；UI 的 name、状态、token 都已按时出现。

## 后记（2026-11-06）

`v0.2.9` 标签把 `0.1.21` 一并发到了 npm。这**不是意外**：`publish-connector.yml:19` 同时监听
`v*` 与 `connector-v*`，而 npm 发布那一步没有标签守卫（守卫只加在"版本与标签一致"那一步），
注释写明"两个标签指向同一次发布"。所以只要 `connector/package.json` 是 `0.1.21`，打任何
`v*` 都会发它 —— 下面"未发版"的结论在本次发版后作废；当时未验证的第 1 条已在
2026-11-07 补上（见本文开头）。

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
boundary 728）；2026-11-07 收尾后的数字看 `tools.md`（844 / 1762 / 833）。

## 已验证（2026-11-05 那次，可复现）

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

## 当时未验证（2026-11-07 已补）

- **三条链真实往返**：投影 / 子代理 / 审批已在真机跑通，证据见上表。
- **手机侧 `name`**：真机看到的是子任务标题，不再是会话 UUID；副标题是首条指令。
- **`path` 没做**：它在 `listDescendants()` 的返回里，而我们的目录走 `subagentCatalog` 投影，
  那条调用面没接。层级已由树表达。这一项仍是缺口，不是本轮回归。
- **0.2.2 其余 19 条是"读源码判不命中"**，不是运行时证明。
- **`protocol/verify-*` 与 relay 门禁**当时没跑；2026-11-07 收尾已补跑，全绿。

## 三条链怎么测（2026-11-07 实际用的）

- 测试根目录：`D:\sudy\myproject\dsh-e2e-022`（仓库外）
  - **0.2.2 宿主**：`node_modules\.bin\dsh.cmd`，`DSH_HOME=<root>\home`，profile `e2e`
  - 覆盖：`<root>\port.patch.yml`（网页 13080、连接器 18790）+ `<root>\e2e-lan-model.patch.yml`
    （连接器 `18791`、`listenHost 0.0.0.0`、中转指向本机死端口、模型 `xfyun/spark-x2.6`）
- 手机与电脑同一 WiFi；浏览器开 `http://127.0.0.1:13080/?token=…` → 管理面出码 → 手机扫码。
- 验什么：统计条（投影链）、右抽屉子代理面板（catalog v3 + `name`）、审批卡（interaction 链）。
- 模型 key 只在启动进程的环境变量里，不写进配置、不写进仓库；测完停止宿主、清掉临时文件。

## 发版步骤

1. 跑完整门禁：`node protocol/verify-fixtures.mjs && verify-loopback.mjs && verify-vectors.mjs`；`cd relay && pnpm typecheck && node --test`；`cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test`；`cd app && dart analyze --fatal-infos lib test integration_test && flutter test`
2. 决定入库方式：这个仓库两种历史都有（`(#3)`/`(#2)` 走 PR，`0a5556c` 直接提交）。走 PR 就先推 `feat/…` 分支。
3. 打 `connector-v0.1.21`（CI 校验 `标签 == package.json` 后 OIDC 发布；npm 上已有同版本则幂等跳过）。
4. 发完更新 `memory.md`（它只写闭环后的现状）。

## 一个必须知道的风险

`0.1.20` 的上界是旧写法 `>=0.2.1-rc.5 <0.2.2`，`includePrerelease` 下**放行 0.2.2 的预发布**（实测）。所以在 `0.1.21` 发出之前，任何已经升级到 0.2.2 的用户按包名装到的都是 `0.1.20`，而它从没在 0.2.2 上验过。攒批的代价，不是错，但别忘。
