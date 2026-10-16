/// DSH 顶栏（照 `mock/proto/index.html` 的 `.appbar`）。
///
/// ## 它长什么样（数值取自 `styles.css`，**不是估的**）
///
/// ```
/// ┌──────────────────────────────────────┐
/// │ ☰  标题(超长省略)  ⑵任务运行中  ⊕   │  height: 56px + safe-top
/// └──────────────────────────────────────┘
/// ```
///
/// - 左：`☰` 开抽屉（`.ib`，`panelLeft` 图标）；
/// - 中：标题，`flex:1` 且 `min-width:0` 好让省略号生效；
/// - **状态位**（`.statuspill`，`min-height:30` / `border-radius:15` /
///   `max-width:42vw`）：有后台任务显任务数，否则显文件变更；点它开右侧抽屉；
/// - 右：`＋` 新建会话（`newChat` 图标）。
///
/// ## 为什么这一条单独成组件
///
/// 三个页面（聊天 / 设置 / 任务）各有一个顶栏，而它们的左右按钮语义相同、
/// 只换标题与中段。分开写会让"抽屉按钮在聊天页是 `panelLeft`、
/// 在设置页是 `chevronLeft`"这类不一致悄悄出现。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';

/// 顶栏上的一个图标按钮（`.ib`）。
///
/// 尺寸是原型里那个圆钮：`38×38`（`--r-19`），图标 18~20。
class DshAppBarButton extends StatelessWidget {
  const DshAppBarButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.size = 18,
  });

  /// DSH 图标名（必须是 [DshIcons.names] 里的一员）。
  final String icon;

  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: 38,
      height: 38,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Center(
            child: DshIcon(icon, size: size, color: DshColors.labelSecondary),
          ),
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// 顶栏中段的状态胶囊（`.statuspill`）。
///
/// 两种内容（照原型）：**有后台任务显任务**，否则显文件变更。
/// 它是"会话现在在忙什么"的唯一常驻信号 —— 所以哪怕为空也占位
/// （不占位的话标题会随内容左右跳）。
class DshStatusPill extends StatefulWidget {
  const DshStatusPill({
    super.key,
    required this.text,
    required this.onPressed,
    this.icon = 'loading',
    this.isWarn = false,
    this.spin = false,
  });

  final String text;
  final VoidCallback onPressed;
  final String icon;

  /// 告警色（比如任务失败、有越权操作待批）。
  final bool isWarn;

  /// 图标是否**转圈**。
  ///
  /// 连接中 / 重连中必须转：一个静止的加载图标会被读成"卡住了"
  /// （2026-10-15 真机反馈："右上角这个重连,他有个图标,但是不转圈,
  /// 我都以为卡住了"）。静止的图标传达的是"没有在动"，而不是"在等"。
  final bool spin;

  @override
  State<DshStatusPill> createState() => _DshStatusPillState();
}

class _DshStatusPillState extends State<DshStatusPill>
    with SingleTickerProviderStateMixin {
  /// **只在真的要转圈时才建**。
  ///
  /// 两个坑都踩过：`late final` 懒建会在 `dispose` 里第一次触发创建（元素已
  /// deactivate，造 ticker 直接抛）；无条件建则让一个不转的胶囊也挂着一个
  /// 常驻 ticker，跨用例不停就会污染后面的测试。
  AnimationController? _controller;

  void _startSpin() {
    _controller ??= AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    // `repeat()` 回 `TickerFuture`，这里不关心它何时完成。
    unawaited(_controller!.repeat());
  }

  void _stopSpin() => _controller?.stop();

  /// 取（必要时建）转圈控制器。**只在 `spin` 为真时被调**，
  /// 所以不转的胶囊不会挂 ticker；`repeat()` 的 future 不关心完成。
  AnimationController _spinController() {
    final existing = _controller;
    if (existing != null) return existing;
    final created = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _controller = created;
    unawaited(created.repeat());
    return created;
  }

  @override
  void initState() {
    super.initState();
    if (widget.spin) _startSpin();
  }

  @override
  void didUpdateWidget(DshStatusPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.spin == oldWidget.spin) return;
    if (widget.spin) {
      _startSpin();
    } else {
      _stopSpin();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isWarn ? DshColors.roleTool : DshColors.labelSecondary;
    return ConstrainedBox(
      // `max-width: 42vw`：标题优先，胶囊不能把标题挤没。
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.42,
        minHeight: 30,
      ),
      child: Material(
        color: widget.isWarn ? DshColors.roleToolBg : DshColors.layer2,
        borderRadius: BorderRadius.circular(15),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.spin)
                  RotationTransition(
                    turns: _spinController(),
                    child: DshIcon(widget.icon, size: 13, color: color),
                  )
                else
                  DshIcon(widget.icon, size: 13, color: color),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    widget.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: color),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 聊天页顶栏。
class ChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ChatAppBar({
    super.key,
    required this.title,
    required this.onOpenDrawer,
    required this.onNewSession,
    this.statusText,
    this.statusIcon = 'loading',
    this.statusIsWarn = false,
    this.statusSpin = false,
    this.onStatusTap,
  });

  final String title;

  /// `☰` —— 主入口（会话抽屉）。
  final VoidCallback onOpenDrawer;

  /// `＋` —— 新建会话。
  final VoidCallback onNewSession;

  /// 状态胶囊的文字；`null` = 不显示胶囊。
  final String? statusText;
  final String statusIcon;
  final bool statusIsWarn;

  /// 状态位图标是否**转圈**（连接中 / 握手中 / 重连中）。
  ///
  /// 由调用方按连接状态给：静止的加载图标会被读成"卡住了"
  /// （2026-10-15 真机反馈："他有个图标,但是不转圈,我都以为卡住了"）。
  /// 「连接不上」不转 —— 那是结论,不是等待。
  final bool statusSpin;
  final VoidCallback? onStatusTap;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final status = statusText;
    return Container(
      color: DshColors.sidebar,
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
      height: 56 + MediaQuery.of(context).padding.top,
      child: Row(
        children: [
          const SizedBox(width: 4),
          DshAppBarButton(
            icon: 'panelLeft',
            tooltip: '打开会话抽屉',
            onPressed: onOpenDrawer,
          ),
          const SizedBox(width: 2),
          // `flex:1` + `min-width:0`：标题长了省略，且**不挤走右侧**。
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: DshColors.labelPrimary,
              ),
            ),
          ),
          if (status != null) ...[
            const SizedBox(width: 6),
            DshStatusPill(
              text: status,
              icon: statusIcon,
              isWarn: statusIsWarn,
              // 转圈由调用方按**连接状态**决定（连接中 / 握手中 / 重连中），
              // 不是按告警色 —— 「未连接」不需要转,「连接不上」是结论也不转。
              spin: statusSpin,
              onPressed: onStatusTap ?? () {},
            ),
          ],
          const SizedBox(width: 2),
          DshAppBarButton(
            icon: 'newChat',
            tooltip: '新建会话',
            onPressed: onNewSession,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

/// 顶部分段控件（`.seg`，对话 / 轨迹）。
///
/// 数值取自原型：`padding:3` / `border-radius:999`，
/// 滑块（`.seg-ind`）随选中项平移 —— **这是动画，不是两个静态高亮**。
class DshSegmented extends StatelessWidget {
  const DshSegmented({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: DshColors.layer1,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i += 1)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(i),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    // 选中项有底色滑块（未选中透明）—— 这就是 `seg-ind`。
                    color: i == index ? DshColors.layer3 : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: i == index
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: i == index
                          ? DshColors.labelPrimary
                          : DshColors.labelSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
