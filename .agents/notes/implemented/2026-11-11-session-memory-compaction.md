# Agent Note: 会话内存缓存 —— 只放正文，事实留成标量

Status: implemented

## 结论先行

`_stores` 原来是**只增不减**的（整个 `AppModel` 里只有 `dispose()` 清它，`:5013`），
于是"今天点开过多少个会话"直接等于"内存里压着多少条正文"。现在改成：
**切换会话时，把不在看 / 不在跑 / 没有待处理 / 且本地库读得回来的那几份正文放掉**，
只留三个标量事实（条目数、最新时刻、有没有过可见条目）。

不删整表、不退订 —— 两条都是有意避免的，原因在下面。

## 先纠正一个前提

用户 2026-11-11 问：「不应该拉下来本地存储一下？启动直接读本地增量同步线上这样速度流量都少吧？」

**那套已经在跑了**，不是缺口：

| 你想要的 | 现状 |
|---|---|
| 落本地存储 | `platform/sqflite_item_store.dart` + `data/store.dart` 的 `StoreItemPersister`，每条事件到就写（`main.dart` 装配） |
| 启动直接读本地 | `AppModel._restoreLocalHistory`（`app_model.dart:4150`）：读回条目 → `replaceAll` → 界面立刻有内容 → `client.restoreSession(since: 条目最上界)` |
| 增量同步线上 | 订阅带水位（`core/sync_client_impl.dart` 的 `sinceOf`），不是每次重放整窗 —— 真机实测过"一次什么都没变的回前台 147 KB `ev`"的回归，已修 |

缺的只有最后一层：内存里那份 `Map<String, SessionStore> _stores`（`app_model.dart:1239`）
没有上限。

## 为什么不能直接 `_stores.remove(sid)`

`_stores` 不只是渲染缓存，它同时是**另外四件事的事实源**：

| 读它的人 | 行 | 无脑删掉会怎样 |
|---|---|---|
| `_touchSummary` 的 `itemCount` / `pendingCount` / `updatedAt` | `:4902-4924` | 抽屉里那一行"待处理 N / N 条"归零 |
| `hasVisibleItemsOf` → `sessionBlankOf` | `:3711-3719` | **"新建会话点了没反应"复发** |
| `pendingCountOf`（列表徽标 + 通知）+ `_desiredNotices` 逐会话扫条目 | `:3169` / `:3198` | 审批/提问的角标与提醒消失 |
| `_onDelta` 的 `store.byId(itemId)` 做 upsert 配对 | `:4569` 附近 | 后台会话的 `tool/result` 丢工具名 |

所以"加个 LRU"在这里是错的：**淘汰的对象是一个事实源，而不是一层缓存。**

**退订**同样被否：订阅是通知的事实源（后台任务跑完、有人等你回答）。退了它等于把已发货的
通知能力一并关掉。这一批**不退订**，只放正文。

## 落地的形状

1. `SessionStore.compact()`：放掉 `_byId` / `_sorted`，留 `_droppedCount` /
   `_droppedVisible` / `_droppedUpdatedAt`；`length` / `hasVisibleItems` / `updatedAt`
   三个 getter 把标量与现存条目合并。`replaceAll` 与 `clear` **把标量归零**
   （"整份换掉" = 现在这就是全部）。
2. `AppModel._compactIdleSessions(keep:)`：在 `openSession` 末尾调一次，对**其余**会话
   逐个判四条 —— 不是当前会话、不在跑（`_rows.runningOf`）、没有待处理
   （`store.pendingCount == 0`）、`_readLocalItems != null`。
   **三条都是既有事实，没有引入任何上限数字。**
3. `_restoreLocalHistory` 的早退条件改成 `items.isNotEmpty && !isCompacted`
   —— 这正是"回来只看到两条"那个硬故障的钉子。

## 四个边角与它们的钉子

1. **回来只看到两条** —— `_restoreLocalHistory` 的早退条件。
   用例：`app_model_compact_test.dart` 第 1 条（数 `readLocalItems` 的调用次数）。
2. **水位倒退** —— compact 之后来过更新的条目时，回读会把水位拉回去（upsert 幂等，
   只是多几帧）。可接受，**但写在这里，别当成"不会发生"**。
3. **`replaceAll` 与标量的方向** —— 快照收口是"整份换掉"，必须把 `droppedCount` 归零，
   否则条目数翻倍。用例：`session_store_compact_test.dart` 的 `replaceAll` 那条。
4. **抽屉计数不抖** —— `_touchSummary` 在每条 delta 上跑、读的是 `store.length`。
   用例：`session_store_compact_test.dart` 的"compact 前后三个事实完全相等"。

变异校验（证明用例不是恒真）：把"不在跑"那条判据短路掉 →
`app_model_compact_test.dart` 的"正在跑的会话不压缩"立刻红（`reads` 从 `['a']` 变
`['a','a']`），恢复后回绿。

## 实测（真机 `d61cf622`，隔离实例 + 免费渠道，2026-11-11）

| 步骤 | PSS |
|---|---|
| 未配对、空态 | 225 MB |
| 打开 1 个会话（16 条） | 231 MB |
| 切到另一个会话 | 231 MB |
| 回到第一个 | 236 MB |
| 连开 5 个会话 | 232 / 239 / 245 / 240 / 233 MB |

**读法（别把它读成"没问题"）**：

- **没有线性爬升**：五次之后回落到 233 MB。这批会话都小（十几条），GC 能收回。
- **所以条目本身不是一个"越用越卡"的放大器**（至少在这个数据量下）。
  真正可能上 MB 的是 **`job_book.dart` 的 `_output`：任务输出只追加、永不裁剪**
  —— 那一块**本次没做**，是下一个该量的点。
- 这条改动仍然保留：它的价值是**先给出上限**，而不是等里面长到出事。

## 已验 / 未验

- ✅ 真机：A → B → A，A 的正文完整回来（截图与 `第 1 轮 · 1 条消息 · 15.1K tok` 一致）。
- ✅ 真机：无障碍 —— 会话行与顶栏图标钮在 `uiautomator dump` 里是
  `class="android.widget.Button"` 且 `clickable="true"`
  （见 `implemented/2026-11-10-tappable-semantics.md`）。
- ❌ **未验**："切走正在跑的会话，它跑完的通知照常来"。结构上没变（不退订），
  但要真跑一轮才算证据 —— 本轮没花模型钱。

## 代价与遗留

- 新增 12 条用例（7 条 store 层 + 5 条 AppModel 层），`flutter test` 1807 → 1824。
- `AppModel` +1 个方法 / +25 行 —— 这是**明付的账**：`verify-size` 立刻红，要求把上限
  从 5150/176 提到 5200/177。不把数字提上去就得先别处削，而这一批的价值就是让这件事
  成为一次可见的 diff。
- 任务输出缓冲（`job_book.dart` 的 `_output`）**仍然无上限**。下一轮先量它
  （一条 `flutter build` 的日志到 MB 级），再决定是裁窗口还是"收起就不再持有"。
- `_inboxTrackers` / `_subagentCatalogs` / `_jobs` 仍按会话累积，但体积与会话条数线性、
  且都已被 `openSession` 的重拉覆盖 —— 不在这一批的范围里。
