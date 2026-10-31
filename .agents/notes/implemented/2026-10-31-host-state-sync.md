# Agent Note: 宿主状态同步（桌面改、手机要跟上）

Status: implemented（2026-10-31；落地形态与本文初稿的两处出入见「落地时改掉的两处」）

## Problem

2026-10-31 真机联调（笔记本 + `dsh-mobile-test` profile + `wss://dsh.0t0.me`）暴露的四条症状，
其中三条当轮已修，这里记下来是为了**不再重复讨论**：

| # | 症状 | 根因 | 状态 |
|---|---|---|---|
| A | 一条回复在手机上渲染**两次**，Web 只一次 | `_liveText` 只赋值、从不清空（`app/lib/data/app_model.dart` 原先只有一处写它）；持久 `assistant/message` 落库后"列表那条"与"流式尾虚拟条目"同时画 | 已修 `6189c5e` |
| B | 切模型弹框不自动消失 | 有推理档时 `_pickModel` 直接叠第二级 sheet，选完只 pop 上面那层 | 已修 `6189c5e` |
| C | 切模型后"没变化、等一会儿才变" | 远端写 + 之后才 `refreshSessions()`，中间无任何"正在换"的反馈 | 已修 `6189c5e`（模型 chip 进度圈） |
| D | 思考等级只显示图标 | chip 是 `_IconChip`（档位只在 tooltip） | 已修 `6189c5e`（带文字 chip） |
| E | 自动签发的令牌一次都连不上 | 握手要求 `?id=<pcId>` **等于令牌 id**，而自动签发给的是随机 `auto-xxxx` | 已修 `bf0eb82` |

**待修的是同一类问题的根**：

- **P1（主问题）桌面侧状态变更没有推送通道。** 手机侧有一大批"快照型状态"：会话清单行
  （模型 / 标题 / 更新时间 / 计数）、投影包（统计 / 权限档 / 标题 / 轨迹 / 用量 / 排队）、
  设置项、jobs 与子智能体目录。它们只在四个时机重取：连接与重连
  （`landAfterConnect()` → `refreshSessions()`，`app_model.dart:2730`）、打开/切会话、
  **回到前台**（2026-10-31 新增，`main.dart` 的 `didChangeAppLifecycleState`）、自己发起的写操作。
  于是"在电脑上改了模型/权限，手机还显示旧值"是**一类**症状，不是一处 bug；
  而且"显示旧值 → 用户按旧值再操作 → 电脑侧按新值校验 → 报错"的连锁也会重复出现。
- **P2 重连偏慢。** 中转窗口是缓存（默认每会话最近 1000 条或 30 分钟，允许丢，
  `remote-channel.md` §5.4 规则 6）；桥接进程重启后增量缓冲为空（§5.5 末条）。
  两者都会让重连退化成**全量快照分页**——正确但慢。
- **P3 渲染粒度仍偏大。** 流式输出已压到"每帧最多重建一次"（`ui/frame_coalesced.dart`），
  但重建的是**整页**；会话流尾部的临时条目本可以独立订阅。
- **P4 缺"新鲜度"的统一表达。** 哪些状态"可能已过期 / 正在刷新"没有规范，
  每个界面自己决定要不要显示进度（模型 chip 的进度圈就是临时加的一处）。

## 落地时改掉的两处（初稿的判断在这两条上不成立）

1. **触发点不能听我们自己的 handler。** 初稿把"切模型 / 权限档 / 设置"写在
   `session/select-model` / `permission.switch` / `settings.update` 上 —— 但验收的第一条
   就是"**Web** 改模型 → 手机 ≤1s 变"，而 Web 直接调宿主的 `selectModel` 与 `/permission`、
   走宿主自己的设置面，**根本不经过连接器**。从 handler 发只覆盖"手机自己改"，
   正是这条通道要消灭的那半个问题。
   改法：五条触发点全听**宿主事件**（`session/event` 的 `model/selection` /
   `permission/preset` / `sandbox/mode` / `session/title`、`settings/document-updated`、
   `jobs.events` 的三个生命周期事件）。宿主事件是这件事的**真值**，"谁改的"于是不再影响通知。
