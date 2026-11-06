# P1 后半第 1 批：会话族走 `HostRpc`（`data → wire`：app_model 15 → 14）

- 日期：2026-11-06
- 状态：implemented（**第 1 批 / 共 4 批**，两半都在这一篇：1a `session.projections`、
  1b `session.list`；目录族、预览族、收尾仍在
  `proposed/2026-11-06-p1b-host-rpc-port.md`）
- 前情：`core → wire` 已归零（`implemented/2026-11-06-p1-dependency-inversion.md`），
  `data → wire` 剩 21 条、分四批倒置。

## Problem

`data/app_model.dart` 认识线上形状：`session.projections` 的解码结果
`SessionProjections` 与调用口 `loadSessionProjections` 都从 `wire/rpc/projections.dart`
来（9 次字面量），`session.list` 的一页类型 `SessionListPage` 与调用口 `loadSessionList`
从 `wire/rpc/session.dart` 来（2 次）。方向问题与 P1 同源：`data` 应该只认"解好的值"，
字段名与类型只该在 `wire/` 断言。

## Decision

1. `core/host_rpc.dart`（新）：`abstract interface class HostRpc`。本轮只有
   `projections(...)` 一个方法。**端口做成能力口**：`SyncClient` 接口一个成员都不加
   （延续 `core/sync_client.dart` 的 `LinkControl`：全仓二十多个替身是
   `implements SyncClient` 的，加一个抽象方法就得改二十多处）。
2. `core/session_projections.dart`（新）：值对象 `SessionProjections` 从 `wire/rpc/`
   **搬**进来。搬的只是"解好的值"——15 个键的键名、字段类型、认不出时的降级仍只在
   `wire/rpc/projections.dart` 的 `_buildProjections` 里出现。
3. `wire/host_rpc.dart`（新）：`final class WireHostRpc implements HostRpc`，方法体一行
   `loadSessionProjections(client, sid: sid)`。**不加任何判据**：发请求、带摘要、解码、
   `WireDiagnostics` 计数仍全在 `loadSnapshot` / `loadXxx` 那一处（报缺陷的与知道形状的
   必须是同一处）。
4. `SyncClientDeps.hostRpc`（必填，类型是**工厂** `HostRpc Function(SyncClient)`）：
   能力属于这一条连接，而连接是 `createSyncClient` 拿到 deps 之后才成立的。
   `_SyncClient implements HostRpc`，方法转给 `late final _rpc = _deps.hostRpc(this)`。
   连接层因此**不必 import `wire/`**。
5. `AppModel._rpc`：`client is HostRpc` 取能力（显式转换，与
   `core/snapshot_call.dart` 同一个手法），取不到就 `throw StateError`（缺能力是装配错误，
   不是"这台电脑读不出投影"）。6 处 `wire.SessionProjections` / `wire.loadSessionProjections`
   换成 core 类型与 `_rpc.projections(client, sid: sid)`；`import '../wire/rpc/projections.dart'`
   随之删掉（analyze 的 `unused_import` 也会拦）。
6. 装配点各加一行 `hostRpc: WireHostRpc.new`：`main.dart` ×2、两个 `integration_test/`、
   `test/sync_client_test.dart`。
7. 测试侧两个假客户端（`test/fake_sync_client.dart`、`integration_test/ui_flow_test.dart`
   的 `_FakeClient`）`implements HostRpc`，实现**就是** `WireHostRpc(this)`。
8. **1b `session.list`（同一天的第二个提交）**：`SessionListPage`（`sessions` + `hasMore`
   那个 record）搬进 `core/session_list_page.dart`，端口加
   `sessionRows(client, {limit, offset})`，`WireHostRpc` 一行转到 `loadSessionList`，
   `app_model._fetchSessionRows` 改成 `_rpc.sessionRows(...)`。
   **`data/app_model.dart` 的 wire import 计数不变（14）** —— `wire/rpc/session.dart`
   仍被 `createSession` / `forkSession` / `selectModel` / `cancelSession` /
   `updateQueueAction` 用着，这一半省下的是 `wire.` 字面量（35 → 33），不是 import 条数。
   加端口成员时**只有三处**跟着改：`_SyncClient`、`FakeSyncClient`、`ui_flow_test.dart`
   的 `_FakeClient`（各一个 `@override`）—— 21 个 `SyncClient` 替身一处都没动，
   这正是能力口相对"往 `SyncClient` 加抽象方法"的差别。

## 两处与施工图的偏差（都是实测撞出来的）

1. **端口返回 `SnapshotReply<SessionProjections?>`（三态），不是裸 `SessionProjections?`。**
   施工图写"失败返回 null"；而这条路径本来就是三态：`notModified`（摘要命中）与
   "读不出"在调用方是**相反**的处理 —— 前者什么都不动（不清数据、不报错、不通知），
   后者要把目录打成 `failed` 并落一条 `lastError`。压成裸 `null` 会让摘要命中时
   **报错并清空子智能体目录**，等于把 2026-11-01 那批摘要的收益反做一遍。
   `SnapshotReply` 本来就在 core（`core/snapshot_digest.dart`），端口复用它不引入新概念。
   施工图里"6 处"相应是 9 处字面量（8 处类型 + 1 处调用）。
