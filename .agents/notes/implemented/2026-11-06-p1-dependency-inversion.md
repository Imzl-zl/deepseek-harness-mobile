# P1：依赖倒置第一批 —— 翻页/补取的读法收进端口

- 日期：2026-11-06
- 触发：架构审查（`proposed/2026-11-06-branch-a-and-pr-audit.md` §四）把 `core→wire` ×2 与
  `data→wire` ×21 判成"要依赖倒置、不许把 wire 搬进 core"。P1 单独一批、单独留笔记。
- 状态：implemented（本批只落 `core→wire` 的一半；剩下哪几条与**实测**代价见末节）

## Problem

`wire/` 是线上格式的**唯一断言点**（字段名与类型只在那里出现），而 `core/` 与 `data/` 反过来
import 它 —— 方向是"消费者依赖形状"。具体到这两条：

1. `core/sync_client_impl.dart` 的 `page()` / `refetch()` 直接调 `wire/rpc/session_page.dart`
   的 `loadSessionPage` / `loadRefetchedEvent`，并 `switch` 它的
   `SessionPageRecordWire` / `SessionPageRefetchWire`；
2. `core/items.dart` 的 `itemIdOf` 用 `wire/events.dart` 的四个读者取身份字段。

第 2 条不是"改个签名"能了结的（见末节），第 1 条可以干净地收进一个端口。

## Decision

1. **`core/history_page.dart`（新）**：`HistoryPage` / `HistoryPageItem`
   （`HistoryRecordItem` | `HistoryRefetchItem`）与**端口** `HistoryReader`
   （`loadPage` / `loadRefetched`，都用 `null` 表示"读不出来"）。
2. **实现留在 wire**：`wire/rpc/session_page.dart` 的 `WireHistoryReader` 把
   `SessionPageWire` 折成 `HistoryPage`，并把失败**报到 `WireDiagnostics`**
   （`'session.page'` / `'session.refetch'` 两个标签从连接层挪到这里 —— 报缺陷的那一处
   与知道形状的那一处对齐）。
3. **`SyncClientDeps.history` 必填**：不给就没有历史可翻，而"翻不了页"不该是静默默认值。
   装配点（`main.dart` 两处、集成测试两处、`sync_client_test` 一处）各加一行。
4. **补取循环留在连接层**：它要 `await` 自己的 `refetch`（还要按 `seq` 归位、记住 `hasMore`），
   那是 `SyncClient` 的状态。挪去 wire 就得把连接层状态一起搬过去。
5. **顺手修掉一个 S2 遗留**：`integration_test/local_store_test.dart` 还在调
   `SqfliteItemStore.clear()`（该方法在 `61c2b2c` 已删），所以 `integration_test` 自那以后
   **编译不过** —— 而门禁跑的是 `dart analyze lib test`，看不见它。改成 `clearSession('s1')`
   （语义正是"这个会话从头开始"）。

## 被否掉的

- **把 `SessionPageWire` 搬进 core**：那等于把"应答长什么样"搬进 core，正是不许的方向。
- **让连接层自己解 `{items, hasMore}`**：同一条，形状知识会散回消费方。
- **把补取循环搬进 wire**：它需要连接层的 `refetch` 与 `hasMore` 记账，搬过去就是"wire 知道
  连接层的状态"。
- **`history` 给个"没有实现"的默认值**：翻页会静默失效（症状是"上滑没反应"），
  比编译失败糟。

## 代价与已知边界

- 热路径多一次接口调用：每翻一页一次（不是每条事件一次），可忽略。
- `_eventsOfPage` 的分支从 wire 的类型换成 core 的类型：行为不变（`switch` 仍穷尽，
  编译器仍然替我们守"新 item 类型要处理"）。

## 验证

- `cd app && dart analyze --fatal-infos lib test`：No issues found。
- `cd app && dart analyze --fatal-infos integration_test`：No issues found（修掉 `clear()` 之后）。
- `cd app && flutter test`：1758 项全过（本批没加用例，也没改断言）。
- `node app/tools/verify-platform-boundary.mjs`：760 项全过（175 个 Dart 文件；
  比 748 多的 12 项 = 三个新文件 × 4 条按文件扫的规则）。
- `git grep -c "import '\.\./wire/" -- app/lib/core` → **1**（只剩 `items.dart`，见下）；
  `-- app/lib/data` → **4 个文件 / 21 条**（未动）。

## 剩下的（实测，不是计划口吻）

**`core` 还有 1 条**：`core/items.dart → wire/events.dart`。它要 4 个身份字段读者
（`callId` / `toolCallId` / `approvalId` / `commandId`），而 `itemIdOf` 有三个调用方
（连接层、`data/projection.dart`、wire 自己的 page 解码）。

两条路，代价是**实测**的：

| 路 | 省掉的编译期依赖 | 代价 |
|---|---|---|
| 给 `itemIdOf` 加 `EventIdReaders` 参数 | core → wire 变 0 | `data/projection.dart` 的 `projectEvent` 也要收这个端口 → `app/test` 里 **55 处** `projectEvent(...)` 调用、15 个文件全要改（多数只是传一个常量，但 diff 是 55 行噪音） |
| **身份在解码边界算一次**（`SessionEvent.itemId` 已经存在，wire 解出来的），`projectEvent` 收 `itemId` 而不是自己再推一遍 | 同上 | 同样是那 55 处（加 `itemId:` 参数），但顺带**去掉热路径上的重复推导**：今天每条事件在 wire 解一次、在投影里再解一次 |

**`data` 的 21 条**：`app_model.dart` 15、`host_catalogs.dart` 3、`file_preview.dart` 2、
`projection.dart` 1，用到 35 个 `wire.loadXxx(client, …)` 与 6 个应答 DTO
（`SessionListPage` / `SessionProjections` / `SettingSection` / `RepoInfo` /
`PluginInventory` / `WorkspaceSnapshot`）。倒置的形状是"`HostRpc` 端口声明在 core、
`wire` 侧一个适配类实现它、DTO 搬 core"，**但 `AppModel` 的 74 个测试文件都直接
`AppModel(...)` 构造** —— 加一个必填端口参数就是 74 个文件、100+ 处改动。
所以这条路必须先有 `app/test` 侧的 AppModel 构造器（fixture builder）并先把测试迁过去，
否则改动量与收益不匹配。**这是 P1 剩下部分真正的成本中心，不是接口本身。**