2. **"本机自己发起的写不重复发"随之作废。** 宿主事件不认识来源，按设备跳过就没有判据了；
   手机自己切一次模型会多收一条提示、合并之后多**一次**重取。初稿把这条当硬规则，
   落地后它是一个**代价**（一次往返），不是规则。`exceptDeviceId` 那套连同它的单测一起删掉
   （没有生产者的机制就是死代码）。

## Decision

1. **加一条服务端→客户端通知：`host/state-changed`**

   ```ts
   // 线上帧（契约 §3）：不带 sid 的是宿主级，带 sid 的是会话级
   type HostFrame = { v: 1; t: 'host'; sid?: string; fc: number; box: string }
   // box 里只有键，没有任何值
   type HostStateChanged = { keys: HostStateKey[] }
   type HostStateKey =
     | 'session.list' | 'session.projections' | 'settings.describe' | 'job.list'
   ```

   - **它是 §3 的一种新帧类型，不是 relay-control 的通知**。更正一处措辞：
     `relay.open` / `relay.close` 走的是**连接器↔中转**那条控制面
     （`protocol/relay-control.mjs:38-46`），手机从不看那条；这里要的"同类"只是
     语义上的三条——**不占业务 `seq`、不需要应答、丢了不要紧**。落到线上就是
     `{t:'host', fc, box}`：`fc` 与封箱都没得省（不认证的通知可以让任何人让手机
     反复重取），`seq` 没有（它不是会话条目）。
   - **`sid` 是路由不是数据**（契约把 `sid` 归为路由字段）：会话级 key
     （`session.projections` / `job.list`）必须带它，否则客户端不知道重取谁。
     宿主级 key（`session.list` / `settings.describe`）忽略它。
   - app 收到后按 key 调对应的快照方法，**100–300ms 内同 key 合并成一次**。
     合并放在 app 侧（不在连接器）：连接器的"高频写"本来就已经被宿主的
     `selectModel` / `settings.update` 自身节流，而手机断线重连时**只有 app 知道
     "这一批是不是同一屏要的"**；放连接器还会让"合并窗口"变成又一条连接器策略。
   - 触发点（电脑侧），**实施时按"谁能改"改正过一次**：
     - 切模型 / 权限档 / 标题 → 听**宿主的 `session/event`**
       （`model/selection`、`permission/preset` / `sandbox/mode`、`session/title`）。
       起因是验收第一条就是"**Web** 改模型 → 手机 ≤1s 变"：Web 直接调宿主的
       `selectModel` / `/permission`，**不经过连接器**，所以从我们的 handler 发只覆盖
       "手机自己改"。宿主落的持久事件是这件事的真值，"谁改的"于是不再影响通知。
     - jobs 增删 → 宿主 `jobs.events` 的 `registered` / `settled` / `removed`。
     - `settings.update` → handler（宿主没有"设置被写"的与会话无关的事件）。
       这一条**跳过发起者那台设备**（回执已带回值）。
   - 代价如实记：模型 / 权限档那一侧现在**不跳过发起者**（宿主事件不知道来源），
     手机自己切一次模型会多一次重取。一次往返换"Web 改的也能跟上"，接受。

2. **快照状态登记表**（app 侧一张 const 表）

   `key → 重取函数 → 允许的触发点`，配一条测试：**每个 key 至少有一个触发点**，
   新增状态漏配就红。这是防"以后又冒出第八种状态没人管"的机械保证。

3. **尾部渲染独立订阅（P3）**

   流式文本从 `AppModel` 的通知路径上摘下来：`_liveText` 旁边多一个
   `ValueListenable<String?>`（`liveTail`），**只有流式尾条目**订阅它；
   纯流式的 delta（`events` 空、只有 `liveText`）**不再 `notifyListeners()`**
   （现在的写法每批都 `_touchSummary` → 整页重建，而那一批里什么都没变）。
   尾条的**存在性**（多不多一格）仍在流开始 / 结束时通知一次——那不是"流式期间"。
   判据：流式输出期间**会话列表 widget 的重建次数 = 0**（计数桩测，不靠肉眼）。