2. **顺手改了 3 个测试文件里的一个字段名**：`widget_test` / `conversation_hero_test` /
   `trajectory_outline_test` 里装"原始投影 JSON"的字段 `projections` → `projectionReply`。
   原因：`FakeSyncClient` 一 `implements HostRpc`，能力成员就叫 `projections`，
   字段与方法同名是**编译期错误**（`conflicting_field_and_method`）。
   改的只是名字，**值与形状一个字没动**（仍是原始协议 JSON，用例的 `call` 照旧返回它）。

## 被否掉的

- **给 `AppModel` 加必填 `HostRpc` 参数**：74 个测试文件直接构造 `AppModel`，加必填参数 =
  100+ 处改动，而且夹具会从"原始协议 JSON"退化成"手搓 DTO" —— 等于把解码器从测试路径上摘掉。
- **把 `HostRpc` 加进 `SyncClient` 接口**：`LinkControl` 早否过一次（二十多个替身要跟着改）。
- **端口只返回 `SessionProjections?`**：丢掉 `notModified`，见上。
- **让 `WireHostRpc` 有状态**（存下构造时那个 `client`）：端口方法本身就收 `client`，
  存一份只多一个"能力挂在 A、却拿 B 发请求"的口子。工厂参数因此是通配的
  （`const WireHostRpc(SyncClient _)`），代价只写在构造器的文档里。

## 代价与留下的边界

- **`core → model` 是一条新的边**：`SessionProjections` 的 15 个字段里 10 个的类型来自
  `model/`（`TokenUsage` / `ModelRef` / `TrajectoryView` / `GoalView` …），而
  `model/chat_item.dart`、`model/subagent.dart`、`model/permission.dart` 又 import
  `core/job.dart` / `core/endpoint.dart` / `core/json_field.dart`
  ⇒ 出现 `core/session_projections.dart ↔ model/*` 的**纯类型环**（Dart 允许，没有初始化环）。
  端口留在 core 是施工图定下的（`data/` 认的那一面）；要拆掉这条环得先把
  `ModelRef` / `SubagentTiming` 这些类型也挪一层，不在这一批的范围里。
- `core/sync_client.dart ↔ core/host_rpc.dart` 互相 import（deps 要 `HostRpc` 的类型、
  端口要 `SyncClient` 的类型），同上，纯类型。
- `wire/rpc/projections.dart` **re-export** 了 `SessionProjections`：`readSessionProjections`
  的调用方（`wire_shapes_replay_test` 等）因此不必改 import。`data/` 不走这条路。
- 诊断口径没变：形状坏了仍然计一次 `WireDiagnostics`（`session.projections`），
  位置仍在 `wire/`。
- 测试夹具**一行都没从 JSON 改成 DTO**。

## 验证

1a 与 1b 各跑了一遍全部门禁，数字都记在下面（1b 那一遍是最终值）。

- `cd app; dart analyze --fatal-infos lib test` → No issues found；
  `dart analyze --fatal-infos integration_test` → No issues found。
- `cd app; flutter test` → **1759** 全过（两批都与改前同数：没有新增用例，也没有删）。
- `node app/tools/verify-platform-boundary.mjs` → **775** 项全过（175 → **179** 个 Dart 文件；
  1a 加 3 个、1b 加 1 个）。
- `node protocol/verify-{fixtures,loopback,vectors}.mjs` → 454 / 26 / 49 全过（没动 `protocol/`）。
- `node app/tools/verify-rpc-single-caller.mjs` → PASS（`wire/` 外没有 `call<`）。
- `git grep -c "import '\.\./wire/" -- app/lib/data` → `app_model` **15 → 14**（1b 不再降，
  原因见 Decision 第 8 条），其余三个文件不动；`-- app/lib/core` 仍是 **0**（新端口没把这条边带回来）。
- `app_model.dart` 里 `wire.` 出现次数：44 → **33**（1a 去掉 9 处、1b 去掉 2 处）。
- `git diff app/lib/core/sync_client.dart` 只看得到 import 与 `SyncClientDeps` 那一个必填项，
  **`SyncClient` 接口成员一处没动**。
- **变异校验（两批各一次）**：
  - 1a：`WireHostRpc.projections` 改成恒返回 `body(null)` ⇒ `trajectory_outline_test` +
    `goal_bar_test` **19 条红**（例：goal_bar 的"两条 dock 同时在场时的上下顺序"找不到
    `GoalBar`）；还原后两个文件 40 条全绿。
  - 1b：`WireHostRpc.sessionRows` 改成恒返回空页 ⇒ `session_list_paging_test` +
    `session_list_wiring_test` + `session_drawer_test` **14 条红**（三个文件共 37 条）；
    还原后 37 条全绿。
- `dart format --output=none --set-exit-if-changed lib test integration_test`：本批**没有新增**
  不合规文件（HEAD 上本来就有 14 个，逐条比对过；本批新写的 4 个文件全绿）。

## 没做的

- 目录族（设置分区 / 权限目录 / 模型目录 / Agent 预设 / 工作区 / 仓库信息 / 插件清单）、
  预览族（文件预览 / 目录列举 / 改动清单）、收尾三批 —— 施工图在 `proposed/` 那篇。
- **真机**：本轮不需要（读的形状与路径没变，仍是同一批 `loadXxx` 与同一条
  `callSnapshot` 摘要路径）。refetch 分支的真机验证仍按
  `implemented/2026-11-06-p1-dependency-inversion.md` 记的延后。
- 两个**待拍板的产品问题**没碰：投影读失败时整条会话判成不可用；
  有缓存时抽屉里 `session.list` 失败不可见。
