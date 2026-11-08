# Agent Note: 新建会话按 (工作区, 预设) 合流，本地行不再自称非空

Status: implemented

## Problem

2026-11-07 真机：连点「新建会话」，电脑侧一秒内多出 3 个只有会话头的空会话
（`~/.dsh/sessions/--D-sudy-myproject-dsh-mobile--/session-b6f871ee…`，331/332 B，
创建时间 23:15:47–48）；App 抽屉里能看到它们，DSH 桌面侧一行都不显示。

两条成因都在客户端：

1. `AppModel.createSession` 没有在途去重 —— `session.create` 往返期间每点一次就再发
   一次，每次一个新 `requestId`（幂等键只防同一次操作的重发，不防"又一次操作"）。
2. 建完插入的本地行是 `SessionSummary(sid, title:'', updatedAt:0)`，`blank` 默认
   false：App 把它画成一行正常空会话，而桌面按 `sessionVisible` 把「blank 且非当前」
   的行藏掉（`ui-workspace/src/client/tree.ts:229-236`）。同一行也让
   `findBlankSession` 看不见它，复用保护形同虚设。

## Decision

照 DSH Web 的 `connectBlank` 搬两件事：

1. **在途合并**：同一 `(workspaceId, agentPreset)` 的重复调用合流到同一个 future
   （DSH：`ui-workspace/src/client/navigation.ts:224-231`），请求结束自动清表。
2. **本地行按真值写 `blank: true`，并带上 `cwd`**：`session.create` 只可能复用一个
   blank 或造一个新的，两者都还没开轮次（`api/session-controller/src/commands.ts:120-142`）；
   复用判据还要 `cwd == workspace.path`（`ui-workspace/src/client/navigation.ts:238-244`）。
   建完再 `refreshSessionRows()`，让电脑侧的标题 / 更新时间 / blank 接管。
3. **blank 行走"新建会话"这条文案**：`displayTitle` 对 blank 给「新建会话」（DSH 把
   blank 当占位行，`tree.ts:286-288`），抽屉副标题写「尚未开始」而不是"N 条"。
   原来它叫「未命名」、副标题按条目数写成"2 条" —— 新会话落下的 3 条系统事件被
   投影成条目，一个什么都没聊的会话看起来有内容（2026-11-08 真机）。

准入门槛：

1. 同一工作区连点两次 ⇒ `session.create` 只发一次（`new_session_workspace_test.dart`
   的「同一工作区连点两次」）。
2. 本地行在"清单刷新之前那一帧"必须是 `blank=true` **且 `cwd` 是这个工作区的目录**
   （监听器抓第一帧断言）。
3. 建完必重读一次会话清单（`listCalls +1`）。
4. blank 会话的 `displayTitle` 是「新建会话」，非 blank 匿名会话仍是「未命名」。

## Alternatives considered

1. **靠幂等键去重**
   - 最强的理由：写操作本来就走 outbox，`requestId` 是现成的去重机制，不用新状态。
   - 为何被否：幂等键保证的是"同一次操作的重发"不重复执行；两次点击是两个操作，
     各带自己的键。要复用它就得让第二次点击拿到第一次的键 —— 那正是一张在途表。
2. **只加一个 `_creating` 布尔，不区分工作区 / 预设**
   - 最强的理由：更简单，用户的"连点"确实落在同一个目标上。
   - 为何被否：DSH 允许同一工作区同时开不同预设的新会话（`createInWorkspace` 的
     `agentPreset` 分支），一个布尔会把两次合法点击合并掉。
3. **建完不插本地行，直接等清单刷新**
   - 最强的理由：只有一份真值，不存在"本地行撒谎"。
   - 为何被否：清单回来之前主界面没有当前会话（sid 已经有了却打不开），那一段是空白
     屏；而 `blank: true` 不是猜测，是 `session.create` 的必然结果。

## Consequences

- 收益：连点不再造空会话；抽屉与桌面看到的是同一批会话（blank 的行为一致）。
- 代价：`createSession` 多一次 `session.list` 往返（与建完后重读工作区同一档）。
- 代价：在途表按 `(工作区, 预设)` 记键，工作区很多时会短暂留几个键，请求结束即删。
- 未做：`session.create` 本身仍没有超时。桥接面没有"取消一次建会话"的方法，
  客户端加超时只会把"还在路上"说成"失败"（照项目纪律：不新增宿主没有的边界）。
