# S2：存储分域（HostScope + 装饰器）与键空间三分

- 日期：2026-11-06
- 触发：架构审查（`proposed/2026-11-06-branch-a-and-pr-audit.md`）把两件事判成同一处缺陷：
  ① 两台电脑的 `sid` 可能撞名，隔离必须成立；② 当时的隔离手段是"换电脑清库"。
- 状态：implemented

## Problem

`ItemStore.clear()` 删的是 `items` / `cursors` / `outbox` / `meta` **四张表**，而
`main.dart` 的 `_scopeLocalItemsToHost` 在换电脑时调它。代价有两层：

1. **`meta` 被整表清空**：`device.*`（主题、字号、透明度…）与 `schema.data_version`
   一起没了 —— 用户切一次电脑，外观回默认、迁移记账丢一次（迁移本身幂等，重跑无害，
   但外观是用户的选择）。这是"顺手删过头"的典型：清理的判据不是"该不该删"，而是"这张表里装的都是该删的吗"。
2. **切回去要整段重刷**：条目缓存被丢，回到 A 之后 `itemsOf(sid)` 全空，信息流从零开始。

同一批里 `#8`（外部 PR）做了分域，但形状被否：
`SqfliteItemStore.setHostScope(...)` 是**可变字段**，"必须在任何读写之前调"是隐式时序契约
（忘一次的症状是"读到别处的内容"而不是崩溃）；`clear()` 用排除法（只保 `device.%` 与
`net.allow_plaintext_public`）等于把"什么该留"写成一张越写越长的白名单；内存实现没有分域；
以及**没有迁移** —— 键从 `sid` 改成 `<hostId>/sid` 之后旧行成了永久孤儿。

## Decision

1. **`HostScope`（`data/host_scope.dart`）是不可变值**：只有 `hostId` 与
   `keyOf / owns / plainOf` 三件事。它不知道表结构，也不认识 sqflite。
2. **分域做成装饰器**（`data/scoped_store.dart`）：`ScopedItemStore` / `ScopedOutboxStore`
   在**构造时**拿到作用域，给 `sid` / `itemId` / `requestId` 加前缀。
   于是 `ItemStore` 接口与两个真实实现**一个字节都不认识 host**，分域规则只有一处，
   内存实现与 sqflite 实现自动一致（它们只需要各自实现两个与 host 无关的新原语，见下）。
3. **`clear()` 的爆炸半径由作用域决定**：`ScopedItemStore.clear()` 就是 `clearScope()`；
   `clearScope()` 枚举自己那段会话逐个 `clearSession`。**不做 `DELETE FROM items`**，
   也不碰 `meta` —— 三类键的主人见 `docs/subsystems/ui-state.md` §3。
4. **`meta` 不吃前缀**：它的键本来就自带归属（`device.*` / `schema.*` / `host.<id>.*`）。
   再套一层前缀就是同一件事两处表达。
5. **两个新原语（host 无关，写在 `ItemStore` 上）**：
   - `clearSession(sid)`：忘掉一个会话（条目 + 水位，一个事务）；
   - `scopeKeysTo(prefix)`：把还没分域的行补上前缀（`items.sid` / `items.item_id` /
     `cursors.sid` / `outbox.request_id`），判据是"键里没有 `/`" —— 会话别名与条目 id
     都不含它，所以这个方法**幂等**。
6. **迁移 v2 → v3**（`storeDataMigrations[2]`）：前缀取自 v2 装配时写下的
   `meta.local_items.host`，跑完**删掉那个键**。没有这个键就什么都不做 ——
   要么全新安装，要么从没装配过配对凭据，两种情况下不存在"该归给谁"的旧数据。
   `storeSchemaVersion` 2 → 3，`storeMigrations[2]` 是空 DDL。

## 被否掉的

- **保留 `setHostScope` 可变字段**：时序契约不可见，且内存实现必然分叉（`#8` 就是这样）。
- **`clear()` 用排除法保 `device.%`**：白名单会越写越长，而"新加一类键"时漏掉它的症状是
  "某个偏好莫名其妙没了"，且永远不会有测试指向它。
- **给三张表加 `host` 列**：`items.item_id` / `cursors.sid` / `outbox.request_id` 都是
  TEXT 主键，加列要动主键、索引与两个实现的所有查询，换不来任何能力（键里带前缀等价）。
- **迁移时按"最近连过的那台"猜**：没有依据。宁可让旧行走不到（它们是缓存，可重建），
  也不猜一个归属 —— 猜错的症状是"B 下面挂着 A 的会话"。
- **保留 `migrate` 之后的双读路径（旧键读不到就读无前缀的）**：那就是第二条读路径，
  以后每个人都要回答"这两个键哪个是真的"。

## 代价与已知边界

- 升级瞬间那批未分域的旧行只归给 `local_items.host` 记着的那台；若用户下一条要连的是**另一台**，
  它在升级前本来也没有缓存。可以接受。
- **池化仍未做**（S4）：切电脑依旧"换槽 + 重新装配 + dispose 旧的"，
  所以"S2 之后可以两台同时在线"不成立；S2 只保证"不会串台"与"不清过头"。

## 验证

- `dart analyze --fatal-infos lib test`：No issues found。
- `flutter test`：全量通过（本批新增 `test/host_scope_test.dart` 11 项；
  `test/store_contract_test.dart` 新增 2 项、两个实现各跑一遍 = 42 项）。
- **变异校验**：把 `scopeKeysTo` 里的"键里没有分隔符"判据改成恒真，幂等用例立刻变红；
  还原后全绿（证明这条断言不是自我哄骗）。
- `node app/tools/verify-platform-boundary.mjs`：748 项全过（扫描 172 个 Dart 文件）。
