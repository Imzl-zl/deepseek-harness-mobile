# Agent Note: 一轮的 `turn-tail` 操作行（复制 + 用量 pill）

Status: implemented

## Problem

用户 2026-10-20：「dsh web 我看每个消息完毕有复制用量啥的（具体自己看）」。

## 调查：DSH 的形态

`packages/client/ui-chat/src/client/chat/`：

- 它是**独立的 `turn-tail` 行**，不是助手消息的一部分：`turn/end` 时以
  `seq + CHAT_SYNTHETIC_SEQ_OFFSETS.finalizedFollowup`（+0.1）物化
  （`conversation-nodes/turn-tail.ts:107-140`），**一个 turn 只有一条**，
  多 step 不重复出现。渲染入口 `TurnTailNodeView.tsx:57-80`。
- 按钮顺序：复制（复制后 1s 变对勾，`MessageIconActions.tsx:62-76,85-89`）
  → 点赞/点踩（插件槽，order 10）→ 分支（`session/fork` 可用时）
  → **用量 pill** → 时钟。
- **用量 pill** 文案 = `用量 {formatTokens(total)} tok`
  （`locale.ts:178,186` + `TurnUsagePanel.tsx:18-20`），
  点开是「本轮用量」弹窗：精确值（三位分组）+ 缓存命中% +
  未缓存输入 / 缓存读取 / 缓存写入 / 输出（`:52-107`）。
- 数字来自 `deriveTurnTokenUsage`（`packages/llm/token-meter/src/turn-usage.ts:178`），
  即把该 turn 内各次尝试的 `totalTokens` **相加**
  （`aggregateAttempts`，`:130`），不是取最后一条。
- 用户消息只有时钟 + 复制；**明确没有**分享 / 重新生成 / 编辑。

## 数据形状：读真日志确认，不猜

`~/.dsh/sessions/**/session.v4.jsonl.zstd` 是**多帧拼接**的 zstd
（`zstdDecompressSync` 只解第一帧，必须按 magic `0x28B52FFD` 切帧）。
逐帧解出后统计（4 份最大日志）：

- `assistant/message` **8634 条都带 `usage`**，形状是
  `{inputTokens, outputTokens, totalTokens, cacheReadTokens}`；
- 它挂在 **`data` 顶层**（`data` 的键：`turn, step, message, usage, stream`），
  不在 `data.message` 里 —— 与 `turn-usage.ts:246` 的 `event.data.usage` 一致；
- `inputTokens` 是**未缓存**输入：样本 `totalTokens − outputTokens = 94298`
  而 `inputTokens + cacheReadTokens = 66352 + 27946 = 94298` ✓
  （DSH 也把它叫 `uncachedInputTokens`，`turn-usage.ts:150`）。

## Decision

把复制 + 用量 pill 挂在**已有的 `TurnProcessRow`** 上 —— 那一行本来就是我们的
`turn-tail`（`turn/end` 时产出、一轮一条）。

- `TurnTokenUsage`（`model/chat_item.dart`）：`fromWire` **三个必填字段缺一就回
  null**（DSH 的 `normalizeUsage` 同样要么给全要么 `undefined`，
  `turn-usage.ts:100-113`）；`+` 的缓存两档**只在双方都有时求和**。
- `MessageItem.usage`：投影从 `data.usage` 解析。
- `TurnStats`（`data/projection.dart`）：把原来 5 字段 record 换成**带默认值的类**
  —— record 每个字段都得写全，于是任何只关心消息数的调用点都要写 5 项
  （第一版就被一个测试的编译错误逼回头）。
- `_turnStatsOf` 顺带把该轮助手正文按 seq 拼起来（`TurnProcessItem.copyText`），
  复制那一枚才有东西可复制。
- UI：`Wrap` 而不是 `Row`（窄屏上"标题+统计+两枚操作"放不下一行，
  `Row` 只会裁掉或画出黄黑条纹）。

## Alternatives considered（否掉的）

- **点赞/点踩**：要 `message-feedback` 的写面，本仓未接 —— 不做死按钮。
- **分支**：要 `session/fork`，未接。
- **时钟**：这一行左侧已有 `clock` 图标 + 用时，再加一个时刻是重复。
- **把操作栏做成助手消息的一部分**：DSH 明确是独立行，一个 turn 一条；
  贴着每条消息会在多步轮次里重复出现。

## Consequences

- 收益：一轮结束时能复制正文、能看到这一轮花了多少 token（点开看四个桶 + 命中率）。
- 代价：`TurnTokenUsage` / `TurnStats` 两个新类型；`TurnProcessRow` 变有状态
  （复制反馈要 1s 计时器）。
- 测试：`turn_tail_actions_test.dart` 12 项 —— `fromWire`（真日志样本 / 缺字段 /
  负数）、相加（三必填 / 缓存一边缺就 null）、投影带上 usage / 没 usage 是 null、
  pill 文案 `用量 94.4K tok`、没用量不摆、点开明细（精确值 + 30% 命中 + 四桶）、
  没正文不摆复制、复制真写进剪贴板并 1s 后回退。
  **一处变异验证**：把"缓存一边缺就 null"改成"当 0 相加" → 1 条红。
  `flutter test 840` 全绿。
- **真机未验**：演示数据里没有 `TurnProcessItem`（`preview_data.dart` 不造它），
  所以这一行要**已配对**的真会话才出现 —— 等用户重新配对后看。
  判据：一轮结束时那行出现「复制」与「用量 N tok」，点用量开明细。
