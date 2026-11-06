# P1 后半第 4 批（收尾）：读 / 写两个口，`data/` 只剩 `projection.dart` 一条

- 日期：2026-11-06
- 状态：implemented（**第 4 批 / 共 4 批**；`data → wire` 倒置完成，`projection.dart`
  那一条按施工图**不属于本方案**，见末节）
- 前情：第 1 批（会话族）、第 2 批（目录族）、第 3 批（预览族）、端口形状复盘
  （`…-hostrpc-holder.md`）。

## Problem

收尾批要搬的是 `app_model` 里最后 27 处 `wire.`（22 个写操作 + 5 个零散读）。拼到最后
暴露出一个形状问题：**读和写的失败语义相反**。

| | 读 | 写 |
|---|---|---|
| 失败 | 那些面显示**空态**，人继续用 | **必须大声**（答案/操作没进去） |
| 参数 | `sid` / `limit` / `path` | 都带**幂等键** `requestId`（契约 §5.6） |
| 传输 | 即时请求 | 走 outbox（先落盘再发） |
| 谁需要 | `AppModel` / `HostCatalogs` / `FilePreview` | `AppModel` |

混在一个口里，调用点就看不出"这一次失败该空着还是该报错"，这条判据会散到每个
`try/catch` 里。

## Decision

1. **切两个口**：`HostReads`（18 个方法）与 `HostWrites`（22 个）。`HostRpcHolder`
   只多两个 getter（`reads` / `writes`），三个实现方（`_SyncClient`、`FakeSyncClient`、
   `ui_flow_test.dart` 的 `_FakeClient`）各两行。
2. **实现拆成两个薄文件**：`wire/host_reads.dart` / `wire/host_writes.dart`，每个方法一行；
   `wire/host_rpc.dart` 只剩装配（`late final reads/writes`）。
3. **装配点一行都没改**：`hostRpc: WireHostRpc.new` 还是那个工厂，只是 deps 的类型从
   `HostRpc Function(SyncClient)` 变成 `HostRpcHolder Function(SyncClient)`。
   —— 这是"能力持有者"那次改造的直接红利（工厂造的是"一对口"，不是"一个口"）。
4. **适配器里的 `rpc/*.dart` 一律 `as wire` 前缀**：`createSession` / `killJob` /
   `cancelSession` / `pluginJobStatus` 这些名字在端口与 `wire/` 里**同名**，不带前缀的调用
   会解析回本类的方法（无限递归，或"参数个数不对"）。与 `data/app_model.dart` 原来
   用 `as wire` 是同一个理由。
5. **端口按"做什么"命名，不照抄方法名**（映射只写在 `wire/host_writes.dart` 一处）：
   `updateQueue` ← `updateQueueAction`、`installPlugin` ← `startPluginInstall`、
   `removePlugin` ← `removePluginBundle`、`cancelPluginInstall`、
   `pinSession` / `unpinSession` / `archiveSession` / `unarchiveSession` / `moveSession` /
   `moveWorkspace` ← `workspace.*`、`followJob` / `unfollowJob` / `killJob` ← `job.*`。

## 代价与留下的边界

- **端口的绝对大小**：`HostReads` 18 + `HostWrites` 22 = 40 个方法。这是"`data/` 不认识
  线上形状"这条边界的一次性总价；换来的是 `data/` 里**一条 wire import 都不剩**
  （除了 `projection.dart`），`app_model` 的 `wire.` 从 44 处降到 0。
- **`sendPrompt` 没搬**：它的唯一调用点在 `ui/chat_page.dart`（直接 import
  `wire/rpc/session.dart`）。把它塞进写口而不改那个调用点，会多一个没人用的接口成员；
  而顺带改 `ui/` 是另一条病（`ui → wire`），不在本方案范围。**已知遗留**。
- **写口里三个任务订阅没有幂等键**（`followJob` / `unfollowJob` / `killJob`）：
  那是 `wire/` 这几条方法的既有形状（宿主不给），不是端口漏了。
- 写方法**自己不判成功**：回执认不出仍是 `wire/` 的 `valueOrReport` 计一次数、回 `null`，
  调用方（`AppModel`）据此如实报错 —— 与搬移前逐字相同。
- 老边界仍在：`core → model` 的纯类型环（值对象的字段类型来自 `model/`）。

## 验证

- `cd app; dart analyze --fatal-infos lib test` → No issues found；
  `dart analyze --fatal-infos integration_test` → No issues found。
- `cd app; flutter test` → **1759** 全过（同数）。
- `node app/tools/verify-platform-boundary.mjs` → **797** 项全过（183 → **185** 个 Dart 文件：
  `wire/host_reads.dart` + `wire/host_writes.dart`）。
- `node protocol/verify-{fixtures,loopback,vectors}.mjs` → 454 / 26 / 49 全过（没动 `protocol/`）。
- `node app/tools/verify-rpc-single-caller.mjs` → PASS。
- `dart format --output=none --set-exit-if-changed lib test integration_test` → 0。
- `git grep -c "import '\.\./wire/" -- app/lib/data` → **2 个文件 / 12 条 → 1 个文件 / 1 条**
  （`app_model` 11 → **0**、`projection` 1 不动）；`-- app/lib/core` 仍 **0**。
  **这是施工图的终态**：`projection.dart` 那一条另算。
- `app_model.dart` 里 `wire.` 出现次数：27 → **0**（起点 44）。
- **变异校验**：`WireHostWrites.respondInteraction` 改成空实现（写操作"静默没发出去"）⇒
  `chat_takeover_wiring_test` + `interaction_wiring_test` + `takeover_test`
  三个文件 **4 条红**（共 53 条）；还原后 53 条全绿。

## 没做的（施工图里明确不在本方案）

- `data/projection.dart` 的那 1 条：它是**事件载荷的字段读者**，正解与 `EventIdReaders`
  同形（端口在 core、字段名在 wire），但会连带 `projectEvent` 的 55 处调用点，
  按施工图**单独一批**。
- `ui/chat_page.dart` 直接调 `sendPrompt`：同上，另一条病。
