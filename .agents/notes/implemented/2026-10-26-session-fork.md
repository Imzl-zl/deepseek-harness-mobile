# Agent Note: 分支走宿主的 fork，标题后缀由连接器补（客户端服务层那一步）

Status: implemented

## Problem

桌面收口消息的复制旁边有「在新会话中分支」。它不是一个界面动作：`forkAt(seq)`
（`ui-chat/src/client/apply.ts:299-305`）调的是客户端会话服务的 `fork`，后者再落到宿主
`SessionController.fork`（`session-controller/src/index.ts:432-443`）。子会话带着源会话的
已完成前缀、标题与工作区归属——这些只有宿主能造。

手机没有宿主 API，所以"分支"必须过协议；而协议里原来没有 `session.fork`。

另外有一处容易看错：`increaseTitle` **不是宿主参数**（`types.ts:300-307` 没有它），
它是客户端服务层做的"读源标题 → fork → `rename`"
（`client/sessions/service.ts:463-487`，后缀规则 `:132-148`）。

## Decision

新增 `session.fork`：`{sid, atSeq?}` → `{sid}`；连接器在同一个 handler 里补上标题后缀。

准入门槛（可机械判定）：

1. **坐标是收口事件 seq**：`atSeq` 可选、安全非负整数；缺省时**不进请求体**
   （宿主自己取最近一个已完成轮次）。用例：`"atSeq 原样进宿主"` 与
   `"不给 atSeq 时**不进请求体**"`。
2. **子 DSH id 不过线**：回 `{sid}`（别名），且用例断言应答的序列化里没有子 id
   （`session-fork.test.ts`）。
3. **标题后缀逐字照 Web**：`increasedForkTitle` 的单测覆盖半角 / 全角 / 无编号 /
   `a (1) (2)`；源标题缺失时用 cwd 目录名，**不用 DSH id 兜底**（id 不过线）。
4. **rename 失败如实**：`internal` + 宿主原话（fork 已建、桌面也不回滚，`service.ts:484`）。
5. **不带幂等键**：宿主 fork 没有键；重复点击由界面「分支中…」在途禁用兜，
   不用一个自造的键在指令层发明"同键同子会话"的语义。

## Alternatives considered

1. **手机侧复制事件另建会话（假 fork）**
   - 最强的理由：不动宿主，看起来最省事，一次 `session.create` 加消息重放就够。
   - 为何被否：fork 是宿主状态（快照、标题、快照 id、允许迁移），复制出来的是"像分支"
     的另一个会话，与桌面不共享后续；标题与工作区归属也会错。
2. **把 `increaseTitle` 抬成宿主参数**
   - 最强的理由：一次调用完成，连接器不用二次 read + rename。
   - 为何被否：那要改 DSH 的 `@Remote('fork')` 契约；手机侧没有这个能力去改宿主，
     而 Web 客户端本来就把这一步放在客户端。
3. **给 `session.fork` 加幂等键**
   - 最强的理由：连点两次不会建出两个子会话。
   - 为何被否：宿主没有这个键，加了等于在指令层发明语义（同键必须同子会话）；
     一个点击一个动作的约束属于界面，放在按钮的在途状态里更直接。

## Consequences

- 收益：收口处能真的分支；子会话进抽屉、可继续用，与桌面共享同一份宿主状态。
- 收益：标题后缀与 Web 一致（同一个正则、同一个兜底链），用户在两块屏上看到同一个名字。
- 代价：方法面 +1（52）；`fork` 每次多两次宿主往返（读列表取标题、rename）。
- 代价：`rename` 失败时子会话已存在但手机拿不到它 —— 与桌面一致（视图不变），
  用户可以通过列表找到那条新会话。

## 代码入口回指

- `connector/src/dsh/sessions.ts`（`fork` / `rename` / `increasedForkTitle` / `sourceTitleOf`）
- `connector/src/handlers.ts`（`session.fork`）
- `app/lib/wire/rpc/session.dart`（`forkSession`）、`app/lib/data/app_model.dart`（`forkSession`）
- `app/lib/ui/chat_turns.dart`（`TurnProcessRow` 的分支钮）、`app/lib/ui/chat_page.dart`（`_fork`）
