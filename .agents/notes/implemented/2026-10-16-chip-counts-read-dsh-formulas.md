# Agent Note: 计数 chip 改读 DSH 的计数口径（任务报"在跑数"，子智能体报总数 + 转圈点）

Status: implemented

## Problem

顶栏底下那两枚计数 chip 是 2026-10-15 加的，当时的文案函数是
`liveChipLabel(count, running, noun, suffix)`：只要有东西在跑，就把 `count` 加上后缀。
它被写成"逐字照 Web" —— **但只对了字面，错了口径**：

| | 手机上（改前） | DSH Web |
|---|---|---|
| 子智能体 | `3 个子智能体，正在运行`（总数 + 后缀） | 可见文案 `count.total` = **`3 个子智能体`**；在跑另画一枚 **ongoing 转圈点**；`{count} 个子智能体，正在运行` 只在 **aria-label** 里（`SubagentHeaderLineage.tsx:679-711`） |
| 后台任务 | `5 个后台任务运行中`（**总数** + 后缀） | `count.live` = **`1 个后台任务运行中`**（报**在跑的个数**）；没有在跑才报总数 `count.idle`（`JobListAction.tsx:450-453`） |

两处都是"同一个真值源的第二个算法"：数字与 Web 对不上（用户看到 5，Web 上是 1）。
chip 的配色也是我们加的（在跑整枚变琥珀），而 DSH 的触发条是
`label-tertiary` 文字 + 转圈点（`JobListAction.module.css:10,29-31`）。

## Decision

把口径搬回 DSH，一处一个纯函数，并让"在跑"由**点**而不是文案承担：

- `subagentChipLabel(total)` → `'{total} 个子智能体'`；
  `subagentChipAria({total, running})` → 有在跑时报**在跑的个数**（`{running} 个子智能体，正在运行`）。
- `jobChipLabel({live, total})` → `live > 0 ? '{live} 个后台任务运行中' : '{total} 个后台任务'`。
- `_LiveChip` 的前导槽：在跑 → `DshStateDot(ongoing)`（DSH 的 `triggerDot` / `activitySlot`），
  否则 → 图标（手机没有 hover，图标是"这是哪一类"的唯一线索）；文字色统一 `labelTertiary`
  （`JobListAction.module.css:10`），**不再整枚变琥珀**。
- 可见文案与无障碍名**分开**（`label` / `aria`）—— 子智能体那枚的差异就在这里。

## Alternatives considered

1. **维持"总数 + 运行中后缀"**（现状）。
   - 最强的理由：手机上少一个点、字数多一个词，读起来更直白。
   - 为何被否：与 Web 的数字**对不上**。用户是"拿手机看电脑上的东西"，
     数字不一致比少一个词严重得多；而 DSH 把"在跑"专门留给了一个点。
2. **保留琥珀色**（在跑整枚变琥珀）。
   - 最强的理由：一眼看见"有东西在跑"，比一个 10px 的点更醒目。
   - 为何被否：告警色是 DSH 留给 `warning`（需要用户注意）的语义；"在跑"是 `ongoing`。
     两件事共用一个颜色，下次真有告警时就没颜色可用了。
3. **把 aria 那句也放进可见文案**（`3 个子智能体（1 个在跑）`）。
   - 为何被否：自造文案。DSH 的可见文案就是 `{count} 个子智能体`，
     要写就写 DSH 那一句，而 DSH 把那一句放在了 aria 里。

## Consequences

- 收益：两枚 chip 的数字与文案与 Web 一致；"在跑"由状态点表达（同一个 `DshStateDot`，
  与顶栏连接点共用一套形状）；告警色空出来给真正的告警。
- 代价：子智能体 chip 不再直接说出"有几个在跑"——要看那枚转圈点（或读屏时的 aria）。
- 回归：`app/test/live_chips_test.dart` 钉住三个判别性用例（含 `live=1, total=5` 这条
  —— 旧口径会算出 5）。做过变异校验：把 `jobChipLabel` 改回旧口径，
  **恰好**那一条变红（`Expected: '1 个后台任务运行中' / Actual: '5 个后台任务运行中'`）。
- 本轮之后 chip 行的宽度也重新算过：`Row` 改 `Wrap`（两枚两位数 chip 在 360px 上必溢出）。