/// 粘顶的折叠行标题（DSH 的 `position: sticky`）。
///
/// ## 它治什么
///
/// 展开后的「思考过程」可以很长。DSH 的正文**不封顶**，靠 CSS
/// `position: sticky`（`ui-chat/src/client/chat/ReasoningRow.module.css:15-21`）
/// 把标题行钉在视口顶部 —— 正文滚到哪，"想折叠"都够得着。
///
/// Flutter 没有 sticky。真正的等价物是 `SliverPersistentHeader`，而那要求
/// **整个聊天流是 sliver**（标题与正文得是两个相邻的 sliver）—— 正文现在长在
/// 消息条目里面，改它等于重写消息渲染。所以这里用同一效果的另一种实现：
/// 展开的折叠行把自己的标题登记进来，滚动时若它的标题已经滚出视口顶、正文
/// 还在视口里，就在**列表顶部画一份同样的标题**（点了就是折叠）。
///
/// ## 判据
///
/// - 只钉"标题在视口顶之上、正文还没离开视口"的那些（`recompute`）；
/// - 多个同时满足时取**最后登记的那个** —— 与 DOM 里后一个 sticky 把前一个
///   顶出去同向；
/// - 滚动一帧只算几个矩形，且只有"钉谁变了"才通知重建。
///
/// Note: 取舍（为什么不是 sliver 重构）见
/// `.agents/notes/implemented/2026-11-04-sticky-disclosure-header.md`。
library;

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';

/// 一条可粘顶的折叠行（由 `_CollapsibleNote` 在展开时登记）。
class StickyNote {
  const StickyNote({
    required this.headerKey,
    required this.bodyKey,
    required this.header,
  });

  /// 行标题（视口里的那一份）——用来算"滚过去了没有"。
  final GlobalKey headerKey;

  /// 展开的正文 —— 用来算"还在不在视口里"。
  final GlobalKey bodyKey;

  /// 钉在顶部时画什么（与行标题同一个 widget，`open: true`）。
  final Widget Function() header;
}

/// 登记处：谁在展开、这一刻该钉谁。
class StickyNoteController extends ChangeNotifier {
  final Map<int, StickyNote> _notes = <int, StickyNote>{};
  StickyNote? _active;

  /// 这一刻该钉在顶部的那一条；`null` = 不钉。
  StickyNote? get active => _active;

  /// 一条折叠行展开了：登记它。
  void attach(int id, StickyNote note) {
    _notes[id] = note;
  }

  /// 收起了 / 销毁了：注销，并把它从"正在钉"里摘掉。
  void detach(int id) {
    if (_notes.remove(id) == null) return;
    final active = _active;
    if (active != null &&
        _notes.values.every((note) => !identical(note, active))) {
      _active = null;
      notifyListeners();
    }
  }

  /// 按视口顶部（全局坐标）重算该钉谁。
  ///
  /// 只在"钉谁变了"时通知：滚动时每帧都会调它，而每帧重建整棵列表是没必要的。
  void recompute(double viewportTop) {
    StickyNote? next;
    for (final note in _notes.values) {
      final header = _rectOf(note.headerKey);
      final body = _rectOf(note.bodyKey);
      if (header == null || body == null) continue;
      // 标题已经滚到视口顶之上，而正文还没完全离开视口。
      if (header.top < viewportTop - 0.5 && body.bottom > viewportTop + 0.5) {
        next = note;
      }
    }
    if (identical(next, _active)) return;
    _active = next;
    notifyListeners();
  }

  static Rect? _rectOf(GlobalKey key) {
    final object = key.currentContext?.findRenderObject();
    if (object is! RenderBox || !object.hasSize) return null;
    return object.localToGlobal(Offset.zero) & object.size;
  }
}

/// 把控制器递给子树里的折叠行。
class StickyNotes extends InheritedNotifier<StickyNoteController> {
  const StickyNotes({
    super.key,
    required StickyNoteController controller,
    required super.child,
  }) : super(notifier: controller);

  /// 子树里的登记处；不在 [StickyNoteHost] 里就是 `null`（折叠行照旧工作，只是不钉）。
  static StickyNoteController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StickyNotes>()?.notifier;
}

/// 把列表里展开中的折叠行标题钉在视口顶部。
///
/// 用法：把要滚的那一块（`ListView` / `CustomScrollView`）包进来即可 ——
/// 滚动通知靠 [NotificationListener] 旁听，不改变列表自己的滚动行为。
class StickyNoteHost extends StatefulWidget {
  const StickyNoteHost({super.key, required this.child});

  /// 会滚的那一块。
  final Widget child;

  @override
  State<StickyNoteHost> createState() => _StickyNoteHostState();
}

class _StickyNoteHostState extends State<StickyNoteHost> {
  final StickyNoteController _controller = StickyNoteController();
  final GlobalKey _viewport = GlobalKey();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double get _viewportTop {
    final object = _viewport.currentContext?.findRenderObject();
    if (object is! RenderBox) return 0;
    return object.localToGlobal(Offset.zero).dy;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return StickyNotes(
      controller: _controller,
      child: Stack(
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification ||
                  notification is ScrollUpdateNotification ||
                  notification is ScrollEndNotification) {
                // **量位置要等这一帧画完**：滚动通知是在 `setPixels` 里发的，
                // 那一刻子节点的 paint offset 还是上一帧的 —— 当场 `localToGlobal`
                // 会读到"没滚"的坐标，钉住的标题永远不出现（第一版就栽在这）。
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  _controller.recompute(_viewportTop);
                });
              }
              return false;
            },
            child: KeyedSubtree(key: _viewport, child: widget.child),
          ),
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final active = _controller.active;
              if (active == null) return const SizedBox.shrink();
              return Positioned(
                key: const ValueKey('sticky-note-header'),
                top: 0,
                left: 0,
                right: 0,
                child: Material(
                  // 正文从它下面滚过去 —— 底色必须不透明，否则两层字叠在一起。
                  color: c.bgBase,
                  child: active.header(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
