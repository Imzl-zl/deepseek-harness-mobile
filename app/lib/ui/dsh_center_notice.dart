/// **屏幕中央**的一句结果（消失得比 toast 慢一点，不挡操作）。
///
/// ## 为什么要它
///
/// 插件行的开关、包的卸载结果，都是"刚才那一下成了没有"这一句话 —— 而页面
/// 可能已经被滚到很下面。以前那句话是列表**顶部**的一张卡片：滚动之后就看不见，
/// 用户看到的是"点了，什么都没发生"。用户原话：
/// 「点击停用，居然弹框在上面都被遮挡了？不是屏幕居中？？」
///
/// 于是这里有三种情况里的第三种：
///
/// - 结果在屏幕上**直接看得见** → 不弹（见 `dsh_toast.dart` 的规则）；
/// - 结果看不见、但**与某个控件的位置有关** → `DshToast`（底部浮条）；
/// - 结果看不见、且**用户此刻在看哪儿说不准**（列表可以滚）→ 这里，屏幕中央。
///
/// ## 它不是一个新的视觉语言
///
/// 卡片与 `DshToast` 同一套 token（`layer2` 底 + 描边 + `labelPrimary` 13px），
/// 只是位置换成居中；不引遮罩、不挡点击（`IgnorePointer`），到点自己消失。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';

/// 屏幕中央的一句提示（同一时刻只留一条）。
abstract final class DshCenterNotice {
  static OverlayEntry? _entry;
  static Timer? _timer;

  /// 弹一条。`error` 只影响图标、颜色与停留时长。
  ///
  /// 时长是**界面参数**（不是业务规则）：普通 2.2 s，错误 4 s —— 够读完一句话，
  /// 又不会赖在屏幕中间。
  static void show(BuildContext context, String message, {bool error = false}) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final colors = context.dshColors;
    dismiss();
    final entry = OverlayEntry(
      builder: (_) => _Notice(message: message, error: error, colors: colors),
    );
    _entry = entry;
    overlay.insert(entry);
    _timer = Timer(Duration(milliseconds: error ? 4000 : 2200), dismiss);
  }

  /// 立刻收掉（页面已经在拆的时候也要能安全调用）。
  static void dismiss() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }
}

class _Notice extends StatefulWidget {
  const _Notice({
    required this.message,
    required this.error,
    required this.colors,
  });

  final String message;
  final bool error;
  final DshColorTokens colors;

  @override
  State<_Notice> createState() => _NoticeState();
}

class _NoticeState extends State<_Notice> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    // 下一帧再亮：这样淡入真的看得见（第一帧就 1.0 等于没有动画）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return Positioned.fill(
      // **不挡操作**：滚动、点按照常穿透，这句话只是"看得见"。
      child: IgnorePointer(
        child: Center(
          child: AnimatedOpacity(
            opacity: _visible ? 1 : 0,
            duration: const Duration(milliseconds: 140),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Semantics(
                liveRegion: true,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 320),
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  decoration: BoxDecoration(
                    color: c.layer2,
                    borderRadius: BorderRadius.circular(DshRadius.md),
                    border: Border.all(
                      color: widget.error ? c.stateError : c.layer3,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x40000000),
                        blurRadius: 18,
                        offset: Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.error) ...[
                        DshIcon(
                          'warningTriangle',
                          size: 16,
                          color: c.stateError,
                        ),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Text(
                          widget.message,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: c.labelPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
