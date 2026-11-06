# P1 后半第 2 批：目录族走 `HostRpc`（`data` 的 wire import 4 文件 → 3 文件）

- 日期：2026-11-06
- 状态：implemented（**第 2 批 / 共 4 批**；预览族、收尾仍在
  `proposed/2026-11-06-p1b-host-rpc-port.md`）
- 前情：第 1 批（会话族两半）见 `implemented/2026-11-06-p1b-batch1-session-family.md`。

## Problem

`data/` 还剩四组"读电脑侧"的调用认识线上形状：

| 位置 | 认的是什么 |
|---|---|
| `app_model.dart` | `settings.describe` / `repo.info` / `workspace.list` / `plugin.list`+`listBundles` |
| `host_catalogs.dart`（**3 条 wire import**） | `session.modelCatalog` / `permission.catalog` / `agentPresets.list` |

`app_model.dart` 里 `wire.` 还有 33 处；`host_catalogs.dart` 整份文件只为三个读口而 import `wire/`。

## Decision

1. **四个"解好的值"搬进 core**（键名 / 拆包 / 坏字段处置仍留在各自 `wire/rpc/*.dart`）：
   - `SettingSectionWire` → `core/setting_section.dart` 的 `SettingSection`
   - `RepoInfoWire` → `core/repo_info.dart` 的 `RepoInfo`
   - `PluginInventoryWire` → `core/plugin_inventory.dart` 的 `PluginInventory`
   - `WorkspaceSnapshot` → `core/workspace_snapshot.dart`（原名搬走，没有 `Wire` 后缀）
   **搬的同时去掉 `Wire` 后缀**：那个后缀在 `wire/` 里表示"这是线上形状"，
   搬进 core 之后它恰好说反了（这些是解好的值）。
2. **`HostRpc` 加七个方法**：`settings` / `modelCatalog` / `permissionCatalog` /
   `agentPresets` / `workspaces` / `repoInfo` / `plugins`。其中三个直接回
   `model/` 里的既有类型（`ModelCatalog` / `PermissionCatalog` / `AgentPresetRoster`）——
   **没有 DTO 要搬，只搬调用口**。
3. **`ForwardingHostRpc`（core，本批当时的结构决定；已被取代，见末尾）**：
   连接层与两个测试假客户端都是
   "能力在我身上、活儿在 `wire/`"的同一形状。九个方法让三处各抄一遍 = 27 处样板，
   加一个方法要改四处、漏一处还是编译错误或某个替身悄悄不转发。收成一处：
   实现方只给一个 `HostRpc get target`。于是
   `_SyncClient extends ForwardingHostRpc`、`FakeSyncClient extends ForwardingHostRpc`、
   `ui_flow_test.dart` 的 `_FakeClient extends ForwardingHostRpc` 各只剩一个 getter。
   **真正的实现仍只有 `wire/host_rpc.dart` 一处**（它直接 `implements HostRpc`，
   不转发给谁，避免"能力的实现只是转发给能力"的空转）。
   **这一条已被取代**：`ForwardingHostRpc` 当天就换成了 `HostRpcHolder`（1 个 getter）
   —— 那层转发与"方法还要收一个 `client`"都是自造问题，见
   `implemented/2026-11-06-p1b-hostrpc-holder.md`。
4. **`hostRpcOf(client)`（core）**：缺能力时的判据与错误文案只写一处
   （`AppModel._rpc` 与 `HostCatalogs._rpc` 都调它，判的是 `client is HostRpcHolder`）。
   缺能力是装配错误 ⇒ 抛，不静默降级。
5. `HostCatalogs` 的三条 wire import 全部消失（改用 `_rpc`）；`app_model` 四个读口改 `_rpc`，
   `wire/rpc/repo.dart` 那条 import 随之删掉（`loadRepoInfo` 是它唯一的用处）。

## 代价与留下的边界

- **测试侧又多两个字段改名**：`conversation_hero_test` / `new_session_workspace_test` 里装
  `workspace.list` 原始应答的字段 `workspaces` → `workspacesReply`（与 `HostRpc.workspaces`
  同名 = 编译期 `conflicting_field_and_method`）。累计五个测试文件只因"字段名撞端口方法名"
  改名，值一律没动。**这是这套命名法的已知代价**：端口方法按"方法名去掉 `session.`/`settings.`
  那一段"取名词，而夹具里装原始应答的字段天然想叫同一个词。
- **`wire_shapes_replay_test` 改了 11 处类型名 + 3 条 import**：它是线上形状的回放用例，
  改名后读的是 core 的值类型。**金样文件与断言值一个字没动**（仍是那一份
  `connector/tests/fixtures/wire-shapes.json`），所以"线上形状变了会红"这条保证不变。
- `settings.update`（写）仍在 `wire/`，但返回类型已经是 core 的 `SettingSection?` ——
  写操作整体留到收尾批。
- `plugins` 是端口里**唯一没有摘要三态**的方法（`loadPluginInventory` 本来就是
  `Future<PluginInventory?>`，两侧都读不出才 null）；端口没有把这条判据重写一遍。
- 老边界仍在：`core → model` 的类型环（值对象的字段类型来自 `model/`），详见第 1 批那篇。

## 验证

- `cd app; dart analyze --fatal-infos lib test` → No issues found；
  `dart analyze --fatal-infos integration_test` → No issues found。
- `cd app; flutter test` → **1759** 全过（与第 1 批同数：没有新增用例，也没有删）。
- `node app/tools/verify-platform-boundary.mjs` → **791** 项全过（179 → **183** 个 Dart 文件，
  本批新增 4 个值类型文件）。
- `node protocol/verify-{fixtures,loopback,vectors}.mjs` → 454 / 26 / 49 全过（没动 `protocol/`）。
- `node app/tools/verify-rpc-single-caller.mjs` → PASS。
- `git grep -c "import '\.\./wire/" -- app/lib/data` → **4 个文件 / 20 条 → 3 个文件 / 16 条**：
  `app_model` 14 → **13**，`host_catalogs` 3 → **0**（不再出现在清单里），
  `file_preview` 2、`projection` 1 不动；`-- app/lib/core` 仍是 **0**。
- `app_model.dart` 里 `wire.` 出现次数：33 → **29**。
- **变异校验**：`WireHostRpc.workspaces` 改成恒返回 `body(null)` ⇒
  `new_session_workspace_test` + `conversation_hero_test` + `workspace_actions_test`
  三个文件 **12 条红**（共 37 条）；还原后 37 条全绿。
- `dart format --output=none --set-exit-if-changed lib test integration_test`：0（本批前已
  把 HEAD 上遗留的 14 个文件格式化干净，见 `edad912`）。

## 没做的

- 预览族（文件预览 / 目录列举 / 改动清单）、收尾（各写操作 + `projection.dart` 那条）——
  施工图在 `proposed/` 那篇。
- **真机**：本批只换调用口，读的形状与摘要路径都没变，未跑。
