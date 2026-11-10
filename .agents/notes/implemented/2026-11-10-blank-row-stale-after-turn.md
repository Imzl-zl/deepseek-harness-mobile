# Agent Note: 跑过一轮之后，本地那一行不许再自称 blank

Status: implemented

## Problem

手机侧的 `session.list` 行是宿主 `blank` 字段的**缓存**，而 `blank` 是宿主的投影
（`blank && type !== 'turn/start'`，`packages/api/session-controller/src/list.ts:51`）。
手机只在「重读清单」时更新它；自己发消息那条路不重读（在 `turn/start` 重读是回归：
快照会把刚到的 `running` 压回旧值，`running_reconnect_test` 钉住过）。

于是存在一个**真正的陈旧窗口**：`turn/start` 已到手机，而本地那行还写着 `blank: true`。
这期间 `findBlankSession` 会把当前这个会话当成新会话复用（`openSession(自己)`
⇒ 页面不动），抽屉也把它画成「新建会话 / 尚未开始」。

## 这件事**不能**解释的那个报告

2026-11-10 用户反馈「点新建会话还是旧会话页面」。当时的笔记曾把这条当成它的根因——
那是**过头了**，同一天的真机 A/B 已推翻：**DSH 在首句之后几秒内就落 `session/title`**，
而 `session/title` 会触发 `sessionList` 重读（`connector/src/protocol/host-state.ts`
的 `hostStateForSessionEvent`），行当场归真。实测日志：发完一句 1 秒内顶栏就从
「新建会话」变成会话标题，紧接着点 ＋ 正常换页。
所以这个窗口是**秒级**的，不是持续现象；那条反馈的根因**仍未确定**。
本笔记只记录下面这条不变量与它的测试，不宣称它治好了那次反馈。


## Decision

在收 delta 的唯一那一处（`_onDelta` 的 `turn/start` 分支）把那一行翻成 `blank: false`，
理由与宿主同源：`blank` 是缓存的宿主字段，我们已经在收它变化的那条事件。

准入门槛（可机械判定）：

1. 单测：`session.list` 给一行 `blank: true` → 推一条 `turn/start` →
   `sessionOf(sid)!.blank == false` 且 `findBlankSession() == null`
   （`app/test/new_session_workspace_test.dart` 的「跑过一轮之后这一行不再算 blank」）。
2. 真机：旧会话上点 ＋ → 顶栏变「新建会话」+ hero；发过一句之后再点 ＋ 仍能换到新会话
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

- 收益：`blank` 缓存与宿主规则对齐，复用判据在那几秒窗口里也说真话；
  抽屉不会把刚聊过的会话画成「新建会话」；hero ↔ 正文的切换不再等清单刷新。
- 代价：手机侧的 `blank` 有了第二个写入口（宿主的清单 + 本地的 `turn/start`）。
  两者是**同一条规则的两处应用**，靠 `list.ts:51` 的引用与门槛 1 钉住；
  宿主将来改这条规则，两处要一起改。
- **未做 / 未证**：「点新建会话没用」那条反馈的根因没找到。已排除的：
  代码路径（真机 A/B 正常换页）、内容缓存（`_derivationFor` 按 sid + 来源同一性失效）。
  仍可能的：落点就在电脑侧已有的 blank 上（那是 DSH 的 reuse-or-create，本就不是 bug）、
  已配对但断连时的写失败（toast 在，页面不动）。
