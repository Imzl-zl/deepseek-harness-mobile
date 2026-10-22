# Agent Note: 收抽屉要用 `closeDrawer()`，不能用 `Navigator.maybePop()`

Status: implemented

## Problem

真机（`d61cf622`）复现三次：☰ → 设置 → 返回，回到聊天页时**抽屉还开着**。

`main.dart` 的 `_openSettings` 里那句本意是"先收抽屉再 push"：

```dart
unawaited(navigatorKey.currentState?.maybePop());
unawaited(navigatorKey.currentState?.push(MaterialPageRoute<void>(...)));
```

它**一次都没生效**，而且是静默的。根因在框架的两处实现（本机 SDK 3.41.9）：

1. 抽屉不是一条路由 —— 打开时它给**当前路由**挂一个 `LocalHistoryEntry`
   （`packages/flutter/lib/src/material/drawer.dart:529-541`），"收抽屉"于是表现为
   "吃掉当前路由的一个 local history entry"（`widgets/routes.dart:950-967` 的 `didPop`
   摘掉最后一条并 `return false`，路由本身不 pop）。
2. `NavigatorState.maybePop` 是 `async`：它 `await lastEntry.route.willPop()`
   （`widgets/navigator.dart:5539`；`willPop` 自己也是 `async`，
   `widgets/routes.dart:934` / `:2008`），**回来之后重新取一次栈顶**，
   发现"不是刚才那个"就直接放弃：

   ```dart
   final _RouteEntry? newLastEntry = _lastRouteEntryWhereOrNull(...);
   if (lastEntry != newLastEntry) {
     // Forget about this pop, something happened to our history in the meantime.
     return true;
   }
   ```
   （`navigator.dart:5547-5551`）

我们**同一拍就 push 了**设置页 ⇒ 栈顶变了 ⇒ `maybePop` 走这条"忘掉"分支，
`didPop` 根本没被调用，抽屉的 history entry 一个都没摘掉。

复现证据（widget 级，见下）：同一段代码执行完，`Scaffold.isDrawerOpen` 仍是 `true`；
而设置页**没有被立刻 pop 掉**（那条断言是绿的），说明 `pop()` 压根没执行 ——
正好对上"忘掉这次 pop"那条分支，而不是"pop 晚了一拍弹掉了新页面"。

## Decision

1. `ChatPageState` 新增 `closeDrawer()` —— 直接 `ScaffoldState.closeDrawer()`
   （`material/scaffold.dart:2437` → `drawer.dart:543-549` 自己摘 history entry），**同步**。
2. 新增 `ChatPageState.openFromDrawer(Route)`：先收抽屉、再 push，
   开 / 关各收一次输入法（复用 `ui/input_focus.dart` 的 `dismissInputFocusAround`，
   取代 `_openSettings` / `_openUsage` 里各自手写的那一份）。
3. `main.dart` 里**所有**"从抽屉里跳走"的入口都改成 `_closeDrawer()` / `_openFromDrawer()`：
   会话行、连接行（未配对）、设置、用量、归档 sheet、连接操作 sheet、新建会话、
   「还没做」提示。**不再有一处用 `maybePop()` 表达"收抽屉"**。
4. 唯一保留的 `maybePop()` 是用量页里的"点会话行 → 关掉用量页"—— 那是**路由**，
   它压在最上面且紧接着没有 push，没有这个竞态。

## Alternatives considered

1. **`await` 一下再 push**（`await navigatorKey.currentState?.maybePop(); push(...)`）
   - 最强理由：一行改动，语义不变，还留住了"抽屉是 local history entry"这层抽象。
   - 为何被否：它靠的是"pop 一定在 push 之前跑完"这一条时序假设，而这条假设的前提是
     **调用点没有人紧接着改栈**。以后任何一个"收抽屉 + 立刻跳转"的新入口都会重新踩同一坑，
     而且症状是静默的（抽屉开着而已）。更重要的是：抽屉关不关与"能不能 pop 掉一整条路由"
     是两件事，`maybePop` 把后者也做了 —— 万一哪天在抽屉没开时调用，它会**把聊天页本身 pop 掉**。
2. **用 `Scaffold.of(context).isDrawerOpen` 判一下再 `maybePop()`**
   - 最强理由：只在真的开着时才 pop，避免误 pop 整页。
   - 为何被否：判完到真的 pop 之间还是异步的（同样的两段 `await`），竞态没消，只是加了条件。
3. **保持 `maybePop()`，改成"push 之前先 `await` 一帧"（`await SchedulerBinding.endOfFrame`）**
   - 最强理由：不动调用点结构。
   - 为何被否：帧边界不是这条竞态的边界 —— 只要栈顶在 `maybePop` 恢复之前变过，它就放弃；
     而"同一拍 push"本来就是我们想要的即时性。用一个与原因无关的延时去兜，属于碰运气。

## Consequences

- 收益：设置 / 用量 / 归档 / 连接 sheet / 新建会话这一族入口的"抽屉没关"一次收口，
  而且不再有"在抽屉里点东西把聊天页 pop 掉"的潜在误 pop。
- 代价：
  - 抽屉的开合从"路由栈语义"变成"Scaffold 自己的开合"，两个概念在 `ChatPageState` 上各有一个方法
    （`openDrawer` / `closeDrawer`）—— 这是本页**唯一**的抽屉入口，外部不要再绕过它;
  - `_openSettings` / `_openUsage` 的输入法收口搬进了 `openFromDrawer`（少了两处重复），
    代价是"输入法纪律"与"收抽屉"现在绑在同一个方法里：将来若有"不开全屏页也要收抽屉"的新路径，
    它得单独调 `closeDrawer()`，不能指望 `openFromDrawer`。
- 判据：
  - widget：`app/test/drawer_close_before_push_test.dart` —— 走生产通路
    `openFromDrawer` push 一页、再 `pop`，断言 `Scaffold.isDrawerOpen == false`。
    变异校验做过：把它改回 `unawaited(maybePop())` + push，该条红在 `isDrawerOpen` 上（恰好一条）。
  - 真机（`d61cf622`，debug 包 `adb install -r` 原地装，`firstInstallTime` 未变）：两轮完整证据
    `D:\tmp\dsh-e2e\shots-2026-10-22\a1-drawer-open.png` / `a2-settings-page.png` /
    `a3-after-back-drawer-closed.png`，以及 `a6-1-drawer.png` / `a6-2-settings.png` /
    `a6-3-back.png`；返回后是聊天页、抽屉不在树里，`dumpsys input_method` 的 `mInputShown=false`
    （G 的输入法纪律没被改坏）。
- 相邻但**没动**的：抽屉打开时"点空白关闭"仍走框架的 `close()`（`drawer.dart:634-637`），
  那条不经 `maybePop`，本来就没问题。
