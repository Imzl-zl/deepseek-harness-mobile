/// 输入焦点在「页面级转换」上的收口 —— 输入法不许自己弹出来（2026-10-22）。
///
/// ## 为什么需要它：框架双向都会搬焦点
///
/// 1. **搬进浮层**：抽屉打开时 `DrawerController._ensureHistoryEntry()` 执行
///    `FocusScope.of(context).setFirstFocus(_focusScopeNode)`
///    （`packages/flutter/lib/src/material/drawer.dart:538`）—— 焦点被搬进抽屉。
///    路由（设置页 / 用量页 / 底部 sheet / 锚定浮层）push 时同理：`ModalScope`
///    在 `_routeSetState` 里把自己设成 first focus
///    （`packages/flutter/lib/src/widgets/routes.dart:1169-1171`）。
/// 2. **搬回页面**：抽屉 / 路由关闭后，框架又把**页面里上一次的焦点节点**设回
///    first focus —— `FocusScopeNode` 记得自己的 `focusedChild`
///    （`packages/flutter/lib/src/widgets/focus_manager.dart:1444-1461` 的
///    `setFirstFocus` 走 `_doRequestFocus(findFirstFocus: true)`，而
///    `:1503-1515` 就是用 `focusedChild` 往下恢复）。
/// 3. 输入框一拿回焦点就走 `EditableText._handleFocusChanged`，它的第一句是
///    `_openOrCloseInputConnectionIfNeeded()`
///    （`packages/flutter/lib/src/widgets/editable_text.dart:4752-4753`）
///    —— 于是**输入法自己弹出来**，用户根本没点输入框。
///
/// 真机证据（2026-10-22，`d61cf622`）：抽屉打开时 `dumpsys input_method` 的
/// `mInputShown=false`；点空白关掉抽屉后 400ms 变 `true` 并保持（截图
/// `shots-2026-10-22/g2-after-close.png`）。这就是「每次回来都要关输入法」。
///
/// ## 做法：只在转换点失焦
///
/// `FocusNode.unfocus(disposition: UnfocusDisposition.scope)` 会
/// `scope._focusedChildren.clear()`（`packages/flutter/lib/src/widgets/focus_manager.dart:929-940`），
/// 之后框架想「把焦点还给上次那个输入框」时，作用域里**已经没有它了**。
///
/// 两个必须守住的边界：
///
/// - **只绑在转换点上**（抽屉开关 / sheet 与浮层开合 / 路由 push·pop）。
///   绑到输入框的点击路径上会把点击吃掉 —— 那正是「点了没反应」的形状。
/// - **不能对根作用域动手**：根作用域没挂到任何 widget 上（`FocusNode.context`
///   为 null），对它失焦只会把焦点再往上挪一层，没有任何收口效果。
///
/// 调用点：`chat_page.dart` 的 `Scaffold.onDrawerChanged` / `onEndDrawerChanged`、
/// `dsh_sheet.dart` 的 `showDshSheet`、`dsh_popover.dart` 的 `showDshPopover`、
/// `main.dart` 的 `_openSettings` / `_openUsage`。
///
/// Note: 为什么只许绑在转换点、为什么不用 `keyboardDismissBehavior` —— 见
/// `.agents/notes/implemented/2026-10-22-input-focus-only-from-user-tap.md`。
library;

import 'package:flutter/widgets.dart';

/// 让当前焦点失焦，且**不**还给同一作用域里的上一个焦点节点。
///
/// 见本文件头部：清的是「作用域记得的那个输入框」，不是输入框自己。
void dismissInputFocus() {
  final primary = FocusManager.instance.primaryFocus;
  if (primary == null || primary.context == null) return;
  primary.unfocus(disposition: UnfocusDisposition.scope);
}

/// 包住一次「页面级打开」：**先**失焦（此时输入框还是 primary，最有效），
/// 结束后再兜一次（框架在 pop 时可能已经把焦点还回去了）。
///
/// 顺序是硬要求：先失焦再 `show`，浮层里自己的 `autofocus`（如设置页搜索框）
/// 才不会被这次失焦顶掉。
Future<T?> dismissInputFocusAround<T>(Future<T?> Function() open) async {
  dismissInputFocus();
  try {
    return await open();
  } finally {
    dismissInputFocus();
  }
}
