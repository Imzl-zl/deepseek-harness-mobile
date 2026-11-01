# Agent Note: 冷启动不再是"从零开始"—— 读回本地库，水位取内容的上界

Status: implemented（2026-11-01）

## Problem

`resume-from-persisted-watermark` 那批之后，空闲重连已经是 0 字节 `ev`，但**冷启动**
（进程被杀 / 重装 / 重启手机后第一次打开会话）仍然整窗重放：真机实测 `ev` 147 039 B。
原因不是电脑侧不愿意给增量，而是**手机声称自己什么都没有**：

- 条目其实落了盘（`items` 表），水位也落了盘（`cursors` 表），
- 但这条链**只写不读**：`itemsOf` / `allCursors` 全仓零调用方（`store.dart` 里写着
  "它是 `subscribe(since:)` 的输入"，而那个 `since` 早已改成由连接层自己带），
- 于是 `DeviceSession.sinceOf` 冷启动恒为 0 ⇒ 电脑侧只能给窗口。

## Decision

**打开会话时先把本地条目读回界面，再把水位交给连接层。**

```text
itemsOf(sid) → 投影成界面条目 → store.replaceAll
            → since = max(这些条目的 seq)
            → SyncClient.restoreSession(sid, since: …)   // DeviceSession.restore
            → subscribe（带 since）
```

三条判据，每条都对应一种真实的失效形态：

1. **水位取内容的上界**，不取 `cursors.last_seq`：计数器在"事件因空洞没入库、
   却照样落了盘"时会超前于内容（`_sendPersisted` 是逐条调的），拿它当 `since`
   就是"声称我有到 N、界面却是空的"；
2. **一条条目都没有 ⇒ 什么都不做**（不调 `restoreSession`，水位保持 0）：
   这就是上面那条错误的极端形态，方向必须是"多发一次"，不能"少发一段"；
3. **本地条目按电脑身份分区**：`sid` 是电脑侧分配的别名，两台电脑的别名空间互不相干。
   装配时比 `meta` 的 `local_items.host` 与 `pcSignPubHex`，不一致就 `store.clear()`
   ——与"换电脑清 `host.*` 偏好"同一处置。

另外补上**"整份替换"**这一档：连接层补洞补不动时（电脑侧明说没有更早的历史），
说明本地那段属于**另一段历史**（会话日志被改写/截断），于是发一条
`SessionDelta(outcome: snapshot)`，`AppModel._onDelta` 用 `replaceAll` 而不是
`upsertAll` —— 契约 §5.4 规则 4 的"快照整体替换"，这里的第一次真实使用。

## Alternatives considered

1. **冷启动也整窗（什么都不做）** —— 就是本批要治的病：每次冷启动 147 KB。
2. **用 `cursors.last_seq` 当水位** —— 比"不读"更危险：计数器与内容可能不一致，
   而错的方向是"漏发"。见判据 1。
3. **读回条目但不设 `since`** —— 界面有内容、电脑侧仍整窗重放：省了白屏，没省字节；
   而且重放回来的条目要和读回的合并（`itemId` 相同，upsert 幂等，安全但白搬）。
4. **不做"整份替换"，补不动就拼着显示** —— 也是我在上一批的取舍；但它会让
   "另一段历史的旧消息"一直留在界面上，而 `outcome: snapshot` 的语义本来就存在
   （契约 §5.4 规则 4），不用新造概念。所以这次把这一档补上。

## Consequences

- **冷启动的代价从"整窗"变成"窗口之后的那一段"**（电脑侧缓冲还活着时通常就是 0）。
- 代价 1（多一条跨层缝）：`core/session_restore.dart` 的能力口 + `AppModel` 的
  `readLocalItems` 参数（装配点传 `store.itemsOf`）。测试替身不受影响
  （同 `snapshot_call.dart` 的做法：能力口 + 扩展，缺了就当没这个能力）。
- 代价 2（本地条目是"上一次看到的样子"）：界面先显示本地内容，电脑侧确认后才可能变
  —— 与 DSH 桌面"先显示本地库、再对齐"同一条。**断开时也能看**（这是顺带的收益）。
- 代价 3（清库的时机）：换电脑会清掉本地条目。如实说：那是**有意的**
  ——别名空间不通用，混着显示就是"别处的消息"。
- 代价 4（`outcome: snapshot` 的路径现在真的会被走到）：`AppModel` 的这条分支以前
  只被 fixtures 覆盖，现在连接器会发它（补洞补不动时）。

## Testing

- `app/test/cold_start_restore_test.dart`（4 条）：读回条目并取内容上界（输入故意
  不连续：5、9 ⇒ 水位 9）/ 一条都没有则不认水位 / 内存已有内容不读盘 /
  `outcome == snapshot` 整份替换（旧的 5、9 不在界面上）。
- 真机：见 `memory.md`（冷启动前后同一条探针的 `ev` 字节）。
