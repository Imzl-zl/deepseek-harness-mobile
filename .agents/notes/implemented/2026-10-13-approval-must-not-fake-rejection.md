# Agent Note: 审批「呈示不了」必须抛，不能冒充用户的拒绝

Status: implemented

## Problem

真机上「审批转手机」最后一跳拿不到结果:`approval/decided` 在 **322 毫秒**后回来,
outcome 是 `rejected`。322ms 远快于人手点按(测试轮询一步就 200ms)、也远快于看护的
10 分钟 —— 只可能是连接器自己立刻返回的。

而那条 `tool/result` 写的是:

> the user rejected escalating this command to "danger-full-access"; it stays denied,
> so stop and explain instead of working around it

**用户什么都没有点。** 这是连接器替用户做了一个用户没做过的决定。

## Decision

`connector/src/interaction-claims.ts` 的 `askApproval`:**呈示不了就抛,不 `return 'reject'`。**

依据是 DSH 自己的浏览器客户端 —— `packages/client/ui-approval/src/client/index.ts` 的
`answerApproval` 只有三个出口:

| 出口 | 原生动作 | 归一成 |
|---|---|---|
| 用户答了 | `PendingApproval.answer(outcome)` | `'allowed-once'` / `'rejected'` |
| 我呈示不了 | `delegate()` → `next()` | 交给瀑布下一个 |
| 我的寿命结束了 | `abort(reason)` → 抛 | DSH 归一成 `'unavailable'` |

`'rejected'` 在原生语义里**只代表用户点了拒绝** —— `PendingApproval.answer()` 的类型签名
就是 `ApprovalDecision = 'allowed-once' | 'rejected'`(`contract/slots.ts`),没有第三个值。

而我们在两条路上返回了 `'reject'`:

1. 进端口时 `offlineOf(deviceId)` 命中(设备已被判定离线);
2. 看护以 `timeout` / `disconnected` 收束(手机断开、asker 的 signal 被取消)。

两条都**不是**用户决定。而且因为本应答者是 `prepend` 的(见
`.agents/notes/implemented/2026-10-13-answerer-must-be-prepended.md`),
我们一 `reject`,排在后面的桌面应答者就永远问不到 —— 用户连"在桌面上答"的机会都没有。

改成抛之后,`dsh/interactions.ts` 已有的 catch 会把它归一成 `'unavailable'`
(与提问侧 `askQuestion` 完全一致 —— 那边本来就是对得)。**两边这才一致,
而此前错的是审批那侧。**

## Alternatives considered

- **保持 `'reject'` 但只在"用户真的拒绝"时用**
  - 最强的理由:不需要改代码。
  - 为何被否:问题正是"呈示不了"与"用户拒绝"共用同一个返回值,分不开。
    要么加第二通道(契约里没有),要么把呈示不了改成抛。
- **呈示不了时 `next()` 交还桌面**
  - 最强的理由:原生客户端正是这么做的(`delegate → next()`),桌面能答总比没人答好。
  - 为何被否(至少本期):我们的"呈示不了"绝大多数是**手机连接断了**,
    而连接断意味着这台手机此刻不在;此时交还桌面,桌面的转发监听器会把审批挂在
    一个没人点的浏览器对话框上 —— 那正是 prepend 之前那个挂了数小时的事故形态。
    原生客户端 `abort()` 的注释也点了这条:"when its transport, scope, or plugin
    lifetime ends" —— 传输没了就抛,不是 delegate。
  - **留给后续**:如果将来要支持"手机答不了就落到桌面",该做的是**在 claim 之前**
    判"手机还在不在"(那时 `next()` 是安全的),而不是在看护收束之后。
- **把 `'unavailable'` 也做成返回值**
  - 为何被否:`ApprovalOutcome` 是 DSH 的封闭词汇表,answerer 可以返回它,
    但我们的端口层返回它就得让 `interactions.ts` 的三元映射变四元 —— 而抛已经是
    提问侧既定做法,复用它比新增一条映射线省一处会漂移的地方。

## Consequences

- 收益:**不再冒充用户决定**。模型收到的话从"用户拒绝了,停下并绕"变成"没人能答",
  前者让模型放弃、后者它可以重试 —— 这个区别对实际行为是重要的。
- 收益:审批侧与提问侧行为一致(拿不到答案就抛),少一处不对称。
- 代价:`'rejected'` 从此只来自 `settleClaim` 里那个"没有 allowed-once 标签"的分支
  (用户显式点拒绝 / 显式跳过)。任何"我们这边出了问题"的情形都走 `'unavailable'` ——
  桌面上不再出现"用户拒绝了"的假象,但也**不会**自动落到桌面对话框(见上一节的权衡)。
- 代价:7 条既有用例钉的是旧行为,已逐条改成 `assert.rejects` 并补上理由;
  变异校验确认改回 `'reject'` 会红 5 条(测试网不是空的)。
- 未修:步骤 ④ 的等待窗口仍可能因"会话在跑轮次"而超时(测试侧问题,与本文无关)。
