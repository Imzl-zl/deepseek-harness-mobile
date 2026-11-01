# Agent Note: 重连别再整窗重放 —— 手机带的是"落盘水位"，连接器只在能证明覆盖时才跳段

Status: implemented（2026-11-01）

## Problem

一次"回前台、什么都没变"的实测（`d61cf622`，直连 8790，profile `dsh-mobile-test`）：

```text
connector.bytes.out_frame.ev   147 037 B   （占总出站 63.7%，上一批按明文计是 104 683 B）
connector.connect.count        +1
connector.handshake.established +1
connector.state.transitions    +4
```

那一次**是重连**（四个计数一起动），而空闲期间**没有任何新事件**。按契约 §5.4/§5.7 的
恢复语义，带有效 `since` 的重订应答里**不该有 `ev`** —— 于是这 147 KB 是一次纯粹的
"把没变的东西又搬了一遍"，比摘要能省的那 56.5 KB 还大。

## 根因（先出证据，再动代码）

三段链路各自都没错，接起来就退化成"每次全量"：

1. **手机从不给水位**。`AppModel.openSession(sid, {int since = 0})` 的默认值就是 0，
   而全仓**没有一个调用点传别的值**；这层于是把 0 抄进 `_declared[sid]`，重连时
   `sync.hello` 照抄 `{sid, since: 0}`。手机**其实有**这个水位：
   `core/recovery.dart` 的 `DeviceSession.sinceOf(sid)` 是"最近一条**落盘**事件的 `seq`"
   （`_sendPersisted` 成功之后才 `commit`），只是没人读它。
   `ItemStore.cursorOf` / `allCursors` 也有实现 —— 但**零调用点**（本地库这条链今天只写不读）。
2. **连接器拿到 0 就只能重放**。`session.subscriptions` 的 `buffer.tailFrom(sid, 0)`
   覆盖不到（缓冲已按这台设备的 `persisted` 裁过头）⇒ `undefined`；于是走 `follow` 的
   开启快照，而 `lastSeq` 是 `0`，宿主那份**最近窗口**的 `records` 逐条全过，变成一串 `ev`。
3. **退化里还有一处隐患**：`since` 只在"缓冲覆盖得到"时才有意义，而旧代码不管覆盖与否
   都拿 `since` 当 `lastSeq` —— 手机说它到 800、缓冲只剩 900 以后时，801..899 会被
   **静默跳过**（"少发一段"是这条通道唯一不可接受的方向）。

## Decision

**水位只有一个 owner：连接层的 `DeviceSession`。**

- `SyncClient.subscribe(String sid)` **删掉 `since` 参数**：谁手里有内容只有连接层知道，
  让它当调用方参数，就是给"手机声称自己有到 N、其实界面是空的"开一个口子；
- `sync.hello` 的每个会话带**发这一帧那一刻**的水位（不是订阅那一刻的入参 ——
  两者之间收到的事件已经落盘，重连要的是"现在到哪了"）；
- 连接器：**`since` 只在增量缓冲证明"从 `since+1` 开始连续"时才用来跳段**，
  覆盖不到就退回 `lastSeq = 0`（整窗重放），与 `since` 缺省时**一字不差**。

两条方向上的保证：**多发一次可以，少发一段不行**。

## Alternatives considered

1. **用 `ItemStore.cursorOf` 当 `since`（本地库的落盘水位）** —— 今天不行：
   条目**只写不读**（`itemsOf` 零调用点），冷启动的手机内存里是空的。拿库里的水位当
   `since` 会让它声称"我有到 N"，而界面一片空白 —— 正是"漏发"。
   等本地库回读接线之后，这会是**更准**的水位（跨进程），届时替换 `_sinceOf` 一处即可。
2. **要求宿主支持 `follow({since})`** —— 宿主的 `follow` 没有这个入口
   （`connector/src/dsh/sessions.ts:375-388` 只带 `address` 与 `assistantStream`），
   而我们是插件。连接器自己按 `since` 过滤 `records` 已经达到同样效果（线上字节一样省，
   只是宿主多算了一点）。
3. **让连接器在覆盖不到时要求快照（`snapshotRequired`）** —— 这个方法面今天没有
   这个应答形状（`session.subscribe` 只回 `{since, hasMore}`），加它要动契约与手机两处，
   而"整窗重放"在覆盖不到时本来就是我们今天的行为：**退化路径不该新增协议**。
4. **什么都不做** —— 147 KB/次的常态出站，比摘要能省的多一倍；而修法只是"把已有的水位接上"。

## Consequences

- 收益：同一条探针下，空闲重连的 `out_frame.ev` 从 147 037 B 掉到**帧头量级**（见下"验收"）；
  收益与摘要是**两本账**，互不替代：摘要治快照（`res`），这条治事件流（`ev`）。
- 代价 1（契约）：`session.subscribe` 的 `since` 语义写进 §5.7 那一行
  （"手机自己带、连接器只在能证明时跳段"），不再由调用方传。
- 代价 2（一处删除）：`SyncClient.subscribe` 的 `since` 参数删了，
  `declaredSessions` 从 `Map<String,int>` 收成 `Set<String>`（水位不再有第二份）。
  测试替身按"给 `DeviceSession` 喂水位"来构造场景，比原来更接近真实路径。
- 代价 3（如实记）：**空洞检测仍未接线**。契约 §5.4 规则 5 要求"出现 `seq > 水位 + 1`
  就触发一次重订"，但 `DeviceSession.gaps` 今天只计数、没有动作，而 `session.subscribe`
  的应答里也拿不到 anchor（走 outbox，`_sendHello` 之前的那条路见
  `sync_client_impl.dart` 的 `subscribe` 注释）。所以：**连接器丢帧造成的洞不会被自动补**。
  上一批的"每次整窗重放"偶然兜住了它，这条兜底随本批一起消失 —— 但兜底的前提是
  "每次都重放"，那正是本批要治的病。真正的补法是 anchor 接线 + 空洞即重订，
  它不属于这一批（判据：真机上出现"少一条"再谈，那时证据会在 `DeviceSession.gaps` 上）。
- 代价 4（跨进程仍全量）：冷启动第一次打开会话仍是整窗（内存里没有内容，**必须**要）。
  这是如实的成本，不是退化。

## Testing

- connector `tests/session-subscriptions.test.ts` +2：
  ① 带**有效 since** 且没有新事件 ⇒ **一条 `ev` 都不发**（这就是本批的判据）；
  ② 带 since 但缓冲**覆盖不到** ⇒ 退回整窗（1..5 一条不少）。
- app `test/sync_client_test.dart`：新增"重连声明的是**当前**水位"（订阅之后收到的事件
  也算数）；原有两条改成"喂 `DeviceSession` 水位 → 断言 hello / subscribe 带它"。
- 真机：同一套 `HOME → monkey → 等 8s → 读 metrics` 的探针，改前 `out_frame.ev`
  147 037 B（见 Problem），改后见 `memory.md` 的数字。
