# Agent Note: 落点只能由 `_landOnSession` 一个人决定，blank 复用降为第 4 档

Status: implemented

## Problem

2026-10-27 真机（d61cf622）实测：重开 App 不回到刚才那个会话，而是落到一个
**未分组的 blank 会话**上 —— 于是"上次的页签"和"上次的草稿"看起来都没恢复，
`host.last_session` 还被覆盖成那个 blank。用户侧看到的是"连上后连跳好几屏"。

根因不是"忘了写盘"，而是**两条落点路径同时存在且顺序反了**：

- `refreshSessions()` 末尾调 `_openBlankSessionIfUnselected()`（照 DSH 的
  `reuseOrCreateBlank`），它看到 `_currentSid == null` 就选中第一个 blank 并
  `openSession`，顺手把 `host.last_session` 写成那个 blank；
- 随后 `refreshSessions().then((_) => _landOnSession())` 才跑，
  而 `_landOnSession` 第一行是 `if (_currentSid != null) return;` —— 直接早退。

`docs/subsystems/connect-landing.md` §2 早已写明落点只有四档
（`last_session` → 在跑的 → 最新 → 空白屏），并且触发时机就是
"`refreshSessions()` 回来的那一步、由 `_landOnSession` 决定"。代码比文档多出一条路径，
且那条路径先跑。

## Decision

落点由 `_landOnSession()` 独家决定；`_openBlankSessionIfUnselected()` 只作为
第 4 档兜底，不再是 `refreshSessions()` 的一步。

准入门槛（可机械判定）：

1. `refreshSessions()` 结束**不选中任何会话**（不调 `openSession`、不写 `last_session`）。
2. 记住的 sid 在 `session.list` 里 ⇒ `currentSid` 必须是它，且 `host.last_session`
   仍是它（被覆盖即失败）。用例：`app/test/ui_state_wiring_test.dart` 的
   「落点：记住的会话优先于 blank 复用」两条。
3. 没有记忆时仍按第 2/3 档落（在跑的最新 → 最新），不靠 blank 复用兜。

## Alternatives considered

1. 把 `_openBlankSessionIfUnselected()` 挪到 `_landOnSession()` 的**第 1 档之前**
   - 最强的理由：改动最小，一行位置调整，且它确实解决了"blank 会话在抽屉里被藏起来、
     用户永远看不到 hero"这个 2026-10-17 的老问题。
   - 为何被否：它等于宣布"blank 优先于用户上次的会话"，与 `connect-landing.md` §2
     的四档顺序直接冲突；而 hero 另有 `新建会话` 这条正常入口，不需要靠抢落点获得。
2. 让 `_landOnSession()` 覆盖已有会话（去掉早退）
   - 最强的理由：一条路径也能收敛到正确结果，且不必动 `refreshSessions`。
   - 为何被否：早退是**用户点开的那个优先**的守卫（同文档 §2 末句）。去掉它，
     用户正在看的会话会被一次重连顶掉 —— 用一个新 bug 换掉一个旧 bug。
3. 两条路径都留，只加"谁后跑谁赢"的时序保证
   - 最强的理由：两个老需求（hero 可达 / 记得上次会话）都不动。
   - 为何被否：仍然是"两处真值"，下一次改落点规则还得同时改两处；
     而这次事故正是"两处各自成立、合起来错"的形态。

## Consequences

- 收益：冷启动/重连回到用户上次的会话；`host.last_session` 不再被 blank 覆盖；
  落点规则回到文档写的那四档，只有一处。
- 代价：连上一个**只有 blank 会话**的电脑时，第 2/3 档会落到最新那条（通常就是那个
  blank，形态仍是 hero），与旧行为一致；没有 blank 时才由第 4 档保持空白屏 ——
  也就是说"hero 可达"从"每次都抢先"降级为"按四档自然发生"。
- 已实测：修后真机重开回到原会话、仍是「轨迹」页签、草稿在、不弹键盘
  （`app/integration_test/ui_state_live_probe_test.dart` 之外的 10 条真机条目见
  `docs/subsystems/ui-state.md` §8）。
