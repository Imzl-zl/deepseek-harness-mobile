# Agent Note: 移动端交互在延迟下的形态（提问 / 审批 / 计划审查）

Status: proposed

## Problem

提问与审批在手机上只有**一种失败处理**，而失败有两种：`interaction/not-pending`（这一项真的没了）
与传输失败（超时 / 断线 / 中转不可达，这一项很可能还在）。现在两者都被当成"已过期"：

- `app/lib/ui/chat_page.dart:371-384`：`on Exception` 一律 `settle(itemId)` + 弹「这一项已过期」；
- `app/lib/ui/takeover.dart:340-449`：三个提交方法都是 `_busy = true` → `await _submit` → 写成功回执
  → `settle`，**没有 `try/finally`**，也没有"失败就不写回执"；`_submit` 失败时回执仍然会写
  （「已回答 · …」），因为失败在 `chat_page` 那层就被吞掉了。

也就是说：网络抖一下，用户看到的是「已过期」，卡片被撤掉（不能重试），对话流里却多了一条
「已回答」。这是延迟下最坏的一种组合：**既没答上，又假装答上了**。

### 第二处：提问的"断开就收束"是从审批抄过来的

`connector/src/interaction-claims.ts:273` 给提问也挂了 `presence.onOffline(deviceId, () =>
watchdog.disconnect())`，而那条规则的原始理由写在审批那一侧（`:221`）：**"手机不看了就立刻还桌面"**。

审批可以"还桌面"（另一个 answerer 还在链上）；**提问不行**：claim 是独占的，端口抛错不能让桌面接管，
只会让这次工具调用失败。于是一次 socket 抖动 / 一次切后台，就把提问变成工具失败 —— 而用户回来时
卡片已经没了。

### DSH 原生能力（读源码，0.2.1-rc.2）

| 能力 | legacy（本机现状） | timed |
|---|---|---|
| ask 的身份 | **没有** `wait`（`tool-ask-user/src/index.ts:98-109`） | `wait: {callId, timed:true}`（`user-questions/src/index.ts:251`）；无限等待也带 `callId`（`timed.ts:200-203`） |
| 前台等待 | 无期限（模型一直等） | 默认 120 s，模型可传 `timeout`，`-1` = 无限（`timed.ts:145-148`、`:191-205`） |
| 超时后 | 没有这个概念 | 工具返回 `{pending, callId, message}`，模型继续（`index.ts:261`、`timed.ts:156-165`） |
| 迟到回答 | **答不了**：工具已失败；`answer()` 只认 `continued`，legacy 永不进投影（`projection.ts:12-20`） | 成为一条 `user-question-reply` 用户消息（`index.ts:164-206`） |
| 待处理视图 | 只有会话事件（`tool/call`），断线期间可能错过 | `userQuestions` 投影：`open` / `continued`（`projection.ts:235-304`、`types.ts:72`），可随时拉 |
| 剩余时间 | — | `attachWait` 流（`index.ts:215-220`）；桌面卡有 `countdown`（`client/ui-user-questions/src/client/contract/slots.ts:214`） |
| 桌面提问卡 | 无倒计时 | **带倒计时**，超时后模型继续 |

投影只跟踪 **timed schema** 的调用（`projection.ts:12-20`），所以"用投影重建待处理"这条在 legacy 下
永远是空集。

### 延迟 / 断线矩阵

| 情形 | legacy 现状 | legacy + P2 | timed（端口不改） | timed + 端口等定时器 |
|---|---|---|---|---|
| 用户 3 分钟后才答 | 成功（10 min 看护内） | 成功 | 成功或已 `pending` | 成功或已 `pending` |
| 答到一半手机断线 | **立刻失败** | **等到重连（≤10 min）** | 端口抛错 → `askTimed` 重抛 → 工具失败 | 定时器到点 → `pending`，问题仍可答 |
| 用户 30 分钟后才答 | 工具已失败；答复 `not-pending` | 同左（看护已到点） | 问题仍 `continued`，答复成为用户消息 | 同左 |
| 断线后重连 | 卡靠事件重放重建，但 claim 已死 | **claim 还活着，可直接答** | 投影可重建 | 同左 |
| 卡片状态 | 只有"在 / 撤" | 同左 | `open` / `continued` / settled | 同左 |

## Decision

分四步；**P1 / P2 都不改部署**，P3 才是 timed（可选），P4 是另一件事。

**P1（App）：失败分类。**
- `onAnswer` 的失败分成两类：`interaction/not-pending` → 撤卡 +「已过期」；其余（传输 / 超时 / 未知）
  → **留卡** +「没发出去，再试一次」。
- 失败**不写成功回执**、不 `settle`；`_busy` 用 `finally` 复位。
- 判据：控制器单测（失败时 `receipts` 为空、`active` 仍在、`busy` 复位）+ 接线单测
  （`not-pending` 撤卡、传输失败留卡）。

**P2（连接器）：提问不因"手机断开"立刻失败 —— 只有看护超时（10 min）或取消才收束。**
- 做法：提问那条 `presence.onOffline` 不再 `watchdog.disconnect()`（审批保留）。`onAbort`（turn 取消）
  与看护超时照旧。
- 依据：见上面第二处。审批的"断开就还桌面"对提问不成立，抛错只会让工具失败。
- 效果：断线 / 切后台 ≤10 min 内回来，claim 还活着，答复照常落；超过看护才 fail-closed（与今天一样）。
- 代价：用户真的走了，模型白等最多 10 min（不烧 token，桌面也看不到这次提问 —— 它已被 claim）。
- 判据：端口单测（设备离线**不立刻抛**、重连后 `settleClaim` 成功、看护到点仍抛、取消仍抛）；
  契约 §6.2 的 fail-closed 表要跟着改（"断开"从触发项里去掉，只留超时 / 取消 / 会话被替换）。

