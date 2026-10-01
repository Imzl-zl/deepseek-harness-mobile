# Agent Note: itemId 从「turn:step:kind」改为消息自己的 `MessageId`

Status: implemented

## Problem

契约 §5.2 的 itemId 推导表原先给带消息的事件定的规则是 `m:<turn>:<step>:<kind>`。移植协议层时对着
DSH 源码逐条核对事件载荷，发现这条规则**会撞号**：

`user/message` 是**非约束**事件。它的载荷注释写明它同时覆盖「直接提问」「`agent.inject()` 注入的上下文
（文件变更通知、子目录 AGENTS.md、skill 内容、cron 通知）」「goal 续跑轮次」三类，并明确说
「All three project their `content` verbatim; `source` tells them apart」
（`packages/core/session/src/types.ts:302-308`）。不变量校验也印证了这一点：对 `user/message` 只有裸
`break`，而 `system/message` 与 `tool/call` 都必须走 `requireOpenStep`
（`packages/core/session/src/invariant.ts:127,150,153`）——也就是说同一个 turn 里可以有任意多条
`user/message`。

于是 `m:1:2:user` 这种 id 会重复，而条目是 upsert-only 的：后一条会**静默覆盖**前一条，
用户看到的对话会凭空少一条。这正是不变量 I9（条目身份与序号解耦）要防的形态，只不过它绕开了
「用 seq 当主键」这个显眼写法，藏在了「用 turn/step 当主键」里。

顺带核出的第二个问题：表里写「审批 / 提问的审计对 → `i:<callId>`」，但**提问根本没有专属审计事件**。
DSH 自己的提问状态是由 `tool/call` / `tool/result` / 带 `source.kind='user-question-reply'` 的
`user/message` 折出来的（`packages/interaction/user-questions/src/projection.ts:247,260,295`）。

## Decision

带消息的事件（`user/message` / `system/message` / `developer/message` / `assistant/message`）
的 itemId 取消息自身的稳定身份：`m:<MessageId>`。

审批审计对改为 `i:<data.id>` 并标明它是**审批专用**（`approval/asked` 与 `approval/decided`
共用同一个 `id`，`packages/interaction/user-approval/src/index.ts:225,232`）；提问不再单独成行，
它的身份落在 `t:<callId>`（提问本身是 `tool/call`）与 `m:<messageId>`（回答是 user message）上。

准入门槛（可机械判定）：

1. **身份字段必须来自事件载荷本身**，不得由 `(turn, step, kind)` 这类「位置组合」推导 ——
   位置组合不保证唯一（I9）。
2. 已知事件类型**缺了身份字段就抛错**，不静默退化成 `<type>:<seq>`；`<type>:<seq>` 只用于
   **规格里没有更稳定身份的事件类型**（兜底是许可的，把已知类型降级成兜底不是）。
3. 改动这张表必须两侧同步（TS 插件 / Dart 手机端）；表在契约 §5.2，任一侧不得自留一份。

## Alternatives considered

1. 维持 `m:<turn>:<step>:<kind>`，只给 `user/message` 加个序号区分
   - 最强的理由：改动面最小，`turn`/`step` 是现成的、两边都能从事件里直接读到，不必依赖
     `MessageId` 这种看起来更「内部」的 id；加了序号照样能保证唯一。
   - 为何被否：序号要么来自「该 turn 内第几条」（要求接收端维护每个 turn 的计数状态，
     而恢复、快照分页、乱序投递都会让这个计数漂移），要么来自 `seq`（直接用 seq 当主键的一部分，
     正面违反 I9，正是这条规则要躲的东西）。而且它把身份变成了「接收端算出来的」而不是
     「事件自带的」——一旦两侧算法有一处不同，同一个事件就会在两处得到不同 itemId，且症状是
     静默重复或静默覆盖，不是报错。
2. 用 `seq` 当 itemId（既然 `seq` 会话内唯一且单调）
   - 最强的理由：最省事，唯一性天然成立，不需要理解任何事件载荷。
   - 为何被否：I9 明令禁止，且 §5.1 已论证 `seq` **不是内容 ID**——崩溃尾回合的 closer 由冷读在
     内存合成、其 `seq` 基准是 `last.seq + closers.length + 1`，同一 `seq` 会经两条读路径各出现一次。
     拿它当主键，重启或冷读就会让条目身份漂移，upsert-only 立刻退化成「要么重复要么覆盖」。
3. 审批与提问共用 `i:<callId>`，把提问的 callId 也接进来
   - 最强的理由：表上更整齐，交互类条目统一一个前缀，手机端渲染也统一。
   - 为何被否：提问**没有**独立的审计事件可供生成这个 id —— 它的 callId 在 `tool/call` 上，
     而那条事件已经按 `t:<callId>` 进了条目表。硬造一个 `i:<callId>` 等于同一条事实有两个身份，
     触发两次 upsert，手机端会看到重复的提问卡。统一前缀是审美收益，重复条目是真实缺陷。

## Consequences

- 收益：身份回到「事件自带」这一条线上，I9 从一句原则变成了可机械检查的推导规则；
  同一 turn 多条 `user/message` 不再互相覆盖；表里那条不存在的「提问审计对」被删掉，
  实现者不会去找一个不存在的事件类型；`itemIdOf` 里「已知类型缺身份字段就抛错」让这类问题
  在第一次遇到时就炸出来，而不是静默产出一个会漂移的 id。
- 代价：`MessageId` 比 `(turn, step)` 更贴近 DSH 内部（虽然它是契约明写的稳定身份），
  手机端实现者需要多理解一个字段；表从「位置推导」变成「字段提取」后，兜底分支
  `<type>:<seq>` 的适用面必须被 reviewer 盯着——它现在更容易被顺手滥用；
  另外 §5.2 的改动会传导到还没写的 Dart 侧，那份实现必须照新表写，
  契约文档与 `connector/src/protocol/items.ts` 之间多了一处需要同步的契约点。