4. **中转窗口可选落盘（P2）**——**最后做**，且只在 P1/P3 落地后仍觉得重连慢时做。
   语义不变：**窗口是缓存不是存档**，落盘丢失仍走 `snapshotRequired`。

## Alternatives considered

1. **给每个快照方法各配一条事件**（`session/model-changed`、`session/permission-changed`…）
   - 最强理由：语义直白，客户端不用查表。
   - 为何被否：20 多条快照方法会变成 20 多条事件，**同一份状态两处表达**；
     新增状态要在协议、连接器、app 三处各加一次，漏一处就是又一条 P1。
2. **客户端轮询快照**（前台 1–5s 一轮）
   - 最强理由：零协议改动，今天就能上。
   - 为何被否：耗电与流量随会话数线性涨；延迟不可控（用户仍会觉得"没同步"）；
     而且它把"什么时候该重取"从事件变成了时钟——判断依据更弱。
3. **引入消息队列**（跨重启逐条送达）
   - 最强理由：最彻底，任何丢失都能补。
   - 为何被否：这条链的目标是**状态收敛**（快照 + 单调 `seq` 水位），不是逐条送达；
     任何丢失都收敛到 `snapshotRequired`，恢复幂等（§5.4/§5.6）。MQ 只增加运维面与延迟，
     换不到更强保证。
4. **在中转里做"状态变更总线"**
   - 最强理由：连接器不用改。
   - 为何被否：中转**无状态**是 I7 的前提（中转被清空正确性不变）；让它理解业务状态，
   就把缓存层变成了业务层。
5. **桌面侧改动直接推"数据"而不是推"重取提示"**
   - 最强理由：少一次往返。
   - 为何被否：同 1，等于再抄一份真值；而快照方法是宿主权威的唯一来源。

## Consequences

- 收益：桌面改模型/权限/设置 → 手机秒级跟上，且"按旧值操作再报错"那条连锁断掉；
  新增宿主状态有登记表兜底；流式输出不再牵动整页重建。
- 代价 1：**动协议**。新增一种帧类型要同步三处单一来源：契约 §3 的联合类型、
  `connector/src/protocol/frame.ts` 的 `FRAME_TYPES`、`app/lib/core/frame.dart` 的
  `frameTypes`（门禁：`connector/tests/frame-list-single-source.test.ts` 现在三处都比）。
  向量（49 项）与 fixtures（454 项）**不涉及帧类型清单**，改完只需重跑确认全绿。
- 代价 2：多一次往返（通知 → 快照）。这是"不抄真值"的价钱，接受。
- 代价 3：老 app 收到未知通知必须**忽略**（现有实现是否已忽略未知帧，实施前要核实并补用例）。
- 代价 4：登记表要靠纪律维护（所以配机械测试）。

## Testing

- 帧类型三处单一来源：契约 §3 / `FRAME_TYPES` / Dart `frameTypes`
  （`connector/tests/frame-list-single-source.test.ts` 扩到三处，做一次变异校验）。
- `connector/`：`select-model` / 权限变更 / `settings.update` / 标题生成 / jobs 增删
  后确实发通知；**发起方那台设备不重复发**；老客户端不回 `credit` 也不会被饿死窗口。
- `app/`：收到通知按 key 重取；同 key 100–300ms 内合并成一次；不同 key 互不合并；
  **断连期间不排队**（重连由 `landAfterConnect` 兜底）；未知 key 忽略并计数；
  **登记表里每个 key 至少一个触发点**（机械测试）。
- 端到端（真机）：Web 改模型 → 手机 ≤1s 变；Web 改权限档 → 同理；
  改完立刻断网重连 → 仍是最新值。
- P3 判据：流式输出期间会话列表 widget 重建次数 = 0（计数桩）。

## Open questions（2026-10-31 已答，实施按这四条走）