**P3（可选，部署 + 连接器 + App）：timed。**
- 只解决"看护之后才答"的那一段；代价是**桌面提问卡带倒计时**、**模型 120 s 后继续**（默认 `timeout`
  是 120，模型要"必须等到答案"得自己传 `-1`）。这是改模型行为，不只是改 UI，所以单列、要你点头。
- P3a 部署：profile 的 `cordis.patch.yml` 给 `tool-ask-user` 加 `config: {mode: timed}`（不改 shipped preset）。
- P3b 连接器：`QuestionPrompt` 加回 `timed` 并**真的读它** —— timed 的提问在设备离线 / 看护超时时
  **不抛**，把结算让给 DSH 的定时器（`index.ts:249-263`；端口抢先抛会让 `askTimed` 重抛，工具照样失败）。
- P3c App：待处理改"投影优先 + 事件兜底"（见 P4 之外的合并规则）；`continued` 的卡不禁用，
  标「电脑已不再等，仍可回答」。
- 判据：端口单测（timed 离线不抛、legacy 照抛）+ 真机 1–2 个轮次（断线 → `pending` → 迟到答案）。

**P4（另一件事）：计划审查卡。**
- `/exit_plan_mode` 的 `ask()` 带 `intent.callId`（`plan-mode/src/index.ts:313-330`），但卡只从
  `ask_user_question` 的 `tool/call` 生成 ⇒ 手机上永远没有计划审查卡（legacy / timed 都一样）。
- 要做就得让 App 从 `exit_plan_mode` 的 `tool/call` 渲染一张"计划审查"卡（`arguments` 里就是计划正文），
  并用 `intent.approve` 作为同意标签。**这是一条新的 App 面**，单独开工单。

## Alternatives considered

1. **只做 P1，维持现状（断线立刻失败）**
   - 最强的理由：桌面零变化；失败快，用户能立刻在电脑上重问；模型不白等。
   - 为何不选：移动端最常见的失败就是"切一下后台 / socket 抖一下"，而它会让提问直接失败、
     卡片消失。P1 只能让失败变得诚实，不能让它不发生。
2. **把看护从 10 min 加到 60 min**
   - 最强的理由：不改 DSH 语义、只调一个参数，就能覆盖"用户过一会儿才回来"。
   - 为何被否：它不解决断线那条路（`presence.onOffline` 立刻收束，看护长度根本走不到）；而且
     模型被挂住一小时，比失败更坏。
3. **直接上 timed（不改端口）**
   - 最强的理由：投影、`answer()`、迟到答案都是现成的，一步到位。
   - 为何被否：端口在手机断开时抢先抛错，`wait.signal` 还没 abort，`askTimed` 会重抛 ⇒ 工具照样
     失败（`index.ts:249-263`）。**只改部署不改端口 = 白改**，还白白背上桌面倒计时与模型继续的代价。
4. **连接器自己把迟到答复 steer 成用户消息**（绕开 `answer()`）
   - 最强的理由：不改部署就能得到"迟到可答"。
   - 为何被否：那是把 `user-questions` 的私有语义抄一遍（`user-question-reply` 的 source 形状、排队
     去重、投影收敛都在 DSH 里），正是"翻译层就是漂移层"。
5. **新增一种"待处理推送帧"**（电脑主动推 pending）
   - 最强的理由：不依赖事件重放，最直接。
   - 为何被否：契约 §6.3 明确"待处理集合是会话事件的投影"，两份集合必然对不上；timed 的投影已经
     把这件事做完了，加帧是重复。

## Consequences

- 收益（P1）：网络抖一下不再被说成"已过期"，也不会在对话流里留一条假的「已回答」；卡片可重试。
- 收益（P2）：切后台 / socket 抖动 ≤10 min 内回来，提问还能答 —— 这是移动端最常见的失败形态，
  而且改动只有一条 `onOffline` 与一段契约文字。
- 收益（P3，若做）：看护之后才答的答案也有归宿（用户消息）；重连后待处理从投影重建，不依赖
  "那条事件还在不在"。
- 代价（P1）：App 多一条失败分类；`onAnswer` 的契约从"吞掉失败"变成"把失败交回控制器"。
- 代价（P2）：用户真的离开时，模型白等最多 10 min（不烧 token）；契约 §6.2 的 fail-closed 表要改，
  审批那条**不动**。
- 代价（P3）：桌面提问卡带倒计时；默认 120 s 后模型继续（问题仍可答）。要"必须等到答案"的提问，
  模型得传 `timeout: -1`，而它默认不会。`QuestionPrompt.timed` 要加回来并真的被端口读
  （本轮的清理把它删了，因为它当时没有读者 —— P3 落地时以 `timed` 为判据重新引入，不是回退）。
- 代价（P3c）：App 多一条投影解析 + 合并规则；`i:<callId>`（投影）与 `t:<callId>`（事件）两种 itemId
  必须收敛成一张卡，否则同一次提问会出现两张。
- 代价（P4）：计划审查卡要解析 `exit_plan_mode` 的 `arguments`，并接受"它不是 `ask_user_question`"。
- 真机：P1 / P2 可在单测与 widget 测试里证；P3 的"断线 → pending → 迟到答案"必须真机（约 1–2 轮）。

代码入口回指（P1 / P2 落地时补）：`app/lib/ui/takeover.dart` 的三个提交方法、
`app/lib/ui/chat_page.dart` 的 `_onTakeoverAnswer`、`connector/src/interaction-claims.ts` 的
提问 `onOffline`。
