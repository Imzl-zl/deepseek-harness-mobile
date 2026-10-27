# AppModel 收窄：按簇抽类 + 保留转发 getter

- 日期：2026-10-27
- 状态：proposed（设计与批序见 `2026-10-27-ui-state-design.md` §7/§9；本篇只记这个选择与被否方案）
- 相关：`2026-10-27-state-semantics-mechanism-decisions.md`（五条机制裁定）

## Problem

`app/lib/data/app_model.dart` 已是 **4078 行**：连接装配、端点簿、会话行、条目 store、投影缓存、
模型/权限/预设目录、设置面、文件预览、改动记录、提及词汇表、作业订阅、通知编排全在一个类里。
这不是"文件长"的审美问题，它已经产生了三个可观察的后果：

1. **同一个值有第二个来源**（待处理数在 `_pendingCountOf` 与 `TakeoverController` 各算一遍）；
2. **O(n) 出现在 build 路径**（`sessionOf` 线性扫、`workspaceGroupOf` 扫成员、`_pendingCountOf` 扫条目），
   因为"这一簇数据住在这个类里，没有属于自己的派生点"；
3. **新机制无处安放**：本次要加的"设备本地状态缝"如果继续塞进去，就是第 20 个字段 + 第 20 个 `_refreshX`。

AGENTS.md 的硬规则是"新机制不许让它继续膨胀"。所以先定拆分方式。

## Decision

按**职责簇**抽成独立类，`AppModel` 保留**同名 getter 转发**，因此 UI 调用点改动数为 0。
准入门槛（每批都要满足才允许提交）：

1. `cd app && flutter test` 全绿（现有 1381 项，一条不删不改语义）；
2. `app_model.dart` 的**公开 getter/方法签名集合不收缩**（转发保留），顶层字段数**不增加**；
3. 新类**不 import** `package:flutter/*`（`verify-platform-boundary` 的 `core-no-platform-import` 同一条精神）；
4. 每个新类都能用**纯 Dart 用例**直接构造与断言（不经过 `AppModel`）；
5. 一批只搬一簇，`flutter test` 与静态检查在同一提交内。

批序（每批一个提交）：① `host_catalogs` ② `file_preview` ③ `endpoint_book` + `session_rows`。
三个新缝（`ui_state` / `composer_gate` / 派生行事实）**独立成文件，不进 AppModel**。

## Alternatives considered

- **A. 保持单文件，只加机制**。
  最强理由：零回归风险，所有调用点与私有字段的可见性都不动；这次要的"跑通"最快。
  被否：机制一加就是第 20 个字段，而且 `_pendingCountOf`/`workspaceGroupOf` 这类 O(n) 会继续
  留在 build 路径里 —— 下一次同类问题会以同样的形状出现（这正是本轮审计发现的成因）。
  更关键的是它违反 `AGENTS.md`：新机制让 `AppModel` 继续膨胀必须先给收窄计划。
- **B. 一次性大重构**（拆 6 个类 + 全量改调用点）。
  最强理由：一步到位，边界最干净，不用维护一段"转发层"。
  被否：改动面覆盖几乎每个页面，回归与评审压在同一次提交里；本轮纪律是"每批一个红先用例"，
  大重构没有可隔离的红线，出问题也定位不到是哪一簇。
- **C. 引第三方状态库强制分片**（riverpod / bloc）。
  最强理由：provider 天然按 scope 分片，生命周期与依赖注入由库兜住，不用自己写转发。
  被否：与 `2026-10-27-state-semantics-mechanism-decisions.md` 的 B 同一条 ——
  仓库存量是 `ChangeNotifier` + `ListenableBuilder`，换库会把这次改动从"补机制"变成"换骨架"，
  必须另开评审。
- **D. 用 Dart `part`/`part of` 只拆文件、不拆类**。
  最强理由：零 API 变化、纯物理搬迁，`git blame` 也最干净。
  被否：类仍是 4000 行，私有字段对整个类可见，"谁拥有什么"仍然没有边界；
  它只把体积藏进多个文件，解决不了 Problem 里的第 1、2 条。

## Consequences

收益：

- 每簇有自己的文件与派生点，O(n) 的收口变成"那一簇自己的事"，不再散在 build 里。
- 转发 getter 让 UI 零改动，回归面被压在"数据层内部"。
- 新机制（设备本地缝、门槛、行事实）有了明确的安放位置，`AppModel` 停止增长。

代价：

1. **多一层转发**：读代码时要多跳一次（`app.modelCatalog` → `_catalogs.modelCatalog`）。
   这是为了保住调用点，属于有意的可读性代价。
2. 拆分期间 `AppModel` 是"半搬半留"状态，可能出现同一簇数据在两处可读的过渡期；
   每批必须**当场删掉旧私有字段**，不允许留下第二种读法。
3. 抽类后 `_disposed`、`notifyListeners`、错误记录要从"类内直接调"改成注入的回调或
   基类契约；这会新增少量样板（`guarded.dart` 就是为此准备的）。
4. `AppModel` 测试里那些 `@visibleForTesting` 的注入点需要随之搬移，测试文件要同步改；
   这是本批唯一允许改测试文件的场景（改的是**接线**，不是断言）。
