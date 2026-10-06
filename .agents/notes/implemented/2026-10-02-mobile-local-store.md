# Agent Note: 本地库落地 —— `persisted` 不再是谎话，出帧队列真的会发

Status: implemented（2026-10-02 落地：`data/store.dart` + `platform/sqflite_item_store.dart` + `test/store_contract_test.dart`）

## Problem

### 一、`persisted` 一直在说谎

契约 §5.3 的原文是"`ev` **落盘后**才发 `persisted`"。
而实现里 `_sendPersisted` 只调了一次**内存里**的 `DeviceSession.commit` 就发帧 ——
**没有任何落盘**。于是：

- 手机告诉电脑"我到 `seq` 了"；
- 电脑据此**裁掉那边的增量缓冲**（水位就是它裁剪的依据）；
- 而手机其实什么都没存。

后果不是当次崩溃，而是**重启后那段数据永久丢失** —— 源头已经裁掉了。
这类 bug 的表现是"某段历史不见了"，而排查会从协议开始找，真因在"发了一帧不该发的帧"。

### 二、出帧队列从来没发过任何东西

装配点写的是：

```dart
outbox: Outbox(store: inMemory, send: (_) async => false)
```

`send` **永远返回 false** ⇒ `flush()` 永远返回 `offline` ⇒
**队列里每一条都永远发不出去**。而症状只是"订阅了但收不到数据"：
`offline` 是合法返回值，所以**没有任何异常、没有日志**。

量的结果：`Outbox(` 在全仓有 9 处构造，**每一处都传的是桩**
（`(_) async => false` 或 `(_) async => true`）—— 也就是说这条路径
从写出来那天起就没在真连接上跑过。

**根因是循环依赖**：队列要客户端才能发帧，客户端要队列才能处理写操作。
而"构造时传一个假实现"是绕开环的常见做法 —— 也是这个 bug 的来源。

## Decision

### 一、`persisted` 必须等**落盘成功**

`SyncClientDeps` 加一个**窄接口** `ItemPersister`（不是 `ItemStore`）：
`core/` 只需要"把这批交出去，成功后告诉我"，不需要知道条目怎么存、几张表。

落盘失败时：**不发 `persisted`**，本地水位也不前进，错误记进诊断面。
不发是对的 —— 水位不前进，电脑会在重连时重发那一段（幂等，安全）。
而"落盘失败还发"是最糟的选择：它把**可恢复的失败**变成**数据丢失**。

### 二、落盘串行，顺序由 `core/` 保证，不依赖存储实现的细节

事件逐条到达而落盘是异步的。并发落盘时，若某个实现是"覆盖水位"而不是
"取最大"，完成顺序不同会让水位**倒退** —— 而电脑已按较大水位裁过缓冲。

所以 `core/` 用一条 `_persistChain` 把落盘串起来，**不把这个责任推给存储实现**。

### 三、出帧口由 `SyncClient` 自己装（`Outbox.attachSender`）

`Outbox` 的 `send` 改成**可缺省**，`SyncClient` 在构造完之后装上。
缺省时 `flush()` 如实返回 `offline`（而不是假装成功 —— 假装成功会让调用方
删掉队列项，那等于**静默丢掉一次写操作**）。

同时加 `Outbox.hasSender` 作为可断言的信号：**生产装配必须为真**。

### 四、schema 在三端同源，只有驱动分叉

- schema 与迁移脚本定义在 `data/store.dart`（纯 Dart，`storeSchemaVersion`
  + `storeMigrations`）；
- `platform/sqflite_item_store.dart` 只负责**执行**，不许自己写 `ALTER TABLE`。

这才是 `app-platform-boundaries.md` §1 那条"同一套 schema 与迁移脚本，
不允许按平台分叉存储格式"的落地形态：**分叉点在驱动，不在格式**。

### 五、准入判据（可机械判定）

1. **两个实现语义一致**：`test/store_contract_test.dart` 的**同一套断言**
   （14 条 × 2）在 sqflite 与内存实现上各跑一遍。
2. **落盘失败不发 `persisted`**：有专门用例 + 变异校验。
3. **多条事件按到达顺序落盘**：有用例。
4. **装配点不退回假实现**：`test/assembly_invariants_test.dart` 5 条结构断言。

## Alternatives considered

1. **把 `ItemStore` 直接给 `core/`（不做窄接口）**
   - 最强的理由：少一个类型，`core/` 直接 `store.commit(...)` 即可。
   - 为何被否：那会让 `core/` 认识 `StoredItem` / 表 / 序列化 —— 而 `core/` 是
     "纯协议、零平台依赖"的那一层（`verify-platform-boundary.mjs` 的扫描对象）。
     窄接口让 `core/` 的单测不必起数据库，给一个记账的假实现就够。
