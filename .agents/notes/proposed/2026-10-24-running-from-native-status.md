# Agent Note: 开工单 W4 —— 运行态改读原生（`api-session/status`），删掉 App 侧的"重建 + 代号"

Status: proposed

## Problem

"这个会话现在在不在跑"在 DSH 侧是一个**宿主字段 + 一条推送**：

| 原生面 | 出处 |
|---|---|
| `SessionSummary.running`（`session.list` 的每一行） | `packages/api/session-controller/src/types.ts:185`，取值 `list.ts:120` 的 `agents.get(id)?.status === 'running'` |
| `api-session/status(sessionId, running)`（`agent/status` 的转发形态） | `types.ts:617-622`、`index.ts:204-205`；在网关的转发清单里 `api/remotes/src/remote-events.ts:33` |
| 浏览器的消费方式 | `session-controller/src/client/index.ts:118-119` → `manager.ts:726-734`（直接写 running，没有任何"重建"） |
| `running` 的语义 | `core/agent/src/runtime-types.ts:102-109`：从"唤醒输入开始跑可取消的 pre-step"起，**跨越整个 driver 期间**（含等工具/等审批），到回合收口止 |

我们**没有转发这条**，于是手机自己推同一事实（`app/lib/data/app_model.dart`）：

- `_runningSids`（`:2713-2722`）：靠"最后一个 `turn/start` 没有配对 `turn/end`"；
- `_turnGeneration`（`:2738-2751`）：轮次边界代号；
- `_applySessionList`（`:1899-1933`）：平时"只补不撤"、**重连那一包按代号重建**；
- 判据 `app/test/running_reconnect_test.dart`（6 条）盯的就是这套重建。

这套东西的形状是：**一份真值长在两端**，然后用"重建 + 代号护栏"把两边对齐。
它每加一条边界（"只补不撤"、"代号变了就跳过"）都要一条测试，而且这些边界
（`turn/start` / `turn/end` / `session.list` 三者的到达顺序）**全是传输时序**，
不是产品语义。

## Decision

**连接器把 `api-session/status` 转成一条下行帧推给手机；App 的 `running` 只有一个写入方。**

1. 连接器（host 进程内，它本来就是 DSH 插件）：`ctx.on('api-session/status', …)`
   —— 与网关转发的是**同一个** Cordis 事件；把 `sessionId` 换成别名 `sid`
   （只对登记过的会话发），推 `status { sid, running }`（新帧，形状与 `presence` 同级）。
2. App：`runningOf(sid)` 直接读这张表；**初值**仍取第一包 `session.list.running`
   （那时还没有任何帧，等价于今天的"只补"）；此后**只由帧改**。
3. 删掉 `_runningSids`（换成"帧写进来的表"）与 `_turnGeneration` 的重建语义：
   - 不再有"平时只补不撤 / 重连按代号重建"两条规则；
   - 不再需要"快照比事件旧/新"的判断 —— 快照只在"还没有帧"时用一次。
4. **保留**从事件里取的东西：`turn/start.time`（活时钟要它）、`turn/end`（轮次统计、
   过程摘要、`_turnStartedAt` 的定稿）。运行态与"回合时间轴"是两件事。
5. 断线期间发生的轮次边界：**不再需要补偿** —— 重连后下一条 `status` 帧（或首包
   `session.list.running`）就是权威；这也顺带消掉"断线期间收了 `turn/end` 收不到"那类缺口。

## 判据

- **单测（connector）**：一条 `api-session/status` ⇒ 一帧 `status {sid, running}`；
  未登记给手机的会话 ⇒ 不发（与 `sidOf` 同一条判据）。
- **单测（app）**：`status` 帧把 `runningOf` 翻成 true/false；首包 `session.list`
  只在该 sid **还没有过帧**时生效；帧到达之后列表再旧也不覆盖它。
- **删/改测试**：`app/test/running_reconnect_test.dart` 的 6 条里，2 条改成"帧为准"，
  4 条（代号护栏、只补不撤）随规则删除 —— **属于"断言的行为被删"，不是放宽**，
  按 `implemented/2026-10-24-native-semantics-first.md` 的同一口径记账。
- **变异校验**：把"帧优先于快照"改反 ⇒ 恰好"帧之后旧快照覆盖"那条红。
- **真机 1 个回合**：断网 20 秒、期间让一轮跑完，回网后运行条**立刻**停
  （今天的判据是"重连那一包重建"，明天是"帧"）。报价 **1 回合**。

## 代价

- **契约要加一条下行帧**（`docs/subsystems/remote-channel.md` §5.7 末尾的事件清单
  + §6 之外的一节，或并在 `presence` 一节里）：这是本单最贵的部分 ——
  帧类型是封闭集，加一条要同时改契约、connector、app 三处。
- **门禁**：connector 611（+2~3）、flutter 1140（净变化取决于删/改）、boundary 360、
  protocol 454（帧表若进 fixtures）。**跑全套，不许降**。
- 收益是**可数的**：`_runningSids` 的重建、`_turnGeneration`、`_applySessionList` 的两条
  规则、`runningOf` 的长注释与 6 条测试 —— 一次性换成一个字段 + 一条帧。
- **风险（要盯）**：`agent/status` 的边界是"driver 期间"，而 UI 的"运行条"还想要
  "这一刻在做什么"；后者继续由事件提供，不要顺手把两件事并了。

## Alternatives considered

1. **只把 `session.list` 的 `running` 读成真值**（不转发推送）
   - 最强的理由：零契约变更。
   - 为何不选：2026-10-22 已经踩过 —— 快照是请求/应答，`true` 会被旧快照钉死
     （`app/lib/data/app_model.dart:2759-2770` 的注释就是那次事故）。没有推送就只有"轮询"，
     而轮询是新的边界。
2. **继续用 `turn/*` 事件，但去掉代号护栏**
   - 为何不选：代号的唯一用途就是对齐两源；去掉它就是回到 2026-10-22 的"运行条转 5 分钟"。
3. **把 `api-session/activity`（`remote-events.ts:29`）当运行态**
   - 为何不选：那是"活动"通知，不是显式布尔；语义要猜。

Note: 本单来自总账 `.agents/notes/proposed/2026-10-24-native-rules-audit.md` 的 B5。
现状事实见 `docs/subsystems/running-cues.md`（本单落地后要改它）。
