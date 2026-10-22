# Agent Note: 输入法只能由用户点输入框引起（页面级转换统一失焦）

Status: implemented

## Problem

用户在真机上反复遇到同一件事：「输入框老是自动调出输入法…我都没点击输入框…每次回来都要关」。

这是**框架行为**，我们一处都没兜：

1. 抽屉打开时 `DrawerController._ensureHistoryEntry()` 执行
   `FocusScope.of(context).setFirstFocus(_focusScopeNode)`
   （`packages/flutter/lib/src/material/drawer.dart:538`）—— 焦点被搬进抽屉。
   路由 push（设置页 / 用量页 / sheet / 锚定浮层）同理：
   `ModalScope._routeSetState` 把自己设成 first focus
   （`packages/flutter/lib/src/widgets/routes.dart:1169-1171`）。
2. 关掉之后框架把**页面里上一次的焦点节点**设回去 —— `FocusScopeNode` 记得自己的
   `focusedChild`（`packages/flutter/lib/src/widgets/focus_manager.dart:1444-1461` 的
   `setFirstFocus` 走 `_doRequestFocus(findFirstFocus: true)`，`:1503-1515` 用
   `focusedChild` 往下恢复）。
3. 输入框一拿回焦点就走 `EditableText._handleFocusChanged`，它的第一句是
   `_openOrCloseInputConnectionIfNeeded()`
   （`packages/flutter/lib/src/widgets/editable_text.dart:4752-4753`）—— 输入法弹出来。

会话页唯一的输入框是输入栏（`ui/dsh_composer.dart` 的 `TextField`），只要用户**曾经**
点过它，它就一直是"上一次的焦点"，于此后每次开合抽屉 / 关弹层 / 从设置页返回都会弹输入法。

**真机证据（2026-10-22，`d61cf622`，修前）**：

| 时刻 | `dumpsys input_method` 的 `mInputShown` |
|---|---|
| 抽屉打开后 | **false**（焦点确实被搬进抽屉） |
| 点空白关闭抽屉后 400ms | **true** |
| 关闭后 1.6s | **true** |

截图 `D:\tmp\dsh-e2e\shots-2026-10-22\g2-after-close.png`：抽屉已关、输入法自己弹出来。

## Decision

新增 `app/lib/ui/input_focus.dart`，只做一件事：

```dart
void dismissInputFocus() {
  final primary = FocusManager.instance.primaryFocus;
  if (primary == null || primary.context == null) return;   // 根作用域不动
  primary.unfocus(disposition: UnfocusDisposition.scope);
}
```

`UnfocusDisposition.scope` 分支会 `scope._focusedChildren.clear()`
（`packages/flutter/lib/src/widgets/focus_manager.dart:929-940`）—— 之后框架想「把焦点
还给上次那个输入框」时，作用域里**已经没有它了**。这比"事后再收一次键盘"可靠：
后者会在中间那一帧把输入连接开起来。

四个转换点各接一次（**都绑在页面级转换上，不碰输入框的点击路径**）：

| 转换点 | 接在哪 |
|---|---|
| 左抽屉开/关 | `chat_page.dart` 的 `Scaffold.onDrawerChanged` |
| 右抽屉开/关 | 同一个 `Scaffold` 的 `onEndDrawerChanged`（与它原有的指标刷新合在一处） |
| 底部 sheet 开/合 | `dsh_sheet.dart` 的 `showDshSheet`（`dismissInputFocusAround`，开前 + 合后） |
| 锚定浮层开/合 | `dsh_popover.dart` 的 `showDshPopover`（同上） |
| 设置页 / 用量页 push·pop | `main.dart` 的 `_openSettings` / `_openUsage`（push 前 + `.whenComplete`） |

**顺序是硬要求**：先失焦再 `show`。反过来的话，浮层里自己的 `autofocus`
（设置页搜索框 `settings_page.dart:899`）会被这次失焦顶掉，搜索框拿不到焦点。

## Alternatives considered

1. **`keyboardDismissBehavior` / `onTapOutside`**
   - 最强理由：一行属性，最省事，语义就是"点空白收键盘"。
   - 为何被否：它们解决的是"用户点空白 → 收键盘"，而这里是**框架主动把焦点还给输入框**
     ——`onTapOutside` 根本没被触发（没有 tap 落到输入框之外的可命中区域？
     有，但键盘是在那之后又被焦点恢复打开的）。改不动焦点所有权，症状会原样留下。
2. **在输入框上包一层 `Focus`，让它"不许被恢复"**
   - 最强理由：从所有权上根治，一个包裹层解决所有转换点。
   - 为何被否：`FocusNode.canRequestFocus = false` 会让**用户自己也点不进去**
     （点击路径与框架恢复走同一个 `requestFocus`），而这是输入栏的主路径。
     要区分"谁在请求焦点"就得自己维护一套来源标记，比四个转换点各收一次复杂得多。
3. **关掉 `Scaffold.drawer`，自己写抽屉**
   - 最强理由：不受 `DrawerController` 的 `setFirstFocus` 影响。
   - 为何被否：那会把跟手拖出、遮罩点击、系统返回键三件事全部重写一遍
     （`material/drawer.dart` 的 `_move` / `_settle` / local history entry），
     而本条只是"关掉之后别还焦点"。代价与收益完全不成比例。
4. **在 `pop` 之后延迟一帧再收键盘**
   - 最强理由：改动最小，不用碰焦点。
   - 为何被否：迟一帧意味着输入连接**已经开过**（`_handleFocusChanged` 是同步跑完的），
     真机上就是"输入法闪一下再收回去"。用户报的正是这个闪烁。

## Consequences

- 收益：抽屉 / 弹层 / 路由四种转换都不再还焦点给输入栏，输入法只能由用户点输入框引起。
  真机复验（修后，同一台机器）：点输入框 `mInputShown=true` → 开抽屉 `false` →
  点空白关闭后 0.4s / 2s 都是 `false`；设置页 push·pop 同一条也是 `false`
  （截图 `g11-fixed.png`、`g13-back-from-settings.png`）。
- 代价：
  - 抽屉关闭时**会顺手收起键盘**：用户若在抽屉的「搜索会话」里打字，关抽屉即结束输入。
    这是想要的行为（抽屉已关，焦点没有落脚点），但它确实是一处行为变化。
  - `dismissInputFocus` 对**当前 primary** 动手，所以它必须发生在转换的**起点**。
    以后若有人把某个 `autofocus` 控件放进抽屉里，需要在那个控件自己 `initState` 之后
    再请求焦点 —— 否则会被这一次失焦顶掉。
  - 这条规则**不允许**扩展到"任何点击都失焦"：那会吃掉输入框的点击（点输入框 → 失焦 →
    键盘永远起不来）。
- widget 测：`app/test/input_focus_test.dart` 钉「关掉抽屉后输入框没有焦点、输入法没有被
  重新叫起来」。**做过变异校验**：把 `onDrawerChanged` 换成空回调，该测当场红在
  `hasFocus` 断言上（`Expected: false / Actual: <true>`）—— 证明它不是恒真。
- 真机观察（本轮**未处理**，与焦点链无关）：从设置页返回后，抽屉是**开着**的
  （`ui.xml` 里能读到抽屉的「新建会话」行 `[32,256][897,372]`）。`_openSettings` 里那句
  `maybePop()` 的意图是"先收抽屉再 push"。下一轮若追这条，判据是先确认
  `ModalRoute.popDisposition` / `didPop`（`widgets/routes.dart:942-966`）在
  push 紧随其后的时序里到底有没有把 local history entry 拿掉。
