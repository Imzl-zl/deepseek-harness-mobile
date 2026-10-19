# Agent Note: 历史翻页的骨架（`session.page` + `loadOlderHistory`），anchor 留缺口

Status: implemented

> **2026-10-24 更新**：anchor 缺口已补（见下面「补上的最后一环」），
> 状态从 `partial` 改为 `implemented`。原文保留，因为它记着走过的错路。

## Problem

2026-10-19 查证（`.agents/notes/implemented/` 同日另一篇记的是"查证后决定不做"）：
**历史翻页整条链没接**。

| 层 | 状态 |
|---|---|
| 电脑侧 `connector` | **一直在发** `hasMore`（`session-subscriptions.ts:80-85`） |
| 手机侧 `SyncClient` | `subscribe` 返回 `Future<void>`，**把回包整个丢掉** |
| 手机侧 `session.page` | **从没实现**（契约 §5.7 有它） |
| DSH 默认窗口 | `DEFAULT_MAX_MESSAGES = 50`（`history.ts:38`），Web 自己传 500 |

后果：手机上只有电脑侧那一个窗口，"历史上 20 轮只看到最近 3 轮"。

## 做了什么

### 1. `SyncClient` 加两个成员

- `subscribe` 返回 `SessionAnchor{since, hasMore}`（契约 §3.1 的回包）；
- `page({sid, beforeSeq, maxMessages, minMessages, minTurns})` 返回
  `SessionPage{events, hasMore, failure}`。

窗口参数**照 DSH Web**（`client/sessions/session.ts:54` 的
`HISTORY_PAGE_OPTIONS` + `:405` 的原话 "at least 50 messages and two Turn
starts, capped at 500 messages"）做成三个常量。**按轮次边界切**，
所以一轮不会被劈成两半。

### 2. `AppModel.loadOlderHistory(sid)`

- 切点 = 当前最早一条的 seq；
- **同一会话不并发翻**（`_loadingOlder`）；
- 翻到的条目走**与 `_onDelta` 同一条投影路径**（不另写一份）；
- **失败不当成"没有更多"**：`session/window-missed` 的契约动作是
  「重新订阅走快照」（§3.1），所以 `failure` 单独一个字段，
  调用方可见。

### 3. 测试基类 `test/fake_sync_client.dart`

`SyncClient` 是 `abstract interface class`，28 个替身都要实现全份。
新加两个成员后它们全部编译不过。收成一个基类：
**翻页相关给默认值，其余给 `UnimplementedError`**（这样任何子类自动是
`SyncClient` 的完整实现，而"调了没声明的成员"会炸 —— 那正是信号）。

26 个测试文件改用 `extends FakeSyncClient`，删掉各自的 `subscribe` 样板。

## 走过的错路（2026-10-19，保留作记录）

**以为 anchor 只能从 `session.subscribe` 的回包拿**，于是卡在"outbox 的应答
回不到调用方"上，一度判定为 `partial`。

**2026-10-24 发现错了**：anchor 有一个**更好的来源** —— `sync.hello` 的应答
（`connector/src/handlers.ts:767` 起，`{sessions: [{sid, since, hasMore}]}`）。
它是**批量**的（一次带所有会话），而且手机侧每次进服务态本来就会发 hello。

那条路只差一件事：`_sendHello` 用的是 `_sendFrameWritten`（**不等应答**），
所以应答到了 `_resolveCall` 也当"迟到的"丢掉。改成"先 `_calls.register` 再写"
就通了 —— **不是双发**，hello 仍然只发一次，只是这次有人等它的应答。

### 两条被这条路教训到的事

1. **`.then` 必须接错误分支**：连接离开服务态时 `CallRegistry.failAll` 会给
   完成器 `completeError`（`close()` 就走那条）。第一版只写
   `pending.future.then(_absorbHelloAnchors)`，于是 **26 个测试红在 `close()`**，
   报错栈指向 `call_registry.dart:87`，看起来像"关连接关坏了"。
   实际是未处理的异步错误。加 `.catchError((_) => null)` 即好。
2. **变异验证抓到了"测了但没测到"**：`history_paging_test.dart` 的替身直接
   覆写 `hasOlderHistory`，所以把 `_absorbHelloAnchors` 改成空操作时测试
   **不红** —— 真实链路（hello 应答 → `_historyMore`）没有判据。
   补了 `sync_client_test.dart` 里两条用**真 transport + 真封箱** 的用例后才
   真能守（那时变异立刻红）。

### 仍然否掉的路线

- **在 `subscribe` 里多发一次 `call('session.subscribe')` 读回包**：
  双发 + 无 requestId，实测 4 个测试超时。否。

## Alternatives considered（否掉的）

- **多发一次 `call` 读回包**：双发 + 无 requestId，实测超时。否。
- **从 `sync.hello` 的应答拿**：`_sendHello` 刻意不等应答（`sync.hello`
  只是"批量订阅 + 应用态声明"的入口，恢复内容走订阅流）。否。
- **让 UI 无条件翻页**（不看 `hasMore`）：每次滚到顶都发一次 `session.page`，
  电脑侧回空页才知道没有更多。那是用无效请求换一个信号。否。
- **`DeviceSession` 加 `hasMoreOf`**：那里确实有 `_snapshots` 与
  `RecoveryAnswer.hasMore`，但 `sync_client_impl` 走的是另一条路径
  （`session.receive`），`RecoveryAnswer` 只在 fixtures 里被断言。
  要接起来得先把两条路合一条。否（超出本批）。

## Consequences

- 收益：`session.page` 有了实现、`loadOlderHistory` 有了完整逻辑与入口、
  窗口参数与 DSH Web 逐字一致；26 个测试替身收成一个基类
  （下次 `SyncClient` 长成员不再炸一片）；**anchor 链路通了** ——
  `sync.hello` 的应答 → `SyncClient.hasOlderHistory` → `loadOlderHistory`；
  **UI 触发也接上了**（滚到顶自动翻，判据抽成 `ui/load_older_trigger.dart`
  的纯函数）。
- 代价：`FakeSyncClient` 基类；`conversation_hero_test` 的替身要**手动**
  覆写 `subscribe`（它记 `subscribed`，默认实现不记）；
  `sync.hello` 现在也是一个"在途请求"（断连时会被 `failAll` 拒，
  两条 `lastRejectedCalls` 断言从 1 改成 2 并说明原因）。
- 测试：`history_paging_test.dart` 3 项（没有更多不翻 / 有一页就并进来 /
  失败记原因且不把 `hasMore` 打成假）；`sync_client_test.dart` 2 项
  （真 transport + 真封箱验 anchor 进屋 / 形状不对不当错误）；
  `load_older_trigger_test.dart` 4 项（reverse 方向 / 正序 / 无可滚内容 /
  `hasMore` 为假）。
  **三处都做过变异验证**（分别把 `_absorbHelloAnchors` 改成空操作、
  把 reverse 方向搞反，测试立刻红）。
  `flutter test 810` 全绿。
- **未验证**：**端到端没跑过**。装到真机后手机停在"还没连电脑"
  （公司电脑的 DSH profile 要重新出码配对，而用户不在）。
  三段（anchor → 翻页 → 触发）各有单测，但**一次真实的"滚到顶多出几轮"
  要等用户重新配对后看**。
