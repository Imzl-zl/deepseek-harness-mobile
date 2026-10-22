/// 运行中行的**文字扫光** —— 照 DSH 的 `TextShimmer`。
///
/// ## DSH 是怎么做的（逐项对照）
///
/// `packages/client/ui-primitives/src/TextShimmer.tsx:37-57` + `TextShimmer.module.css:34-87`：
///
/// - 真实文字**不动**，上面再叠一份**同一段文字**（`aria-hidden`），染成
///   `--dsw-alias-label-shimmer`；
/// - 叠层被一条 105° 的渐变遮罩切成一条带：
///   `linear-gradient(105deg, transparent 0%, black 40% 60%, transparent 100%)`；
/// - 遮罩从 `translateX(-100%)` 扫到 `+100%`，而里层文字反向 `+100% → -100%`
///   —— 两者相抵，**文字在屏幕上不动，动的是那条带子**；
/// - `1.5s` / 延迟 `0.3s` / `steps(48, end)` / 无限；扫到 `66.6667%` 就停在右边缘，
///   剩下 1/3 周期是空档（所以"闪一下、停一下"）；
/// - `prefers-reduced-motion: reduce` 时整个叠层 `display: none`（`:79-87`）。
///
/// ## 这里的两条实现纪律
///
/// 1. **全 App 只有一个 ticker**。每行各建一个 `AnimationController` 会在长会话里
///    挂几十个常驻动画（`dsh_state_dot.dart:83-95` 就是为这件事把控制器改成"只在该转时建"）。
///    所以相位由一个 [DshShimmerHost] 里的单一控制器驱动，行只在**自己真的在跑**时
///    挂上去、跑完就摘掉；一行都没有时控制器**停**（不空转烧电）。
/// 2. **静止的行不许闪**：`active == false` 时直接返回原 widget，连 `Stack` 都不建。
///
/// 颜色：DSH 的 `--dsw-alias-label-shimmer` 是
/// `color-mix(in srgb, neutral-00 45%, transparent)`（深色 `design-platform.css:342`）/
/// `neutral-1000 30%`（浅色 `:224`）。这里从 `labelPrimary` 按同一个比例派生，
/// 不新增字面色值。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';

/// 扫光叠层的 key —— 用例靠它数"屏幕上有几条在动的行"。
const Key shimmerMaskKey = ValueKey<String>('dsh-shimmer-mask');

/// 把扫光时钟挂在整棵树上（`MaterialApp.builder` 里一层就够）。
///
/// 没有它也能跑：`DshShimmer` 找不到宿主时**原样返回子节点**，不闪也不崩
/// （单测里直接 pump 某个页面就是这样）。
class DshShimmerHost extends StatefulWidget {
  const DshShimmerHost({super.key, required this.child});

  final Widget child;

  @override
  State<DshShimmerHost> createState() => _DshShimmerHostState();
}

class _DshShimmerHostState extends State<DshShimmerHost>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  /// 单调时钟（秒）。相位从它算，**不从控制器算** —— 控制器会被停/启，
  /// 而每行的 0.3s 延迟要的是一个连续的时间轴。
  final Stopwatch _clock = Stopwatch();

  int _active = 0;

  double get clock => _clock.elapsedMicroseconds / 1e6;

  AnimationController get controller => _controller ??= AnimationController(
    vsync: this,
    // 1.5s 一个周期（`TextShimmer.module.css:63`）；`repeat()` 只当重绘驱动，
    // 真正的位置由 [clock] 决定。
    duration: const Duration(milliseconds: 1500),
  );

  void attach() {
    _active += 1;
    if (_active != 1) return;
    _clock.start();
    unawaited(controller.repeat());
  }

  void detach() {
    if (_active == 0) return;
    _active -= 1;
    if (_active != 0) return;
    _controller?.stop();
    _clock.stop();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _DshShimmerScope(
      state: this,
      // `prefers-reduced-motion` 的 Flutter 对应物是 `MediaQuery.disableAnimations`。
      enabled: !MediaQuery.disableAnimationsOf(context),
      child: widget.child,
    );
  }
}

