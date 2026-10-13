# Agent Note: App 前后台态必须由 observer 报给连接，且只把 `resumed` 当前台

Status: implemented

## Problem

`SyncClient.setAppState` 是"要不要维持连接"的唯一入口（`core/sync_client.dart` 的接口注释
原话："装配点决定何时开始，前台/后台决定要不要维持"），而在它挂上
`WidgetsBindingObserver` 之前，`app/lib` 里**没有任何调用点** —— 客户端从构造起就以为
自己在**前台**。两个后果都只在真机上看得见：

1. 电脑侧 `foreground` 档的审批接管判据是"前台且已订阅该 sid"
   （`connector/src/protocol/takeover.ts` 的 `rank`；`presence.ts` 的 `foreground`
   由 `sync.hello` 的 `app` 字段置位）。一部退到后台的手机仍被当成"用户正看着手机"，
   审批继续推给它，看护在那儿白等；
2. 契约 §2.2 的"切后台主动断开并停表"、§13 的"三端都不做后台长连接"、§9 的
   "心跳仅在前台发"——三条全部落空，连接在后台活着、心跳照走。

契约 §6.3.1 明写"要恢复桌面接管，把开关设为 `never` 或让 App 退到后台
（`foreground` 档下会自动 delegate）"——**那条产品行为此前是断的**，而没有任何测试或
日志会指出来：这是"装配点少接一根线"的标准形状，不报错、只是静默不工作。

## Decision

在装配点（`app/lib/main.dart` 的根 State）挂一个 `AppStateReporter`
（`app/lib/platform/app_state_reporter.dart`，一个 `WidgetsBindingObserver`），
`didChangeAppLifecycleState` 调 `client.setAppState(appStateOf(state))`。

映射**只把 `resumed` 算前台，其余一律后台**。依据是一手的：Flutter 引擎对 `resumed`
的定义是"可见**且有输入焦点**"，对 `inactive` 的定义是"至少一个视图可见、但都没有
输入焦点"（来电、权限弹窗、分屏失焦、通知栏下拉、任务切换器可见），并明说此态下
"应假设随时可能 hidden / paused"（`flutter/engine/src/flutter/lib/ui/platform_dispatcher.dart`
的 `AppLifecycleState` 文档注释）。契约 §6.3.1 的 claim 判据是"用户正看着手机"——
没有输入焦点就不成立，所以 fail-closed。

准入门槛（可机械判定）：

1. `app/lib` 里 `setAppState` 必须有**产品代码**调用点，且不在 `core/`：
   `grep -r setAppState app/lib` 必须命中 `platform/app_state_reporter.dart` 与
   `main.dart`，只命中 `core/` 定义与测试替身算不通过。
2. 注册与摘除成对：`assembly_invariants_test.dart` 断言 `main.dart` 里
   `addObserver(_reporter)` 与 `removeObserver(_reporter)` 都在，且摘除在 `dispose` 里。
3. 映射由行为用例钉死：`app/test/app_state_reporter_test.dart` 把五个态逐个喂进
   `tester.binding.handleAppLifecycleStateChanged`，只有 `resumed` 产出
   `AppState.foreground`。
4. 客户端**现取不持有**：`AppStateReporter` 持一个取值函数，换 `AppModel` 后上报
   落到新的那个（用例钉：先报旧的、再报新的）。

## Alternatives considered

1. **`inactive` 不算后台**（只把 `paused` / `hidden` / `detached` 当后台）
   - 最强的理由：`inactive` 多是过渡态（来电、权限弹窗、iOS 多任务预览、桌面失焦），
     不断开就少一次重连；分屏场景里用户仍**看得见**卡片，推给他比推给桌面更贴场景。
   - 为何被否：契约 §6.3.1 的 claim 判据是"用户正看着手机"，而 Flutter 对 `inactive`
     的定义是"可见但没有输入焦点"—— 用户点不了那张卡片，审批会在手机上挂到看护
     10 分钟超时才 fail-closed 还桌面。分屏场景的代价（秒级重连）小于"审批挂在一台
     点不动的手机上十分钟"。
2. **放在 UI 层**（比如 `ChatPage` 的 `initState`）
   - 最强的理由：不用碰装配点，页面 State 本来就有生命周期钩子。
   - 为何被否：前后台是**应用级**事实而非页面级 —— `ChatPage` 不总在场，而连接是
     应用级的；且 `ui/` 层禁止 import 平台实现（`verify-platform-boundary.mjs` 的
     `ui-no-impl-import` / `branch-whitelist`），做了就破边界。
3. **让 `SyncClient` 自己观察生命周期**
   - 最强的理由：调用点只有一个，装配点不用管，也不会有人忘了挂。
   - 为何被否：`core/` 禁止 import `package:flutter/*`
     （`core-no-platform-import`，判据是"core 能在没有 UI、没有平台代码的情况下跑绿"），
     而观察生命周期必须 import flutter。把平台知识塞进 core 会让 core 的单测也需要
     Flutter 绑定，那条判据是整个分层的地基。
4. **用 `AppLifecycleListener`（Flutter 3.13+ 的新 API）**
   - 最强的理由：按态分回调（`onResume` / `onInactive` …），不用自己 switch。
   - 为何被否：它同样只给态、映射逻辑一行都省不掉，且同样是平台耦合、同样住
     `platform/`；observer 是 cookbook 既定做法，换 API 没有换来任何判据的变化。

## Consequences

- 收益：退后台立刻声明 `app=background` 并断开停表（§2.2 / §13 / §9 三条同时成立），
  电脑侧 `foreground` 档停止把审批推给后台手机，并按 §6.3.1 **自动 delegate 回桌面** ——
  契约里写着的产品行为自此真的成立。
- 收益：回前台的重连走既有路径（`setAppState(foreground)` → `start()` → `sync.hello`
  整份重新声明订阅集），**没有引入新机制**，恢复语义仍只有一处。
- 代价：分屏失焦、通知栏下拉、来电这类"可见但无焦点"的态也会断开并还桌面 ——
  秒级重连，且这期间审批落桌面。这是 fail-closed 的既定方向，不是回归。
- 代价：`didChangeAppLifecycleState` 与 `setAppState` 的异步存在交错窗口
  （`inactive → resumed` 很快时，后台那次 `_disconnect()` 可能落在前台 `_connect()`
  之后），表现为多一次重连。**刻意不加顺序锁**：§2.2 明说"重连是常态，不是异常路径"，
  且状态机白名单保证交错只落到 `closed → backoff → 重连`，自愈；加锁是为一个秒级
  自愈的场景引入第二套状态。
- 边界（如实记录）：冷启动若不在前台（透明 activity 等极端情况）仍按客户端的
  `foreground` 初相走。**不特判**：引擎状态机的初相是 `detached`
  （`platform_dispatcher.dart` 的文档原话），读 `SchedulerBinding.instance.lifecycleState`
  反而会误报成后台；而移动端冷启动必然附着到视图，实际不可达。
