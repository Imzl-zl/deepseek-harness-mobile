# Agent Note: 抽屉会话行的四态状态点（照 DSH 的 `Rows.tsx`，未读状态是派生、不落盘）

Status: implemented

## Problem

抽屉里每一行只有一枚 6px 的"当前会话"点（`session_drawer.dart`：`session.isActive ? accentBlue : 透明`），
**没有任何运行态**。多会话并行时看不出"哪个在跑、哪个跑完了、哪个在等我"，而这三种事实
在 2026-10-24 之后**全都已经在手机上**：

| 事实 | 来源 |
|---|---|
| 在不在跑 | `status` 帧 + `session.list` 的 `running` → `AppModel._runningSids`（唯一真值，`runningOf`） |
| 有没有人在等 | `session.list` 行上的 `pendingCount`（待处理集合的投影） |
| 刚跑完、但我没看着 | **没有** —— 需要新算 |

第三条是唯一缺口，而 DSH 的浏览器也**不落盘**地算了它：`completionUnread`
（`packages/client/ui-session/src/client/index.ts:292` 的 `Set<SessionId>`）。

## Decision

**行首那枚点改成"状态点"，四态带优先级，未读收口由 `AppModel` 派生（不落盘）；
"是不是当前会话"改由行底色表达。**

- 优先级与形态照 DSH：`ui-workspace/src/client/rows/Rows.tsx:344-398` 的
  `sessionStatuses`（待处理 > 运行中 > 已完成 > 空闲）、`ui-primitives/src/StateDot.tsx:44-77`。
  纯函数落在 `app/lib/model/session_dot.dart`（`sessionDotOf`），**这一层不重算优先级**。
- 颜色映射（本仓自己的三枚语义 token，不自造色值）：
  `warning → stateWarn`、`ongoing → accentBlue`、`done → stateSuccess`、`idle → stateIdle`。
- `AppModel` 新增 `_completionUnread` + `completionUnreadOf`，**只在 `_setRunning` 的收口边沿
  置位**，条件是 `was && sid != currentSid`（三条规则对 DSH `:490-498,511` 的等价物）；
  `openSession` 打开时清掉（"看见了"）。
- **不采用"当前会话 = 蓝点"**：当前由底色说，与 DSH 一致（它的当前行靠 label 强调 + 背景）。

## Alternatives considered

1. **本地"已读表"落盘**（用户最初的建议，走 `_prefs` 的 `kSendModeKey` 那族）。
   最强理由：杀掉 App 再打开还能看见绿点，符合"未读"的直觉。
   被否：DSH 的浏览器端就只是一个内存 `Set`，**刷新即丢**；落盘会让"已读"变成第二份真值，
   而它与"我正在看哪个会话"这件事天然同步不了（换设备/重连/清数据各有一套边界）。
   代价如实记在下面的 Consequences。
2. **直接用行上的 `s.running`**（`session.list` 的快照）。
   最强理由：不用碰 `AppModel`，一行就画出来。
   被否：那是**快照**，`status` 帧之后就不准了；W4 已经把"在不在跑"的唯一真值收进
   `_runningSids`，用行上的值等于把刚废弃的第二真值请回来。
3. **照 DSH 画两枚点**（自己在跑 + 有子智能体在跑）。
   最强理由：DSH 有（`Rows.tsx:352-362` 的 `subagents` 那一枚）。
   被否：手机侧没有 `runningSubagentCount`（`session.list` 的行里没有这个字段，宿主
   `SessionSummary` 也没有），为了一枚点去加字段要先问宿主有没有 —— 它没有，本仓不新造。
   子智能体在跑由顶栏那枚 chip 表达（`dsh_app_bar.dart` 的 `running`）。

## Consequences

- **收益**：多会话并行时一眼看出"谁在跑 / 谁跑完了 / 谁在等我"；三个输入都是既有事实，
  没有新存储、没有新协议、没有新方法。
- **代价（如实记）**：`completionUnread` **杀 App 即丢**（与浏览器刷新一致）——它只是提示，
  不是持久事实。这是本次唯一"看起来像缺失"的地方，不改。
- **代价**：行首点不再表示"当前会话"；若用户习惯靠那枚蓝点定位当前行，现在要靠底色。
  底色本来就有（`isActive ? layer2 : transparent`），所以信息没丢，只是换了载体。
- **没有新契约**：`session.list` 与 `status` 的形状一个字没动。

## 判据

`app/test/session_dot_test.dart`（5 条）+ `app/test/session_drawer_test.dart`（+1 条）：

- 优先级四条组合；"别的会话跑完 ⇒ 置位 / 打开它就清掉"；"正在看的那个跑完 ⇒ 不置位"；
  **"基线（首包就是 false）不造绿点"**；"先 true 后 false 的快照也置位"（断线期间跑完、重连纠正）。
- widget：四行分别画琥珀 / 蓝 / 绿 / 灰，且**当前会话仍是 idle**（点不表示"我正在看它"）。
- **变异校验**：把 `_setRunning` 的 `if (was && …)` 改成 `if (sid != _currentSid)` ⇒
  **恰好**那条"基线不造绿点"红，其余 4 条仍绿（做完即还原）。

门禁：flutter **1145 → 1151**、boundary **360 → 363**（+1 个 Dart 文件）、
`dart analyze --fatal-infos` 0、`dart format --set-exit-if-changed` 0。

## 代码入口回指

`app/lib/model/session_dot.dart`（优先级纯函数）、`app/lib/data/app_model.dart` 的
`_completionUnread` / `_setRunning` / `completionUnreadOf`、`app/lib/ui/session_drawer.dart` 的行首点、
`app/lib/main.dart` 的 `rowOf`（唯一装配点）。
