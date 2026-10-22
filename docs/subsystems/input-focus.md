# 输入焦点（输入法何时允许出现）

手机端的输入法**只能由用户点输入框引起**。抽屉、底部 sheet、锚定浮层、push 出去的全屏页
（设置 / 用量）—— 这些页面级转换无论开还是关，都不许把输入法叫回来。

## 1. 为什么会有这个问题（框架行为，双向都搬焦点）

1. 抽屉打开时 `DrawerController._ensureHistoryEntry()` 执行
   `FocusScope.of(context).setFirstFocus(_focusScopeNode)`
   （`packages/flutter/lib/src/material/drawer.dart:538`）—— 焦点被搬进抽屉。
   路由同理：`ModalScope._routeSetState` 把自己设成 first focus
   （`packages/flutter/lib/src/widgets/routes.dart:1169-1171`）。
2. 关掉之后框架把**页面里上一次的焦点节点**设回去 —— `FocusScopeNode` 记得 `focusedChild`
   （`packages/flutter/lib/src/widgets/focus_manager.dart:1444-1461`，
   `:1503-1515` 按 `focusedChild` 往下恢复）。
3. 输入框一拿回焦点就走 `EditableText._handleFocusChanged`，第一句是
   `_openOrCloseInputConnectionIfNeeded()`
   （`packages/flutter/lib/src/widgets/editable_text.dart:4752-4753`）→ 输入法弹出。

会话页唯一的输入框是输入栏（`app/lib/ui/dsh_composer.dart` 的 `TextField`）；用户只要点过它
一次，它就一直是"上一次的焦点"。

## 2. 收口点

`app/lib/ui/input_focus.dart` 提供两个函数：

| 函数 | 做什么 |
|---|---|
| `dismissInputFocus()` | 对**当前 primary focus** 调 `unfocus(disposition: scope)`；根作用域（`context == null`）跳过 |
| `dismissInputFocusAround(open)` | 上面的开前收一次 + `open()` 结束后再收一次（顺序不能反：翻过来会顶掉浮层自己的 `autofocus`） |

`UnfocusDisposition.scope` 会 `scope._focusedChildren.clear()`
（`packages/flutter/lib/src/widgets/focus_manager.dart:929-940`），于是框架之后想「还焦点给
上次那个输入框」时，作用域里已经没有它了 —— 这一帧输入连接根本不会被打开。

接线（全部绑在**页面级转换**上，**不许**绑到输入框的点击路径 —— 那会把点击吃掉）：

| 转换 | 位置 |
|---|---|
| 左抽屉开 / 关 | `ui/chat_page.dart` 的 `Scaffold.onDrawerChanged` |
| 右抽屉开 / 关 | 同一 `Scaffold` 的 `onEndDrawerChanged` |
| 底部 sheet 开 / 合 | `ui/dsh_sheet.dart` 的 `showDshSheet` |
| 锚定浮层开 / 合 | `ui/dsh_popover.dart` 的 `showDshPopover` |
| 设置页 / 用量页 push · pop | `ui/chat_page.dart` 的 `openFromDrawer`（外层只给 route） |

### 2.1 抽屉先收、再 push

从抽屉里跳全屏页的顺序是**同步收抽屉 + 同一拍 push**，收抽屉那条叫 `ChatPageState.closeDrawer()`
（就是 `ScaffoldState.closeDrawer()`），**不是** `Navigator.maybePop()`：

- 抽屉打开时给当前路由挂一个 `LocalHistoryEntry`（`material/drawer.dart:529-541`），
  所以"收抽屉"过去写成 `maybePop()`；
- 而 `NavigatorState.maybePop` 是 `async`，`await willPop()` 回来后重新取栈顶、
  发现变了就直接放弃（`widgets/navigator.dart:5539,5547-5551`）——
  "收抽屉 + 紧接 push"正好是这个形状，于是那句静默失效，抽屉一直开着；
- `ScaffoldState.closeDrawer()` 自己摘 history entry（`drawer.dart:543-549`），没有这一步。

因果与被否方案见 `.agents/notes/implemented/2026-10-22-drawer-close-before-push.md`。

## 3. 判据

- widget 测：`app/test/input_focus_test.dart` —— 点输入框（焦点在、输入法在）→ 开抽屉 →
  点空白关闭 → 输入框**没有**焦点、`TestTextInput.isVisible` 为 false。
  变异校验：把 `onDrawerChanged` 换成空回调，该测红在 `hasFocus` 断言上。
- widget 测：`app/test/drawer_close_before_push_test.dart` —— 走 `openFromDrawer` push 一页再
  `pop`，`Scaffold.isDrawerOpen` 必须为 false（同一处也钉住"先收抽屉"）。
- 真机：`dumpsys input_method` 的 `mInputShown`。2026-10-22（`d61cf622`）修前是
  「开抽屉 false → 关闭 400ms 后 true」，修后关闭后 0.4s / 2s 均为 false；
  设置页 push·pop 同一条也为 false。

## 4. 已知副作用

- 关抽屉会**顺手收起键盘**（包括抽屉里「搜索会话」正在输入时）—— 抽屉已关，焦点没有落脚点。
- 以后若往抽屉里放 `autofocus` 控件，需要它自己在 `initState` 之后再请求焦点，
  否则会被这次失焦顶掉。
