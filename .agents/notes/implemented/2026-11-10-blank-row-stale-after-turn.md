# Agent Note: 跑过一轮之后，本地那一行不许再自称 blank

Status: implemented

## Problem

2026-11-10 真机：点「新建会话」页面不换（还是当前那个会话），电脑侧也没多出会话。

「新建会话」是 reuse-or-create（DSH `ui-sidebar/src/client/contract/slots.ts:119-121`）：
先 `findBlankSession(工作区)`，有就 `openSession(那一个)`，没有才 `session.create`。
复用判据读的是 `session.list` 行的 `blank`，而 `blank` 是宿主的一个投影
（`sessionListMetadata`：`blank && type !== 'turn/start'`，
`packages/api/session-controller/src/list.ts:51`）—— 手机只在**重读清单**时才更新它。

自己发消息那条路不重读清单（`sendPrompt` 直连 `_writes`；在 `turn/start` 重读是回归：
快照会把刚到的 `running` 压回旧值，`running_reconnect_test` 钉住过）。于是：

点 ＋ 建出 blank `B` → 在 `B` 里发第一句（宿主落 `turn/start`）→ 本地 `B` 仍写
`blank: true` → 再点 ＋ 时 `findBlankSession` 返回 **`B` 自己** → `openSession(B)`
就是"打开当前会话"，页面一动不动 —— 用户看到「点了没用」。
同一个陈旧值还让抽屉把有内容的会话画成「新建会话 / 尚未开始」。

## Decision

在收 delta 的唯一那一处（`_onDelta` 的 `turn/start` 分支）把那一行翻成 `blank: false`，
理由与宿主同源：`blank` 是缓存的宿主字段，我们已经在收它变化的那条事件。

准入门槛（可机械判定）：

1. 单测：`session.list` 给一行 `blank: true` → 推一条 `turn/start` →
   `sessionOf(sid)!.blank == false` 且 `findBlankSession() == null`
   （`app/test/new_session_workspace_test.dart` 的「跑过一轮之后这一行不再算 blank」）。
2. 真机：旧会话上点 ＋ → 顶栏变「新建会话」+ hero
   （`app/integration_test/new_session_real_device_test.dart`，隔离实例 + 真连接）。
3. **不许**用"重读 `session.list`"实现（会把 `running` 压旧，`running_reconnect_test` 会红）。

## Alternatives considered

1. 在 `turn/start` 重读 `session.list`
   - 最强的理由：真值只有宿主一份，手机完全不猜，也不会长出第二条规则。
   - 为何被否：2026-10 试过并回退 —— 快照带 `running: false`，会把刚到的
     `status: true` 压掉，运行条闪一下就没（`running_reconnect_test` 有回归用例）。
2. `findBlankSession` 排除当前会话
   - 最强的理由：一行改动，直接消灭"复用到自己"这个症状，不动任何状态。
   - 为何被否：它把 bug 掩盖成"又建了一个"（电脑侧多出空会话，正是 2026-11-07 修掉的那条），
     并且真在 blank 页上点 ＋ 时的行为就与 DSH 不一致了。
3. 发完消息后重读一次清单
   - 最强的理由：与切模型 / 分支同一条路（`ownWrite` 触发器的现成机制）。
   - 为何被否：`session.list` 在宿主上是重活（本机 327 会话 / 539 MB 日志那次量过），
     每发一句拉一次整表；且与 1 是同一个回归风险。
4. 不修，只在"复用到的就是当前会话"时给一句提示
   - 最强的理由：不动数据，纯 UI，零回归面。
   - 为何被否：治不了抽屉那条错误文案，也治不了"复用判据读的是假值"。

## Consequences

- 收益：复用判据重新说真话；抽屉不再把有内容的会话画成「新建会话」；
  hero ↔ 正文的切换提前到第一句发出时，而不是等下一次清单刷新。
- 代价：手机侧的 `blank` 有了第二个写入口（宿主的清单 + 本地的 `turn/start`）。
  两者是**同一条规则的两处应用**，靠 `list.ts:51` 的引用与门槛 1 钉住；
  宿主将来改这条规则，两处要一起改。
- 未做：**没有订阅**的会话，其 `blank` 仍只能等清单刷新 —— 但那些行不参与当前这次复用判定。
