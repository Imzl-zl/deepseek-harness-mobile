# Agent Note: 运行态改读原生 —— `status` 帧（`api-session/status` 的转发），删掉 App 侧的"重建 + 代号"

Status: implemented

## Problem

"这个会话现在在不在跑"在 DSH 侧是一个**宿主字段 + 一条推送**：

| 原生面 | 出处 |
|---|---|
| `SessionSummary.running`（`session.list` 的每一行） | `packages/api/session-controller/src/types.ts:185`，取值 `list.ts:120` 的 `agents.get(id)?.status === 'running'` |
| `api-session/status(sessionId, running)` | `types.ts:617-622`、`index.ts:204-205`；在网关转发清单里 `api/remotes/src/remote-events.ts:33` |
| 浏览器的消费方式 | `session-controller/src/client/index.ts:118-119` → `manager.ts:726-734`（直接写 running）；`session.list` 那一包也是**原样覆盖**（`manager.ts:248-253`） |
| `running` 的语义 | `core/agent/src/runtime-types.ts:102-109`：从"唤醒输入开始跑可取消的 pre-step"起，**跨越整个 driver 期间**（含等工具/等审批）到回合收口止 |

我们**没有转发这条**，于是手机自己推同一事实：`_runningSids` 靠"最后一个 `turn/start` 没配对
`turn/end`"，再加"重连按首包重建 + 轮次代号护栏"。每一条补丁都在**补协议缺口**
（`turn/start` / `turn/end` / `session.list` 三者的到达顺序全是传输时序，不是产品语义）。

## Decision（已落地）

**连接器把 `api-session/status` 转成一条 `status` 帧推给手机；App 的 `running` 只剩两处写入。**

### 线上（契约 §3 的帧表 + `FRAME_TYPES`）

- 新帧：`{ v: 1; t: 'status'; sid: string; fc: number; box: string }`，`box` 载荷 `{ running }`。
- **与 `ev` / `live` / `job` 同档**（带 `fc`、走 AEAD）；**不塞进 `presence`** —— 那个是每设备的
  连接级事实（在线 / 前后台），而"会话在不在跑"是会话级的瞬时事实。

### 电脑侧

- `connection-scope.ts`：新增 `sendStatus(sid, running)` —— 未认证（`deviceId === null`）不发；
  否则 `port.send`。**不排队、不重试**：瞬时事实，丢一拍由下一条或 `session.list` 兜。
- `ConnectionScopeDeps.registerScope`：把活连接交给挂载级，返回注销函数（连接 `closed` 时调）。
  **这是唯一的结构性新增** —— 在此之前没有任何"所有活连接"的册子（所有下行帧都由
  每条连接自己的订阅/方法面发出）。
- `device-connection.ts`：建好 scope 时注册；`onStateChange` 到 `closed` 时摘掉。
- `index.ts`（`start-transport`）：挂载级 `liveScopes` + `ctx.effect(() => ctx.on('api-session/status', …))`，
  用别名表把 `sessionId` 换成 `sid`（未认领的会话直接丢 —— 手机是从 `session.list` 那一行学到它的）。

### 手机侧

- `frame.dart` 的 `frameTypes` 加 `'status'`；`sync_client_impl._onLine` 加 `case 'status'` →
  `_onStatus`（`sid` 缺失 / 载荷不是合法 JSON / 缺 `running` ⇒ `bad-frame`，**不静默丢**）。
- `SyncClient.sessionStatus`（`Stream<SessionStatus>`，广播流）；`close()` 时收口。
- `app_model.dart`：订阅它 → `_applySessionStatus` → `_setRunning`；**删掉** `_turnGeneration`、
  `_nextTurnGeneration`、`_bumpTurnGeneration`、`_applySessionList` 的 `reconcileRunningFrom`
  分支、`turn/start` / `turn/end` 里的 running 增删，以及 `refreshSessions(reconcileRunning:)` 参数。
  `session.list` 那一包改成**按原样覆盖**（两个方向），与 DSH 浏览器同一条。
  `turn/start` 的 `time` 仍然写 `_turnStartedAt`（活时钟的起点 —— 推送里没有时间）。

## 判据（0 个真机回合）

- **connector 615 → 616**：`connection-scope.test.ts` 一条（未认证不发 / 认证后推一封 `status`
  帧，载荷逐字 `{running}`）。
- **flutter 1144（数值不变，全绿）**：`running_reconnect_test.dart` 6 条整组重写
  （两个写入面各一条 + `session.list` 读失败保留原值 + widget 两条，其中一条**只靠 `status` 帧**
  验证运行条起落）；`shimmer_test.dart` 两条改成帧驱动；`fake_sync_client.dart` 给
  `sessionStatus` 一个**空流默认值**（`AppModel.start` 无条件订阅它，替身不该为此爆炸）。
- **变异校验两组**（做完即还原）：
  ① `_setRunning` 改成"只加不删" ⇒ **恰好 6 条红**（全部 running 相关）；
  ② `sendStatus` 改成不发帧 ⇒ **恰好 1 条红**（connection-scope 那条）。
- **两道现成的门禁替我们抓到了漏项**（这一轮的真收获）：
  - `connector/tests/frame-list-single-source.test.ts`：契约 §3 的帧表与 `FRAME_TYPES` 逐项相等
    ⇒ 加帧时**忘了改契约**会红（第一次跑就红了）；
  - `connector/tests/job-frame.test.ts`：手写清单与 `FRAME_TYPES` 顺序相等（`KNOWN_FRAME_TYPES`
    必须是别名）⇒ 再红一次。
- **一处更正**：原以为"手机遇到不认识的帧会判 `bad-frame` 关连接"，核实
  `app/lib/core/frame.dart:272-276` 是 `IgnoredFrame` / `UnsupportedFrame`（不关连接）。
  所以分阶段上线并非不可行；本单仍两侧一个提交（它是一件事）。

## 代价与后果

- **快照按原样覆盖**（照 DSH）：如果它在"某条 `status` 帧之后"才落地（请求在途时宿主状态变了），
  会短暂覆盖成旧值，下一条帧纠正。**不加代号护栏去消除它** —— 那正是本轮删掉的东西。
- **装配期多一个册子**：`liveScopes` 随连接进出（`closed` 时摘），内存随连接数走。
- **契约同步**：§3 的帧表加一行、§5.7 末尾的事件清单加 `status`；
  `docs/subsystems/running-cues.md` §3 / §3.1 整节改成"宿主推送 + 快照覆盖"。
- **真机未复验（1 回合）**：断网 20 秒、期间让一轮跑完，回网后运行条**立刻**停。
  按"要真机先报价"的纪律没跑，等点头。

## 代码入口回指

`connector/src/protocol/frame.ts`（帧词汇）、`connector/src/connection-scope.ts`（`sendStatus`）、
`connector/src/index.ts`（`liveScopes` + `ctx.on('api-session/status')`）、
`app/lib/core/sync_client_impl.dart`（`_onStatus`）、`app/lib/data/app_model.dart`（`_setRunning`）。

Note: 来自总账 `.agents/notes/proposed/2026-10-24-native-rules-audit.md` 的 B5
（根因分段 3："用 App 侧状态机补协议缺口"）。本篇取代同名的 proposed 版本（执行计划）。
