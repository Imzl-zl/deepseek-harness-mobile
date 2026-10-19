# Agent Note: 一轮的异常结局与模型重试（80 条"出了什么事"此前完全看不见）

Status: implemented

## Problem

用户 2026-10-19 原话："这只是我看到的还不说没看到的问题有多少"。

顺着 DSH Web 的节点清单（`register-node-renderers.ts` 的 14 个 key）逐个对照，
发现 `turn-error` / `turn-max-tokens` / `model-retry` 三个**在手机侧完全不存在**。
从真日志统计出量级：

| 事件 | 这台电脑的条数 | DSH Web 显示什么 |
|---|---|---|
| `turn/end` reason `error` | **71** | `reason.error.message`（原文） |
| `turn/end` reason `interrupted` | **6** | 进程退出提示 |
| `turn/end` reason `max-tokens` | **3** | 截断提示 |
| `llm/retry` | 10+ 条链 | 重试中（第 N/M 次） |

**合计 80 条"出了什么事"在手机上一片空白** —— 用户只看到"这一轮好像没跑完"。

## Decision

### 1. `core/items.dart` 加三种配对

- `llm/retry` / `llm/retry-started` → `r:$retryId:$retry`。
  **id 必须带 `retry` 序号** —— 同一个 `retryId` 下会有多条 `llm/retry`
  （第 1、2、3 次各一条），不带序号会互相覆盖只剩最后一次。
- `turn/end` → `e:$turn`（同一轮只有一条 `turn/end`，turn 号就是稳定身份）。

### 2. `model/chat_item.dart` 加两个条目类型

`TurnOutcomeItem`（kind + message + code + turn + `title` getter）与
`ModelRetryItem`（retry / maxRetries / message / code / started / delayMs）。
**都不并入 `MessageItem`**：它们不是谁"说"的话，是**一轮的结局/过程标记**
（DSH 也渲染成 `contextRow` 那一档，没有头像与气泡）。

### 3. 投影规则逐条照 DSH

`conversation-nodes/turn-error.ts:36-51` 的 `endFailure(reason)`：

| `reason.kind` | 条数 | 处置 |
|---|---|---|
| `error` | 71 | `reason.error.message` **原文** + code |
| `interrupted` | 6 | 固定文案（进程退出） |
| `max-tokens` | 3 | 单独一条（**不算失败**，DSH 同处排除在失败行外） |
| `aborted` + hook `signed-out` | — | 固定文案 + `ACCOUNT_SIGNED_OUT` |
| `aborted`（用户主动） | 53 | **不占条目** |
| `completed` | 891 | **不占条目** |

`llm/retry` → `running` 之前的"计划中"态（`started: false`）；
`llm/retry-started` → 覆盖同一条、`started: true`。
`delayMs` 是 double（真日志 `1737.516418390792`）—— **不收 int**，
`intField` 只认 int（`retry` / `maxRetries` / `turn` 在 DSH schema 里都是
`z.number().int()`，收到 double 说明形状变了，该看不出来而不是悄悄截断）。

### 4. `ui/chat_turns.dart` 加两个行

`TurnOutcomeRow`（图标 + 标题 + 原文，**颜色是语义**：error 用错误色、
截断/中断/登出用工具色）与 `RetryRow`（等宽 `重试 1/10` + 失败原因；
计划中与已开跑**图标不同** —— `alarmClock` vs `loading`）。

## 踩到的坑：`ChatProjection.skip` 让 `.item!` 炸

`ChatProjection.skip` 这个类型早就定义了，但**从没有调用方返回它** ——
所以 `AppModel._onDelta` 里的 `projectEvent(...).item!` 一直没炸过。
这一批第一次返回 skip（completed 的 `turn/end`），立刻踩中：

- `skip` 的 `item` 是 `null`，`.item!` 抛 `Null check operator used on a null value`；
- 它是 `Error` **不是 `StateError`**，下面那个 `on StateError` **接不住**；
- 于是整个 delta 的处理被打断 —— 症状是"会话打开后一条新消息都不再进来，
  且没有任何可见报错"。

修法：`final projected = projection.item; if (projected == null) continue;`
**回归测试**：`turn_end_skip_test.dart` 2 项，并做了**变异验证** ——
把修复 stash 掉后测试变红，报的正是那个 null check 错误（不是空转）。

## Alternatives considered（否掉的）

- **`turn/end` 也返回 `OtherItem`**（而不是 skip）：那会让"事件总数与条目数
  对不上"的排查多一类噪声 —— `turn/end` 是**每个轮次都有一条**的高频事件，
  而 OtherItem 的用途是"这条我知道了但界面上没有它的位置"（用于真异常）。
- **重试行也做成卡片**：DSH 的 `ModelRetryItem` 是 `contextRow` 一档的**行**，
  一条链可能重试 10 次，做成 10 张卡片会把对话流冲掉。
- **给 `interrupted` / `max-tokens` 各写一句自己的文案**：DSH 同处就是固定
  文案（`turn-error.ts:46` 的字面量），照搬不创作。

## Consequences

- 收益：80 条"出了什么事"在手机上看得见了（错误原文、进程退出、截断、
  重试进度）。
- 代价：`ChatItem` 多两个子类型；`_onDelta` 多一个 null 分支。
- 测试：`turn_outcome_test.dart` 14 项（真事件的 reason 六种 / retry 链三条 /
  itemId 与抛错 / **真事件 → 投影 → 渲染三段贯通**）；
  `turn_end_skip_test.dart` 2 项（**含变异验证**）。
- 全量门禁：`flutter test 785` / `analyze 0` / `format 0` /
  `boundary 281` / `icons 100` / `protocol 486`。

## 未验证的部分（说清楚）

**真机上没看到这些行**：反复用 adb 打开会话都被 ROM 行为打断
（模型选择器自动弹出、返回键退到桌面、jumper 不显示），
没能滚到带 error 的轮次。投影与渲染两段有真事件 + widget 测试钉住，
`AppModel` 的接线有 `turn_end_skip_test.dart` 钉住（含变异验证），
但**端到端的样子要用户在带错误的会话里看一次**。
