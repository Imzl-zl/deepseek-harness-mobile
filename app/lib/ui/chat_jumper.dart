/// 对话流的快速跳转钮（rikkahub 的 `MessageJumper`）。
///
/// ## 它是什么
///
/// 右侧贴着的一列四个圆钮，**滚动停下 1.5 秒后淡出**：
///
/// | 钮 | 动作 |
/// |---|---|
/// | 到顶 | 跳到最早一条（会话开头） |
/// | 上一条 | 往上挪**一条**（按条目，不按像素） |
/// | 下一条 | 往下挪**一条** |
/// | 到底 | 跳到最新一条（会话末尾） |
///
/// 出处（`D:\sudy\github\rikkahub\app\src\main\java\me\rerere\rikkahub\ui\pages\chat\ChatList.kt`）：
/// - 四个钮与顺序：`:769-839`（`ArrowUpDouble` / `ArrowUp01` / `ArrowDown01` /
///   `ArrowDownDouble`，`verticalArrangement = spacedBy(8.dp)`）；
/// - 显隐判据：`:513` 的
///   `isRecentScroll && !state.isScrollInProgress && settings.showMessageJumper`；
/// - "最近滚动过"：`:293-302` 的 `LaunchedEffect(state.isScrollInProgress)` ——
///   滚动中置真、停 1.5 秒后置假；
/// - 进出场动画：`:755-763` 的 `slideInHorizontally` / `slideOutHorizontally`
///   （`initialOffsetX = it * 2`，从屏幕外滑进来）；
/// - 位置与左右可选：`:757` 的 `align(if (onLeft) CenterStart else CenterEnd)`，
///   由 `settings.displaySetting.messageJumperOnLeft` 决定。
///
/// ## 为什么"上一条 / 下一条"按条目而不是按像素
///
/// rikkahub 同款（`:791` 的 `animateScrollToItem(firstVisibleItemIndex - 1)`）：
/// 对话流里一条可以是一整屏（长 diff、长输出），按像素挪只会在这条内部滑，
/// 用户想要的是"**看下一条**"。
///
/// ## 与 `reverse: true` 的方向
///
/// 我们的对话流是 `reverse: true`（进会话落在最新一条）。所以：
/// - "到底" = `animateTo(maxScrollExtent)`（reverse 列表的**正最大**端是最旧）；
/// - "到顶" = `animateTo(0)`（0 端是**最新**）。
/// 两个方向都与直觉相反，所以按钮的 tooltip 不写"上/下"而写"最新/最早"，
/// 图标也用"双箭头"而不是单箭头 —— 少一个需要用户在脑子里翻转的方向。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';

/// 淡出前的静置时长（rikkahub `ChatList.kt:296` 的 `delay(1500)`）。
const Duration _kIdleBeforeHide = Duration(milliseconds: 1500);

/// 对话流快速跳转钮。
///
/// [scrollToItem] 由调用方实现（它才认识条目与 index 的对应）：
/// 参数是**相对当前第一条可见条目的偏移量**（-1 = 上一条，+1 = 下一条）。
/// [scrollToEdge] 的两个值是 `true` = 最新一端，`false` = 最早一端。
class ChatJumper extends StatefulWidget {
  const ChatJumper({
    super.key,
    required this.itemCount,
    required this.onStep,
    required this.onEdge,
    this.onLeft = false,
    this.onCreated,
  });

  /// 当前条目数（0 = 没东西可跳，整列不显示）。
  final int itemCount;

  /// 相对挪一条：[delta] 是 -1 / +1。
  final void Function(int delta) onStep;

  /// 跳到某一端：[newest] 为真 = 最新一条。
  final void Function(bool newest) onEdge;

  /// 贴左缘而不是右缘（rikkahub 的 `messageJumperOnLeft`）。
  final bool onLeft;

  /// state 建好时的回调：调用方要拿它调 `notifyScrolled()`（滚动监听在父层）。
  ///
  /// 用回调而不是 `GlobalKey`：这一个实例在整棵树里唯一，而回调不必
  /// 让父层知道 `State` 的类型名（`_ChatJumperState` 是私有的）。
  /// 参数是 [ChatJumperController]（公开接口）而不是 `State` 本身 ——
  /// 这样调用方不必 `as dynamic` 就能调 `notifyScrolled`
  /// （`avoid_dynamic_calls` 是仓库 lint，dynamic 调用过不了 `--fatal-infos`）。
  final void Function(ChatJumperController controller)? onCreated;

  @override
  State<ChatJumper> createState() => _ChatJumperState();
}

/// 跳转钮对外的唯一动作：**"刚刚滚过了"**。
///
/// 存在的理由：`_ChatJumperState` 是私有的，而调用方（对话流的滚动监听）
/// 必须能触发"显示 + 起 1.5 秒淡出计时"。给一个窄接口而不是把 State 抛出去，
/// 调用方就不需要 dynamic 调用，也不会顺手摸到不该摸的内部状态。
abstract class ChatJumperController {
  /// 滚动发生了：显示跳转钮，并（重新）起一个 1.5 秒的淡出计时。
  void notifyScrolled();
}