1. **`keys` 的粒度 = 方法名**（`session.list` / `session.projections` /
   `settings.describe` / `job.list`）。
   - 理由：粒度只有一条判据——"这个名字能不能直接回答'该调谁'"。方法名可以，
     状态键（`session.model`）不能：它指向的仍是同一个 `session.projections`，
     于是"一个方法对应多个 key"⇒ 重取时还要再合并一次，等于把合并做两遍。
   - 状态键的另一条代价：新增一个状态要同时改协议、连接器、app，且**漏一处不报错**
     （同一方法的不同键可以被一个方法名覆盖）。方法名粒度下，新增状态只要重取
     **已存在的方法**就够，协议一个字都不用动。
   - 不接受的反面："`session.model` 更精确，能少拉一点"。快照方法拿到的是一整包
     （`session.projections` 一次 20+ 键，`session.list` 一次全表），**不存在"少拉一点"**，
     所以"更精确"买不到任何东西。
2. **不带 `rev`**。
   - 要有 `rev` 就得定义"每个 key 的 rev 从哪来"：`session.list` 有 `updatedAt`、
     `settings.describe` 是**逐命名空间**的 revision、`session.projections` **根本没有版本号**
     （`app_model.dart` 里 `_projectionRefresh` 那层"不并发重读"正是为了弥补这一点）。
     一份"各 key 的 rev"就是第二份真值，且它比快照本身更容易过期——漏收时它会让
     客户端**相信**自己是最新的（比不检测更糟）。
   - 契约已经给出了更强的收敛手段：任何丢失都收敛到 `snapshotRequired`（§5.4/§5.6），
     通知只承担"提示重取"，重取的结果本身是权威。所以 `rev` 是纯增量复杂度。
3. **未知帧：忽略（不是丢弃），且必须有用例**。核实结果（两侧现状）：
   - 帧类型分派**已经在解码层判掉**：`app/lib/core/frame.dart:273-277` 对清单外的
     `t` 返回 `IgnoredFrame`（无 `id`）或 `UnsupportedFrame`（带 `id`，回
     `protocol/unsupported-version`），`sync_client_impl.dart:515-527` 照办。
     ⇒ **老 app 收到 `host` 帧走的就是这条路**：不崩、不回错、不断连接。
   - 但 `sync_client_impl.dart:624-627` 的 `default` 分支是 `bad-frame` 关连接。
     它只对"**已知**帧类型但这一层没处理"生效 —— 新增帧类型时**必须**同时加
     `case`，否则症状是"连上就断"。
   - 所以本决定分两层：**未知帧类型 → 忽略（已有路径，补用例）**；
     **已知帧里的未知 key → 忽略 + 计数**（app 侧一个 `unknownHostStateKeys` 计数器，
     否则"将来多一个 key"会表现为"通知到了但什么都没发生"，无迹可查）。
   - 附带一条容易漏的兼容风险：老 app 忽略 `host` 帧就**不会回 `credit`**。
     这不影响它——`credit.ack` 是**累计确认**（`protocol/flow.ts:62-89`），后一帧的
     credit 会把前面漏掉的都覆盖；但只要它一直不再收到别的帧，那一份额度就挂着。
     所以要有一条用例钉住"漏 credit 的客户端不会被通知饿死窗口"。
4. **广播**：给**所有已完成业务鉴权的在服务连接**（`liveScopes`），不按订阅者过滤。
   - 理由：这些状态是**宿主级**的（会话清单 / 设置 / 任务表），不是"某个会话的字节流"。
     按订阅者筛等于在连接器里复述"哪个界面读哪个 key"——那是 app 的知识。
   - ~~唯一例外是**本机自己发起的写**~~：这条在落地时作废了，理由见「落地时改掉的两处」。
     宿主事件不知道来源，也就不存在"跳过发起者"的判据。

## 代码回指（改这四条链之前先读这里）

