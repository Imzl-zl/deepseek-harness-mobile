# P1 后半：`data → wire` 倒置走「能力接口」，端口跟着客户端走

- 日期：2026-11-06
- 状态：proposed（设计已定，未落码）
- 前情：`core → wire` 已归零（见 `implemented/2026-11-06-p1-dependency-inversion.md`）。
  这一篇只管 `data/` 剩下的 21 条 import。
- 前置能力：`SyncClient` 已经是"能力接口"手法的先例（`core/sync_client.dart:207` 的
  `LinkControl`：**不往 `SyncClient` 加抽象方法**，因为全仓二十多个替身都 `implements SyncClient`，
  加一个方法就得改二十多处；改用小接口 + `is` 判定）。

## Problem

`data/` 还有 21 条 `import '../wire/…'`，全是"读电脑侧的东西"：

| 文件 | 条数 | 用到的东西 |
|---|---|---|
| `app_model.dart` | 15 | 35 处 `wire.loadXxx(client, …)`（会话列表/翻页/设置/权限/目录/仓库/工作区/插件/文件预览…） |
| `host_catalogs.dart` | 3 | 设置分区、权限目录、模型目录 |
| `file_preview.dart` | 2 | 文件预览、目录列举 |
| `projection.dart` | 1 | 事件载荷的字段读者（**这一条不属于本方案**，见末节） |

`app_model.dart` 里 `wire.` 出现 **44 次**。方向问题：`data` 认识"应答长什么样"，而字段名只该在
`wire/` 断言。

## Decision

**端口声明在 `core/`，实现是 `wire/` 的一个类，客户端把它作为能力暴露。**

1. `core/host_rpc.dart`：
   - `abstract interface class HostRpc`（一个方法族一组，共约 35 个方法，全部返回 core 类型或 `null`）；
   - 应答 DTO 搬进 core（6 个）：`SessionListPage` / `SessionProjections` / `SettingSection` /
     `RepoInfo` / `PluginInventory` / `WorkspaceSnapshot`。它们**只描述"解好的值"**，
     字段名与线上类型仍只在 `wire/` 断言。
2. `wire/host_rpc.dart`：`final class WireHostRpc implements HostRpc`，包一层 `SyncClient`
   并复用现有的 `loadXxx` 解码函数与 `WireDiagnostics` 标签（报缺陷的那一处仍是知道形状的那一处）。
3. `SyncClientImpl` **同时 implements `HostRpc`**（把调用转给注入的 `WireHostRpc`）。
   这样 `AppModel` 只需 `client is HostRpc`，**`SyncClient` 接口一个方法都不加** —— 二十多个替身
   一个都不用改。
4. `AppModel` 内部：`HostRpc get _rpc`（`client is HostRpc ? client : throw 明确错误`），
   44 处 `wire.loadXxx(client, …)` 变成 `_rpc.xxx(…)`；失败仍是 `null` + 诊断，行为不变。
5. 测试侧：`app/test/fake_sync_client.dart` 与 `app/integration_test/ui_flow_test.dart` 的
   `_FakeClient` 各加 `implements HostRpc`，**实现全部转给真的 `WireHostRpc(this)`** ——
   于是现有 `onCall: (m, p) => {raw JSON}` 的夹具**一行都不用改**，而且仍然在跑真的解码器
   （这是本方案相对"给 AppModel 加必填端口"的关键好处：那会逼所有夹具从原始 JSON 改写成 DTO，
   等于把解码器从测试路径上摘掉）。

## 被否掉的

- **给 `AppModel` 加必填 `HostRpc` 参数**：74 个测试文件直接 `AppModel(...)`，加必填参数 = 100+ 处
  改动；而且夹具会从"原始协议 JSON"退化成"手搓 DTO"，**测试不再覆盖解码器**。
  实际成本中心是测试夹具，不是接口 —— 这也是本方案要绕开的。
- **把 `HostRpc` 加进 `SyncClient` 接口**：`core/sync_client.dart:207` 早就否过这个手法
  （二十多个替身要跟着改），能力接口是既有先例。
- **把 6 个 DTO 留在 `wire/`、端口只返回 `Map`**：那等于让 `data` 继续认线上形状，白做。

## 落地顺序（一个方法族一批，每批全绿再下一批）

1. **会话族**：`session.list` / `session.page` / `session.projections` / `session.refetch`
   （`refreshSessionRows` / 打开会话 / 翻页三条路径）—— 用它验证模式，跑全部门禁。
2. **目录族**：设置分区、权限目录、模型目录、Agent 预设、工作区、仓库信息、插件清单。
3. **预览族**：文件预览、目录列举、改动清单。
4. 最后清 `data/` 的 import 计数到 0（`projection.dart` 那条另算，见下）。

## 不在本方案里的一条

`data/projection.dart` 的那 1 条是**事件载荷的字段读者**（`readToolCall` 之类），
不是"读电脑侧"，不能塞进 `HostRpc`。它的正解与 `EventIdReaders` 同形：端口在 core、
实现与字段名在 wire；但那会连带 `projectEvent` 的 55 处调用点（见 implemented 那篇的末节），
所以**单独一批**做，不和本方案混在一起。

## 验收

- `git grep -c "import '\.\./wire/" -- app/lib/data` 从 4 个文件 / 21 条降到 **1 个文件 / 1 条**
  （只剩 `projection.dart`）。
- `SyncClient` 接口**没有新增成员**（`git diff app/lib/core/sync_client.dart` 只看得到
  `HostRpc` 的 import 与文档，看不到新方法）。
- 测试侧只改 2 个文件（两个假客户端），**没有任何测试夹具从 JSON 改成 DTO**。
- 门禁：analyze 0、`flutter test` 全过、boundary 全过、协议三条全过。
- 真机一次重连（改的是会话列表/翻页/设置这些读取路径）。
