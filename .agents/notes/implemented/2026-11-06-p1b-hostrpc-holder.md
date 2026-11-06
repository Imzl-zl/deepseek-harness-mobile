# 把 `HostRpc` 收成「能力持有者」（换掉 `ForwardingHostRpc`）

- 日期：2026-11-06
- 状态：implemented（**取代** `implemented/2026-11-06-p1b-batch2-catalog-family.md` 的
  Decision 第 3 条：`ForwardingHostRpc`）
- 触发：用户看完第 1、2 批的汇报后问"架构设计还好吗？怎么这么复杂"。

## Problem

第 1 批为了让 `client is HostRpc` 这句话成立（沿用 `LinkControl` 的先例），让连接层
**自己实现**这个能力。但连接层自己不会干活——活全在 `wire/` 里。于是每个方法都是一行
`=> target.xxx(...)`；到目录族有九个方法、三个实现方（连接层 + 两个假客户端）时，
就是二十七处纯转发样板，加一个方法要改四处。

第 2 批为此加了 `ForwardingHostRpc`（core）把转发收成一处。**那是在给自己制造的问题
打补丁**：多出一层中转，加一个抽象类，而且端口方法还得额外收一个 `SyncClient` 参数
（能力本来就由那条连接造出来，调用点再传一遍同一个对象），为此写了一段文档解释
"它不是两处水位"——**一个需要写文档才说得通的参数，本身就是设计有味儿了的信号**。

## Decision

1. **`HostRpc` 自己持有连接**：`WireHostRpc(client)` 存下它（`final SyncClient client`），
   九个方法**不再收 `client`**。调用点从 `_rpc.projections(client, sid: x)` 变成
   `_rpc.projections(sid: x)`。
2. **客户端只证明"我有一条 `HostRpc`"**：新增 1 成员接口
   `abstract interface class HostRpcHolder { HostRpc get hostRpc; }`。
   `_SyncClient` / `FakeSyncClient` / `ui_flow_test.dart` 的 `_FakeClient` 各一个
   `late final HostRpc hostRpc = ...(this)`，**九个方法一个都不用写**。
3. `core/host_rpc.dart` 的 `ForwardingHostRpc` 整个删除（约 60 行纯转发 + 3 处
   `extends` 改回 `implements`）。
4. `hostRpcOf(client)` 保留，判据改成 `client is HostRpcHolder ? client.hostRpc : throw`；
   `SyncClientDeps.hostRpc` 仍然是**工厂**（能力要用 `this` 造，那时 `this` 还没成立）。

**为什么 `LinkControl` 的先例不适用**：`LinkControl.disconnect()` 的活是客户端自己干的
（关 socket、停定时器），所以"客户端就是那个能力"是事实；`HostRpc` 的活是**解码**，
在 `wire/` 里。同一手法套过来就把"谁干活"和"谁能拿到它"混成了一件事，代价就是那两层
（转发基类 + 多余参数）。

## 被否掉的

- **保持第一版（`ForwardingHostRpc`）**：能跑、全绿，但每加一个方法仍要动一处基类 +
  三处实现方，而且那个多余参数会一直留在每个调用点上。
- **把九个方法塞进 `SyncClient`**：二十多个替身要跟着改（`LinkControl` 早否过一次）。
- **能力不持有连接、每次由调用方传**：就是第一版，见上。

## 代价

- 一次约 20 处机械改动（`HostRpc` 签名 9 处 + `WireHostRpc` 9 处 + 3 个 holder getter +
  `AppModel`/`HostCatalogs` 的调用点）。没有行为变化：请求与解码走的是同一批 `loadXxx`。
- `AppModel` 与 `HostCatalogs` 的 `_rpc` 仍是 `hostRpcOf(client)`（判据一处）。

## 验证

- `cd app; dart analyze --fatal-infos lib test` → No issues found；
  `dart analyze --fatal-infos integration_test` → No issues found。
- `cd app; flutter test` → **1759** 全过（同数）。
- `node app/tools/verify-platform-boundary.mjs` → 791 项全过（183 个 Dart 文件，没变）。
- `dart format --output=none --set-exit-if-changed lib test integration_test` → 0。
- `git grep -c "import '\.\./wire/" -- app/lib/data` → 不变（`app_model` 13 / `file_preview` 2 /
  `projection` 1）；`-- app/lib/core` 仍 0。
- 净变化：**-1 抽象类（约 60 行）、-1 个参数（9 个签名 + 20 处调用点）、3 处 `extends` → `implements`**。
