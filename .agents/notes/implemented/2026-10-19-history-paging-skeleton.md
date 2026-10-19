# Agent Note: 历史翻页的骨架（`session.page` + `loadOlderHistory`），anchor 留缺口

Status: partial

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

## 没做成什么（缺口，已记录）

**anchor 拿不到**：`session.subscribe` 走 outbox（契约 §5.6 的写操作），
而 outbox 的语义是"发出去就好"，它的 `res` 应答走 `_resolveCall` 那条路 ——
那里只解**即时 `call`** 挂起的 future，outbox 的 `frameId` 没有 future 在等。

**试过并回滚的做法**：在 `subscribe` 里多发一次 `call('session.subscribe')` 读回包。
那样会**双发**（outbox 一次 + 即时一次），且第二发没有 requestId，
电脑侧按新订阅处理 —— 测试替身直接等到超时（4 个 `sync_client_test` 红）。
双发比拿不到 anchor 糟得多，所以回滚。

要真拿到 anchor，得让 **outbox 的应答能回到调用方**（一个"带 requestId 的
pending future"表）。那是 `core/` 的架构改动。

**因此 `hasMore` 目前恒为 `false`**，`loadOlderHistory` 不会被触发 ——
它有了完整的实现与入口，但缺最后一个信号。**这是 partial，不是完成**。

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
  （下次 `SyncClient` 长成员不再炸一片）。
- 代价：`FakeSyncClient` 基类；`conversation_hero_test` 的替身要**手动**
  覆写 `subscribe`（它记 `subscribed`，默认实现不记）。
- 测试：`flutter test 801` 全绿（含 4 个因双发而超时的用例恢复）。
- **未验证**：翻页端到端没跑过（`hasMore` 恒 false，触发不了）。
