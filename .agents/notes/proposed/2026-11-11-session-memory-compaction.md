# Agent Note: 会话内存缓存的淘汰 —— 已经有了落盘与回读，缺的是"放掉"这一步

Status: proposed（方案与边角已摸清；**未动代码**）

## 先纠正一个前提

用户 2026-11-11 问：「不应该拉下来本地存储一下？启动直接读本地增量同步线上这样速度流量都少吧？」

**那套已经在跑了**，不是缺口：

| 你想要的 | 现状 |
|---|---|
| 落本地存储 | `platform/sqflite_item_store.dart` + `data/store.dart` 的 `StoreItemPersister`，每条事件到就写（`main.dart` 装配） |
| 启动直接读本地 | `AppModel._restoreLocalHistory`（`app_model.dart:4150`）：读回条目 → `replaceAll` → 界面立刻有内容 → `client.restoreSession(since: 条目最上界)` |
| 增量同步线上 | 订阅带水位（`core/sync_client_impl.dart` 的 `sinceOf`），不是每次重放整窗 —— 真机实测过"一次什么都没变的回前台 147 KB `ev`"的回归，已修 |

缺的**只有最后一层**：内存里那份 `Map<String, SessionStore> _stores`（`app_model.dart:1239`）
**只增不减**。整个 `AppModel` 里唯一清它的地方是 `dispose()`（`:5013`）。
也就是说：App 从启动到现在，你点开过的每个会话的**全部条目**都还在内存里。

真实量级（估算，未实测）：一条 `ChatItem` 带正文，平均 300–500 字节，长会话 500 条 ⇒ 单会话
150–250 KB；翻 30 个长会话 ≈ 5–8 MB，翻 100 个 ≈ 20 MB。**加上 `_jobOutput`（任务输出
StringBuffer，永不裁剪，一条构建日志可以上 MB）**，这是比会话条目更大的那块。

## 为什么不能直接 `_stores.remove(sid)`

`_stores` 不只是渲染缓存，它同时是**另外四件事的事实源**：

| 读它的人 | 在 `app_model.dart` 的行 | 无脑删掉会怎样 |
|---|---|---|
| `_touchSummary` 的 `itemCount` / `pendingCount` / `updatedAt` | `:4902-4924` | 抽屉里那一行"待处理 N / N 条"归零 |
| `hasVisibleItemsOf` → `sessionBlankOf` | `:3711-3719` | **"新建会话点了没反应"复发**（宿主说 blank、手里也确实空了 ⇒ 被当成可复用的新会话） |
| `pendingCountOf`（列表徽标 + 通知） | `:3169` 附近 | 审批/提问的角标与提醒消失 |
| `_onDelta` 的 `store.byId(itemId)` 做 upsert 配对 | `:4569` 附近 | 后台会话的 `tool/result` 丢工具名（展开区空） |

这就是为什么"加个 LRU"不是这里该做的事：**淘汰的对象是一个事实源，而不是一层缓存。**

## 方案（下一步要落的就是它）

**核心是把"事实"与"正文"分开**，而不是把整张表删掉：

1. `SessionStore.compact()`：放掉 `_byId` / `_sorted`，只留三个标量事实 ——
   `droppedCount`（条目数）、`droppedVisible`（有过非 `OtherItem` 条目）、
   `droppedUpdatedAt`（最新时刻）。`length` / `hasVisibleItems` / `updatedAt` 三个 getter
   把标量与现存条目合并。`replaceAll` 与 `clear` 把标量归零（"整份换掉" = 现在这就是全部）。
2. `AppModel` 侧的触发点只有一处：`openSession` 切走之后，对**其余**会话调 `compact()`，
   条件是**同时**满足：不是当前会话、没有正在跑、没有待处理。
   —— 三个条件都是既有事实（`_runningSids` / `pendingCount`），**不引入任何上限数字**。
3. **只挡一层**：`_readLocalItems == null` 时（单测、无本地库的装配）不 compact ——
   没有回读能力就不该放掉。这是能力判据，不是闸门。

## 已经摸到的四个边角（这是它值得单独立一篇的原因）

1. **回来只看到两条**：compact 之后后台又来了新条目，`_restoreLocalHistory` 的
   `if (store.items.isNotEmpty) return;`（`:4154`）会跳过回读 ⇒ 界面只剩那两条。
   修法：早退条件改成 `store.items.isNotEmpty && !store.compacted`。
2. **水位倒退**：`restoreSession(since: highest)` 用的是**回读条目**的最上界；若 compact
   之后来过更新的条目，水位会往回退，宿主重放一段（upsert 幂等，只是多几帧）。可接受，
   但要在笔记里写明，别当成"不会发生"。
3. **`replaceAll` 与标量的方向**：快照收口（`RecoveryOutcome.snapshot`）是"整份换掉"，
   必须把 `droppedCount` 归零，否则条目数会翻倍。
4. **抽屉计数不抖**：`_touchSummary` 在每条 delta 上跑，读的是 `store.length`；标量合并对了
   它才不抖。这条要单独一条用例钉住（"compact 前后 length 相等"）。

## 准入判据（做的时候按这个验收）

1. `app/test/session_store_compact_test.dart`：`compact()` 前后 `length` / `updatedAt` /
   `hasVisibleItems` 三个值**完全相等**；`replaceAll` 之后标量归零；`upsertAll` 之后
   `length` = 标量 + 新增条数。
2. `app/test/app_model_compact_test.dart`：切走的空闲会话被 compact；**正在跑的、有待处理的
   不 compact**；compact 后再打开能读回全量（装配 `readLocalItems` 替身）；`sessionBlankOf`
   在 compact 前后一致。
3. 变异校验：把"不是当前会话"这个条件去掉 → 用例 2 的第一条必须红（当前会话被压缩 = 屏幕上
   的内容会消失，这是最严重的一种）。
4. 真机一条：A（长会话）→ B → A，A 的滚动位置与条数不变；A 发一句后立刻切到 B，
   A 跑完的通知**照常来**（订阅没有被退掉 —— 本方案里**不退订**，只放正文）。

## 为什么这一批没直接做

因为它同时改到 `_restoreLocalHistory`、`_touchSummary`、`sessionBlankOf` 三处，
而这三处正是 2026-11-09..10 连着修了三轮 bug 的地方（blank 行、流式尾归属、turn/start 翻状态）。
上面四个边角每一个都能单独造成一次"看起来像新 bug"的回归，而它们在
`flutter test` 里只有部分能被覆盖 —— 需要一次真机回合验第 4 条。

**半成品不如不动**：现在的行为（只增不减）是慢性的，而一个做错的淘汰是急性的（内容消失）。
