# Agent Note: 插件安装 / 卸载 —— 发起即返回 + 轮询，进度不新开帧

Status: implemented

## Problem

上一轮把插件的**清单 + 行级启停**接上了，安装 / 卸载 / 升级按"风险面另议"留着。
可用户在 Web 上能点那几个按钮，手机上一个都没有 —— 而 DSH 的方法面早就在：
`installBundle:835`、`waitForInstall:972`、`cancelInstall:982`、`removeBundle:999`、
`listBundles:463`。

真正的难点不是"接"，是**时长与形状**：

- `installBundle` / `removeBundle` **跑 pnpm 并等它结束**（`index.ts:835-965`）；
  一次真实安装常远超契约 §10 的 60 s 请求超时。手机不能"发出去等结果"。
- 进度是**流**（`plugin-manager/install-state` / `install-log`，`types.ts:335-361`），
  而我们的通道没有"全局推送帧"这回事（只有会话级的 `ev` 与一个 `status`）。

## Decision

**发起即返回 + 轮询，`requestId` 一次贯穿。**

1. `plugin.install` `{spec}` → 立刻回 `{requestId}`，`installBundle(spec, {requestId})` 在后台跑。
   **`requestId` 就是方法的幂等键**（分发器强制），也是宿主 `installs` 表里的控制块 id
   （`:837-841`）—— 同一次操作重发不会起第二遍 pnpm，取消与取结果用同一个 id。
2. `plugin.installStatus` `{requestId}` → `{status, kind?, phase?, log[], logTruncated, result?, error?}`。
   连接器在挂载时订阅宿主的两个事件、**按 requestId 收进有界的内存尾窗**
   （最后 4000 字符、最多 40 行、最多 16 条任务），并**明说截断**。
   **不新增帧类型**：手机轮询一个读方法（与 `session.projections` 同一种节奏）。
3. `plugin.cancelInstall` `{requestId}` → 宿主的 `cancelled | too-late | not-running` **原样**。
   不带幂等键：重复取消落到同一个终态。
4. `plugin.remove` `{name}` → 与安装同一形状（发起即返回，结论走 `installStatus`）。
   配套 `plugin.listBundles`：**卸载按包名**，而 `plugin.list` 给的是 Loader entry 行 ——
   一个包可以带多行，两者不是一回事；`removable` / `installed` 由宿主说，手机不猜。
5. 手机：插件页加"安装"（一次明确确认 + 输入 spec）与包段的"卸载"（仅 `removable` 可点，
   二次确认），任务卡显示 `headline`（宿主的 `application` / 错误原话）+ 阶段 + pnpm 输出尾部，
   跑的时候可取消。
6. **不做**：升级（`updateBundle` + `listVersions` 是另一组方法，等有人真用再说）与
   bundle 级启停（会连带改一串行）。

## Alternatives considered

1. **直接同步等（一个请求跑完）** —— 最强理由：最简单，一个方法一个结果。
   被否：契约 §10 的 60 s 请求超时先到，手机会显示"超时"而电脑侧还在装 —— 最坏的一种体验
   （用户重试 → 第二遍 pnpm）。
2. **加一条"安装进度"帧 / 订阅方法** —— 最强理由：进度能实时推，不用轮询。
   被否：那是**给协议加新通道**，与"只加窄口"的不变量冲突；而轮询一个读方法的
   数据源与它完全一样（宿主的两个事件），只是把推送换成了拉。
3. **把 pnpm 输出整包塞进结果** —— 被否：宿主的 `output` 默认截在 16 KiB
   （`config.outputBytes`），而我们的单帧 8 MiB（§40）要装下整个回复；尾窗 + `logTruncated`
   是诚实的做法。
4. **手机上自己判"能不能装"（版本兼容 / registry）** —— 被否：宿主有 `inspect` 前置与
   `ManagementError.code`，抄一份就是第二份真值。
5. **不接卸载，只接安装** —— 被否：装了就卸不掉是最难收拾的状态。

## Consequences

- **收益**：手机上能装、能卸、能看进度、能取消；安装不再被 60 s 超时打断。
- **代价**：轮询（1 s 一次，页面级参数）；安装期间手机要停在插件页才有进度
  （没有后台推送 —— 离开页面就看不到，回到页面靠 `installStatus` 再问）。
- **代价**：任务记录只在**这一代插件进程**里（重载 / 重启后 `unknown`）——
  宿主的 `waitForInstall` 也一样（"completed results are not retained"）。
- **代价**：日志只有尾部；完整输出仍在电脑上（宿主 `packageResult.logPath`，**不过线**）。
- **未做的**：升级、bundle 级启停、安装时的 `approvedBuilds` 交互（宿主要求显式批准
  构建脚本时，现在只会把 `pendingBuilds` 体现在失败原文里，手机没有"批准"按钮）。

## 判据

- connector **645 → 654**：`tests/plugin-install.test.ts` 8 条（发起即返回 / done 带结果 /
  进度尾窗与截断 / 取消三档 / 宿主抛错原话 / remove / unknown / 漏键被拦）+
  `tests/plugins.test.ts` 里 `plugin.listBundles` 一条。
- flutter **1218 → 1220**：`test/plugins_page_test.dart` +2（安装流程含轮询到结论、
  卸载只在 `removable` 的行出现且按包名发请求）。
- `pnpm exec tsc --noEmit` 0、`pnpm build` 过、`dart analyze --fatal-infos` 0、`dart format` 0。

## 代码入口回指

- 连接器：`connector/src/dsh/plugin-install.ts`（四个面 + 事件订阅 + 尾窗）、
  `connector/src/dsh/plugins.ts` 的 `listBundles`、`connector/src/handlers.ts`（四个方法 +
  安装面的幂等键要求）、`connector/src/protocol/methods.ts`（封闭集与幂等集）、
  `connector/src/index.ts` 的挂载点。
- 手机：`app/lib/model/plugins.dart` 的 `PluginBundle` / `PluginJob`、
  `app/lib/data/app_model.dart` 的 `installPlugin` / `removePluginBundle` /
  `pluginJobStatus` / `cancelPluginInstall`、`app/lib/ui/plugins_page.dart`（安装/卸载/任务卡）。
- 契约：`docs/subsystems/remote-channel.md` §5.7 的五行；边界见 `docs/plugin-and-jobs-notes.md` §A.4。
