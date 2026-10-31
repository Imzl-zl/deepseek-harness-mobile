/// 把高频通知压成"每帧最多一次"。
///
/// ## 它治的是什么
///
/// `AppModel` 是 `ChangeNotifier`，流式输出时一秒能通知几十次（每收到一批 delta
/// 就通知一次）。而它的听众里有**整页订阅**：`ChatPage` 的根
/// `ListenableBuilder`、以及 `main.dart` 里构造抽屉与 `ChatPage` 的那一层。
/// 一次通知 = 整棵会话树重建一次（含抽屉 sections、侧栏、列表、统计条）。
///
/// 通知次数 > 帧率的那些时刻（一次恢复的批量事件、工具结果成串到达），
/// 重建就会**堆在同一帧里做多遍**，而屏幕上只需要最后那一次结果。
///
/// ## 为什么是"每帧一次"而不是节流到某个频率
///
/// 节流（比如 10Hz）会让文字一顿一顿地出 —— 那是产品行为变更。压到"每帧一次"
/// 不改变任何可见节奏：同一帧内多次变化，本来就只会显示最后一次的结果。
///
/// ## 时序（第一发不延迟）
///
/// - **帧外（事件回调里）的第一发：立刻转发**。理由：那是"状态刚变、还没排帧"的
///   时刻，延迟它只会让一次点击/一次状态切换多等一帧，而没有任何合并收益。
/// - **同一帧内的后续通知**：合并，等本帧结束（布局已完成）再发一次，
///   由下一帧重建。
///
/// 所以"每帧最多一次"成立，同时"变一下就立刻反映"也成立。
///
/// Note: 为什么整页订阅要靠这一层而不是拆监听（拆是更大的改造）—— 见
/// `.agents/notes/implemented/2026-10-31-ui-perf-review.md`。
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 把 [source] 的通知合并成"每帧最多一次"的 [Listenable]。
class FrameCoalescedListenable extends ChangeNotifier {
  FrameCoalescedListenable(this._source) {
    _source.addListener(_onSource);
  }

  final Listenable _source;

  bool _scheduled = false;
  bool _disposed = false;

  /// 这一帧已经转发过一次了（同一帧内的后续通知要合并）。
  bool _notifiedThisFrame = false;

  void _onSource() {
    if (_disposed) return;
    final binding = SchedulerBinding.instance;
    // 帧外第一发：立刻转发，不额外等一帧。
    if (!_notifiedThisFrame && binding.schedulerPhase == SchedulerPhase.idle) {
      _notifiedThisFrame = true;
      notifyListeners();
      // 帧结束时解锁（`notifyListeners` 会经 `setState` 排一帧，所以这个回调跑得到；
      // 万一没有听众、排不出帧，下一次通知会走下面的合并分支并 `ensureVisualUpdate`）。
      binding.addPostFrameCallback((_) {
        _notifiedThisFrame = false;
        _scheduled = false;
      });
      return;
    }
    if (_scheduled) return;
    _scheduled = true;
    // **必须保证还会来一帧**：如果此刻没有排队的帧，post-frame 回调永远不执行。
    binding.ensureVisualUpdate();
    binding.addPostFrameCallback((_) {
      _scheduled = false;
      if (_disposed) return;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _source.removeListener(_onSource);
    super.dispose();
  }
}

/// 与 `ListenableBuilder` 同形，但把 [listenable] 的通知压成每帧一次。
///
/// 用法与 `ListenableBuilder` 完全一致，替换掉即可。
class FrameCoalescedBuilder extends StatefulWidget {
  const FrameCoalescedBuilder({
    super.key,
    required this.listenable,
    required this.builder,
    this.child,
  });

  final Listenable listenable;
  final TransitionBuilder builder;

  /// 交给 [builder] 的静态子树（与 `ListenableBuilder.child` 同义）。
  final Widget? child;

  @override
  State<FrameCoalescedBuilder> createState() => _FrameCoalescedBuilderState();
}

class _FrameCoalescedBuilderState extends State<FrameCoalescedBuilder> {
  late FrameCoalescedListenable _coalesced;

  @override
  void initState() {
    super.initState();
    _coalesced = FrameCoalescedListenable(widget.listenable);
  }

  @override
  void didUpdateWidget(FrameCoalescedBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换了订阅对象（比如换了电脑 = 换了一个 `AppModel`）：重建合并器。
    if (!identical(oldWidget.listenable, widget.listenable)) {
      _coalesced.dispose();
      _coalesced = FrameCoalescedListenable(widget.listenable);
    }
  }

  @override
  void dispose() {
    _coalesced.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _coalesced,
    builder: widget.builder,
    child: widget.child,
  );
}
