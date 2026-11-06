# P1 后半：`data → wire` 倒置走「能力接口」，端口跟着客户端走

- 日期：2026-11-06
- 状态：proposed（**第 1 批（会话族）+ 第 2 批（目录族）已落地**，其余未落码）
- 前情：`core → wire` 已归零（见 `implemented/2026-11-06-p1-dependency-inversion.md`）。
  这一篇只管 `data/` 剩下的 21 条 import。
- 进度（2026-11-06）：会话族与目录族都已倒置完（`app_model` 的 wire import 15 → **13**，
  `host_catalogs` 3 → **0**，`data/` 21 → **16**，`wire.` 44 → **29**），实际代价与偏差见
  `implemented/2026-11-06-p1b-batch1-session-family.md` 与
  `implemented/2026-11-06-p1b-batch2-catalog-family.md`。**未动**：预览族、收尾。
- 前置能力：`SyncClient` 已经是"能力接口"手法的先例（`core/sync_client.dart:207` 的
  `LinkControl`：**不往 `SyncClient` 加抽象方法**，因为全仓二十多个替身都 `implements SyncClient`，
  加一个方法就得改二十多处；改用小接口 + `is` 判定）。

## Problem

`data/` 还有 21 条 `import '../wire/…'`（**起草时的基线**；第 1 批落地后是 20 条，见上文进度），全是"读电脑侧的东西"：

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
2. `wire/host_rpc.dart`：`final class WireHostRpc implements HostRpc`，**持有那条
   `SyncClient`**（构造时给一次，方法不再收 `client`），并复用现有的 `loadXxx` 解码函数与
   `WireDiagnostics` 标签（报缺陷的那一处仍是知道形状的那一处）。
3. 客户端**只证明"我有一条 `HostRpc`"**：`abstract interface class HostRpcHolder`
   （1 个 `HostRpc get hostRpc`）。这样消费者只需 `hostRpcOf(client)`，
   **`SyncClient` 接口一个方法都不加** —— 二十多个替身一个都不用改。
   *（起草时写的是"`SyncClientImpl` 同时 implements `HostRpc`"；那一版会逼出
   "每个方法转发一遍"或一层转发基类，已被 `implemented/2026-11-06-p1b-hostrpc-holder.md`
   换掉。后面两批按**这一条**的形状做。）*
4. `AppModel` 内部：`HostRpc get _rpc`（`hostRpcOf(client)`，缺能力抛明确错误），
   44 处 `wire.loadXxx(client, …)` 变成 `_rpc.xxx(…)`；失败仍是 `null` + 诊断，行为不变。
5. 测试侧：`app/test/fake_sync_client.dart` 与 `app/integration_test/ui_flow_test.dart` 的
   `_FakeClient` 各加 `implements HostRpcHolder`，`hostRpc` **就是真的 `WireHostRpc(this)`** ——
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

1. **会话族**
   - **1a `session.projections`（已落地，2026-11-06）**：`SessionProjections` 搬进
     `core/session_projections.dart`、端口 `core/host_rpc.dart`、实现 `wire/host_rpc.dart`、
     `SyncClientDeps.hostRpc` 工厂、`AppModel._rpc`。见
     `implemented/2026-11-06-p1b-batch1-session-family.md`。
   - **1b `session.list`（已落地，2026-11-06）**：`SessionListPage` 搬进
     `core/session_list_page.dart`、端口加 `sessionRows(...)`。`wire/rpc/session.dart`
     仍被 create/fork/selectModel/cancel/queue 用着，所以 `data/` 的 import 条数不降
     （省下的是 `wire.` 字面量）。同上那篇笔记。
   - `session.page` / `session.refetch` **这一族里已经没有** —— P1 那批已按 `HistoryReader`
     倒置完（`core/history_page.dart`），本方案不再重复。
2. **目录族（已落地，2026-11-06）**：设置分区、权限目录、模型目录、Agent 预设、工作区、
   仓库信息、插件清单。四个值类型搬进 core（`SettingSection` / `RepoInfo` /
   `PluginInventory` / `WorkspaceSnapshot`），端口加七个方法；`host_catalogs.dart` 的
   3 条 wire import 清零。见 `implemented/2026-11-06-p1b-batch2-catalog-family.md`。
   端口形状当天收成了 `HostRpcHolder`（客户端只多一个 getter），
   见 `implemented/2026-11-06-p1b-hostrpc-holder.md`。
3. **预览族**：文件预览、目录列举、改动清单。
4. 最后清 `data/` 的 import 计数到 0（`projection.dart` 那条另算，见下）。

## 不在本方案里的一条

`data/projection.dart` 的那 1 条是**事件载荷的字段读者**（`readToolCall` 之类），
不是"读电脑侧"，不能塞进 `HostRpc`。它的正解与 `EventIdReaders` 同形：端口在 core、
实现与字段名在 wire；但那会连带 `projectEvent` 的 55 处调用点（见 implemented 那篇的末节），
所以**单独一批**做，不和本方案混在一起。

## 验收

- `git grep -c "import '\.\./wire/" -- app/lib/data` 从 4 个文件 / 21 条降到 **1 个文件 / 1 条**
  （只剩 `projection.dart`）。**当前：3 个文件 / 16 条**（`app_model` 13）。
- `SyncClient` 接口**没有新增成员**（`git diff app/lib/core/sync_client.dart` 只看得到
  `HostRpc` 的 import 与文档，看不到新方法）。
- 测试侧**没有任何夹具从 JSON 改成 DTO**（这条是硬约束）。原写"只改 2 个文件（两个假客户端）"，
  实测撞上第 3 类：三个用例里装原始投影 JSON 的字段本来就叫 `projections`，与能力成员同名
  ⇒ 编译期 `conflicting_field_and_method`，只改名（`projectionReply`）。合计 5 个测试文件。
- 门禁：analyze 0、`flutter test` 全过、boundary 全过、协议三条全过。
- 真机一次重连（改的是会话列表/翻页/设置这些读取路径）。**1a 没做**：读的形状与路径没变；
  剩下 1b 与 3 批落地后仍要补这一次。