| 入口 | 说明 |
|---|---|
| `connector/src/protocol/host-state.ts` | key 清单 + 触发点 → keys 的**唯一代码化**（五个 `*Notice` 函数与 `hostStateForSessionEvent`） |
| `connector/src/connection-scope.ts` 的 `sendHostStateChanged` | 单条连接的出口（未鉴权不发、空清单不发、发出才计数） |
| `connector/src/index.ts` 的三处 `ctx.effect` | 挂载级触发点：`session/event` / `settings/document-updated` / `onJobsLifecycle` |
| `app/lib/data/host_state.dart` | app 侧登记表（key → 重取函数 → 触发点）+ 合并器 `HostStateRefresher` |
| `app/lib/data/app_model.dart` 的 `_onDelta` 开头 | P3：纯流式 delta 不进 `notifyListeners` |
| `app/lib/ui/chat_page.dart` 的尾条目 | 只有那一格订阅 `liveTail` |

## Verification（2026-10-31 实测）

门禁：

- `node protocol/verify-fixtures.mjs` 454 / `verify-loopback.mjs` 26 / `verify-vectors.mjs` 49 —— 全绿。
- `cd connector && pnpm exec tsc --noEmit` 干净；`pnpm test` 全绿（含新增
  `tests/host-state-notice.test.ts` 11 条）。
- `cd app && flutter analyze` 干净；`flutter test` **1619 项**全绿（新增
  `test/host_state_test.dart`、`test/live_tail_test.dart`，以及 `core_units_test`
  的向前兼容用例、`sync_client_test` 的 `host` 帧用例）。
- `node app/tools/verify-platform-boundary.mjs` 673 项（669 + 新文件 `host_state.dart`
  命中的 4 条规则）；`verify-rpc-single-caller.mjs` 通过。

真机（设备 `d61cf622`，profile `dsh-mobile-test`，直连 `0.0.0.0:8790`，
APK 走 `flutter build apk --profile` + `adb install -r`，配对未丢）：

| 验收 | 证据 |
|---|---|
| Web 改模型 → 手机变 | Web UI（同一会话"你好"）把 `spark-x2.6` 换成 `DeepSeek-V4.1-Flash`；手机 chip 在同一秒内跟着变（来回各验两遍） |
| 通知确实发出 | `GET /api/dsh-mobile/status` 的 `connector.host.notices` 每次改动 **+1**（改前根本没有这个键） |
| 时延 | 30 ms 采样：通知计数 `3→4` 落在 `23:34:43.091→.123`，手机侧重取请求自 `23:34:43.194`（**+71 ms**）起到达；权限档那条：宿主写 `23:36:08.406` → 通知 `08.414` → 手机请求 `08.513`（**+99 ms**）。都远小于 1 s |
| Web 改权限档 → 手机变 | 用宿主的 `/permission read-only`（Web 用的同一条命令路径）→ 手机权限 chip 变「只读」，Web 侧 chip 变「仅可查看」；再切回 `workspace-write` |
| 改完立刻断网重连 → 仍是最新值 | `POST /api/dsh-mobile/transport/direct/stop`（`8790` 的 established 归零）→ 断开期间在 Web 上把模型改成 `DeepSeek-V4.1-Flash` → `.../direct/start` → 手机重连（`connector.handshake.established` 1→2）后 chip 已是 `DeepSeek-V4.1-Flash` |
| 老客户端不崩 | 装的是新 app，这条由解码层用例钉：清单外帧类型无 `id` ⇒ `IgnoredFrame`（`core_units_test` 的 `host-state-changed` 用例 + 原有 `future-frame` 用例） |
| 未知 key | `unknownHostStateKeys` 计数（`host_state_test` 的 `future.snapshot` 用例） |
| P3 | `live_tail_test`：流式期间页面根 `FrameCoalescedBuilder` 重建 **0** 次，尾条目逐批更新 5 次 |

没验/没做的三条，如实记：

- **推理等级**在来回切模型时被宿主归一成 `Default`（原来 `Max`）。这是宿主的
  `model/selection` 语义（切模型不带 effort 就走默认），不是这次改动引入的。
- **`workspace.list` 的顺序变化**不在触发点表里（它由手机自己发起的写带回全集），
  所以"Web 上拖动会话顺序 → 手机跟上"**不在本次范围**。
- 中转窗口落盘（P2）**没做**：P1/P3 落地后重连已由 `landAfterConnect` 的整份重取兜住，
  没有"仍觉得重连慢"的证据，按初稿的条件不做。