2. **出帧口在构造时传（保持原样），只是把装配点写对**
   - 最强的理由：不用改接口，改一行装配点就行。
   - 为何被否：**这个写法已经被写错过一次，而且错得没有任何症状**。
     把"谁提供出帧口"从装配点移到 `SyncClient` 自己（唯一知道怎么发帧的地方），
     是让这个错误**在结构上不可能再犯**；而"改对那一行"只是这次对了。
3. **给 `Outbox` 一个"没装出帧口就抛错"的行为**
   - 最强的理由：更吵，绝不会静默。
   - 为何被否：`flush()` 在**启动时**会被调（补发上次的队列），而那时
     连接可能还没建立 —— 抛错会让"启动"崩掉，而正确行为是"留在队列里等重连"。
     所以如实返回 `offline` 是对的；"有没有装"由 `hasSender` 单独暴露、并被断言。
4. **两个库（items 一个、outbox 一个）**
   - 最强的理由：关注点分开，各自迁移。
   - 为何被否：`outbox` 表本来就在契约 §8.3 的同一张 schema 里；
     分成两个库会让"三端同源"从"一套 schema"变成两套，
     而且用同一个事务表达不了"条目与待发项一起落盘"。

## Consequences

- 收益：**`persisted` 说的再也不是谎话**（水位不再超前于内容）。
- 收益：**出帧队列第一次真的会发**（订阅/退订这类写操作从此有效）。
- 收益：两个实现的语义被**同一套断言**钉住 ——
  "单测用内存、真机用 sqflite"这条路上不再有"两边不一致"的隐患
  （第一次跑就抓到了 sqflite 那份起不来库的问题）。
- 代价：多一个依赖 `sqflite`（+ `path`，+ dev 依赖 `sqflite_common_ffi`）。
  这是**必须是插件**的一类：本地数据库是平台能力。
- 代价：`storeMigrations` 现在只有一代（v0→v1）。**加字段一律走它** ——
  实现里不许偷偷 `ALTER TABLE`，否则三端会各自漂移。
- **仍未做**：`pending` / `jobs` 两张表（属于"待处理"与"后台任务"两屏，还没做）；
  淘汰策略的**定时触发**（`prune` 有实现与用例，但还没有谁按期调它）；
  敏感字段的字段级加密（契约 §5.3 要求，依赖安全存储里的派生密钥）。
- **如实记录一处顺序**：`assembly_invariants_test` 的第一版是**空转的** ——
  正则 `Outbox\(\s*store:[^)]*send:` 里的 `.` 不匹配换行（装配点那个调用跨三行），
  所以变异校验时它照样通过。改成按配对括号取调用文本后才真的有效。

## 落地时改动的文件

| 文件 | 做了什么 |
|---|---|
| `app/lib/data/store.dart` | **新增**：`ItemStore` 接口 + `StoredItem` + schema/迁移 + `StoreItemPersister` |
| `app/lib/platform/sqflite_item_store.dart` | **新增**：sqflite 实现 + `InMemoryItemStore` + `SqfliteOutboxStore` |
| `app/test/store_contract_test.dart` | **新增** 28 项：同一套断言在两个实现上各跑一遍 |
| `app/test/assembly_invariants_test.dart` | **新增** 5 项：装配点不许退回假实现 |
| `app/lib/core/sync_client.dart` | **改**：加 `ItemPersister` 窄接口与 `SyncClientDeps.persistence` |
| `app/lib/core/sync_client_impl.dart` | **改**：`_sendPersisted` 等落盘成功；落盘串行链；装上出帧口 |
| `app/lib/core/outbox.dart` | **改**：`send` 可缺省 + `attachSender` + `hasSender` |
| `app/lib/main.dart` | **改**：开真库；`persistence` 与 `outbox` 都用真实现 |
| `app/test/sync_client_test.dart` | **改**：新增 4 项落盘时序用例；subscribe 那条改为断言"真的发出去了" |
| `app/pubspec.yaml` | **改**：加 `sqflite` / `path` / `sqflite_common_ffi`（dev） |

证据：`flutter test` **196 项全绿**；`dart analyze --fatal-infos` 0 问题；
`dart format --set-exit-if-changed` 0 文件。

**三处变异校验**：① 落盘失败也发 `persisted` → 用例红并报出
"水位超前于内容 = 数据永久丢失"；② 装配点传假出帧口 → 结构断言红；
③ 装配点用内存库 / 不给 `persistence` → 各红 2 条。