class _DshShimmerScope extends InheritedWidget {
  const _DshShimmerScope({
    required this.state,
    required this.enabled,
    required super.child,
  });

  final _DshShimmerHostState state;
  final bool enabled;

  static _DshShimmerScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DshShimmerScope>();

  @override
  bool updateShouldNotify(_DshShimmerScope oldWidget) =>
      oldWidget.enabled != enabled || !identical(oldWidget.state, state);
}

/// 一段会扫光的文字。**只在 [active] 为真时扫**（真的在跑的行）。
///
/// 用法就是把原来那个 `Text` 包进来：
/// `DshShimmer(active: running, child: Text(...))`。
class DshShimmer extends StatefulWidget {
  const DshShimmer({super.key, required this.active, required this.child});

  final bool active;

  final Widget child;

  @override
  State<DshShimmer> createState() => _DshShimmerState();
}

class _DshShimmerState extends State<DshShimmer> {
  _DshShimmerHostState? _host;
  bool _attached = false;

  /// 这一行**开始跑**的时刻（宿主时钟，秒）—— 对应 CSS 的 `animation-delay: .3s`。
  double _startedAt = 0;

  bool get _wants {
    final scope = _DshShimmerScope.maybeOf(context);
    return widget.active && (scope?.enabled ?? false);
  }

  void _sync() {
    final host = _DshShimmerScope.maybeOf(context)?.state;
    _host = host;
    final wants = _wants;
    if (wants && !_attached && host != null) {
      _startedAt = host.clock;
      host.attach();
      _attached = true;
    } else if (!wants && _attached) {
      _host?.detach();
      _attached = false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(DshShimmer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    if (_attached) _host?.detach();
    super.dispose();
  }

  /// 相位（0..1）：`steps(48, end)` 离散化，扫到 2/3 就停在右边缘。
  double get _phase {
    final host = _host;
    if (host == null) return 0;
    final t = host.clock - _startedAt - 0.3;
    if (t <= 0) return 0;
    final stepped = ((t / 1.5) % 1) * 48;
    return stepped.floor() / 48;
  }

  @override
  Widget build(BuildContext context) {
    final scope = _DshShimmerScope.maybeOf(context);
    if (!_attached || scope == null || !scope.enabled) return widget.child;
    final tint = shimmerTintOf(context);
    return AnimatedBuilder(
      animation: scope.state.controller,
      builder: (context, _) => Stack(
        children: [
          widget.child,
          // 叠层不吃指针事件：否则按钮/行点击会被这层挡住。
          Positioned.fill(
            child: IgnorePointer(
              child: ShaderMask(
                key: shimmerMaskKey,
                blendMode: BlendMode.srcIn,
                shaderCallback: (rect) => _sweepShader(rect, _phase, tint),
                child: widget.child,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 扫光的染色 —— 见文件头最后一段（从 `labelPrimary` 按 DSH 的比例派生）。
Color shimmerTintOf(BuildContext context) {
  final c = context.dshColors;
  final alpha = c.brightness == Brightness.dark ? 0.45 : 0.30;
  return c.labelPrimary.withValues(alpha: alpha);
}

/// 一条 105° 的带子：中心随相位从屏幕左侧扫到右侧，过了 2/3 停在右边缘。
Shader _sweepShader(Rect rect, double phase, Color tint) {
  // 相位 0..1 映射到 translateX(-100% → +100%)，2/3 之后保持 +100%。
  final t = phase <= 2 / 3 ? phase * 3 - 1 : 1.0;
  final center = 0.5 + t;
  const halfWidth = 0.12; // `black 40% 60%` = 宽度 ±10%，留一点羽化
  final lo = (center - halfWidth).clamp(0.0, 1.0);
  final mid = center.clamp(0.0, 1.0);
  final hi = (center + halfWidth).clamp(0.0, 1.0);
  return LinearGradient(
    // CSS 的 105deg（自"向上"顺时针量）≈ 屏幕坐标里偏右、略向下。
    begin: const Alignment(-1, -0.27),
    end: const Alignment(1, 0.27),
    colors: [tint.withValues(alpha: 0), tint, tint.withValues(alpha: 0)],
    stops: [lo, mid, hi],
  ).createShader(rect);
}