class _ChatJumperState extends State<ChatJumper>
    implements ChatJumperController {
  /// 最近是否滚动过（rikkahub 的 `isRecentScroll`）。
  bool _recent = false;

  /// 淡出计时器。
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    // 建好就告诉父层（它要在滚动监听里调 `notifyScrolled`）。
    widget.onCreated?.call(this);
  }

  /// 滚动发生了：显示，并（重新）起一个 1.5 秒的淡出计时。
  ///
  /// 由调用方在滚动监听里调。**滚动中重复调用会重置计时** ——
  /// 与 rikkahub 的 `LaunchedEffect(state.isScrollInProgress)` 同理
  /// （那个 effect 在 `isScrollInProgress` 变化时重启，滚动中不重启；
  /// 这里更简单：每次滚动都重置，长滚动期间不会中途消失）。
  @override
  void notifyScrolled() {
    _hideTimer?.cancel();
    if (!_recent && mounted) setState(() => _recent = true);
    _hideTimer = Timer(_kIdleBeforeHide, () {
      if (!mounted) return;
      setState(() => _recent = false);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 没条目可跳就不占位（"没有"不说成"有一个空的"）。
    if (widget.itemCount == 0) return const SizedBox.shrink();
    return Align(
      alignment: widget.onLeft ? Alignment.centerLeft : Alignment.centerRight,
      child: Padding(
        padding: EdgeInsets.only(
          left: widget.onLeft ? 8 : 0,
          right: widget.onLeft ? 0 : 8,
        ),
        // **滚动停下 1.5 秒后淡出**（rikkahub `ChatList.kt:293-302` 的
        // `isRecentScroll`）：它浮在对话流上，常驻会挡住文字。
        // 用 `AnimatedOpacity` + `IgnorePointer` 而不是直接移除：
        // 淡出过程里它还在，但点不到 —— 与 rikkahub 的
        // `AnimatedVisibility(slideIn/OutHorizontally)` 同义（那边是横滑，
        // 这里竖着来，因为这一列是竖排的）。
        // **Key 是测试的锚点**：`find.byType(AnimatedOpacity)` 在整棵树上
        // 不唯一（任何带动画的子树都算），用例会撞 "Too many elements"。
        child: AnimatedOpacity(
          key: const Key('chat-jumper-opacity'),
          opacity: _recent ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            // 同上的测试锚点（`find.byType(IgnorePointer)` 也不唯一）。
            key: const Key('chat-jumper-pointer'),
            ignoring: !_recent,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // **到顶/到底两枚带文字**：DSH 图标集里没有"双上箭头 /
                // 双下箭头"（只有 `chevronUp` / `chevronDown` /
                // `chevronsUpDown`，`verify-icons.cjs` 只放行集合内的 100 个），
                // 而两枚同图标的钮用户分不出哪个是哪个。文字 11px
                // 与 `chevronUp`/`chevronDown` 的 16px 同列，视觉上仍是一列。
                _JumperButton(
                  icon: 'chevronsUpDown',
                  tooltip: '跳到最早一条',
                  onPressed: () => widget.onEdge(false),
                  text: '最早',
                ),
                const SizedBox(height: 8),
                _JumperButton(
                  icon: 'chevronUp',
                  tooltip: '上一条',
                  onPressed: () => widget.onStep(-1),
                ),
                const SizedBox(height: 8),
                _JumperButton(
                  icon: 'chevronDown',
                  tooltip: '下一条',
                  onPressed: () => widget.onStep(1),
                ),
                const SizedBox(height: 8),
                _JumperButton(
                  icon: 'chevronsUpDown',
                  tooltip: '跳到最新一条',
                  onPressed: () => widget.onEdge(true),
                  text: '最新',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 一枚跳转钮：36×36 圆、半透明底。
///
/// 半透明是 rikkahub 同款（`copy(alpha = 0.65f)`，`ChatList.kt:777-779`）：
/// 它浮在对话流上，不透明会挡住底下的文字。
///
/// [text] 非空时它是**带文字的胶囊**（到顶 / 到底两枚）：图标集缺可区分的
/// 双箭头，文字是唯一不出错的区分（见 `build` 里的说明）。
class _JumperButton extends StatelessWidget {
  const _JumperButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.text,
  });

  final String icon;
  final String tooltip;
  final VoidCallback onPressed;

  /// 按钮上的文字（`null` = 纯图标）。
  final String? text;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: c.layer2.withValues(alpha: 0.65),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Container(
            width: 36,
            height: 36,
            padding: EdgeInsets.symmetric(horizontal: text == null ? 0 : 6),
            alignment: Alignment.center,
            // 带文字时用胶囊（宽度不变，只是圆角全圆），文字 11px 放得下两个字。
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(18)),
            child: text == null
                ? DshIcon(icon, size: 16, color: c.labelSecondary)
                : FittedBox(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DshIcon(icon, size: 12, color: c.labelSecondary),
                        const SizedBox(width: 2),
                        Text(
                          text!,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1,
                            color: c.labelSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
