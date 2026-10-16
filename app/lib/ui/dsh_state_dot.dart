/// DSH 状态点 —— 照 DSH `packages/client/ui-primitives` 的 `StateDot`。
///
/// ## 为什么照抄而不是自己画一个圆点
///
/// 圆点看起来是"随便画一个就行"的东西，但 DSH 已经把它的语义、尺寸和颜色定死了：
/// 五个语义态（`StateDot.tsx:9`）、实心点 = 10px 槽里画 **6px 核**
/// （`StateDot.module.css:1-15` 的 `inset: 20%`）、转圈态 = **14px 环 + 弧、1.5s 匀速**
/// （`StateDot.tsx:50`、`module.css:37-45`）。
/// 自己画一个"差不多大"的点，就是第二个真值源：DSH 调了尺寸这边不知道，
/// 用户看到的是两套状态语义（Web 一个样、手机一个样）。
///
/// 颜色全部来自 [DshColors]（`stateSuccess` / `stateError` / `stateIdle` / `stateWarn`
/// 与 `labelTertiary`），不在这里取色 —— 三端唯一颜色来源的规矩。
///
/// ## 转圈为什么用 `loading` 图标
///
/// DSH 的转圈态是"25% 透明度的整环 + 转动的弧"（`module.css:47-56`）。
/// 图标集里没有"带整环的转圈"这个字形，最接近且**同样出自 DSH 图标集**的是
/// `loading`（就是那条弧，`ui-primitives/src/icons/index.tsx:727-731`），
/// 旋转周期照 DSH 的 1.5s。**不新增字形**（图标集硬规则）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../model/chat_item.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';

/// 状态点的语义（与 DSH `StateDotState` 一一对应，`StateDot.tsx:9`）。
///
/// `done` 绿 / `warning` 琥珀 / `ongoing` 转圈 / `error` 红 / `idle` 中性。
enum DshStateDotState {
  /// 做完了（绿）。
  done,

  /// 需要用户注意（琥珀）。
  warning,

  /// 进行中（转圈）。
  ongoing,

  /// 出错（红）。
  error,

  /// 空闲（中性灰）—— "这个被跟踪的东西现在什么也没在发生"。
  idle,
}

/// 连接状态 → 状态点的语义。
///
/// 三档的来源是 DSH 的 `ConnectionIndicator`（它只有
/// `disconnected|connecting|recovered` 三态，`ui-primitives/src/ConnectionIndicator.tsx:7-11`）：
///
/// - **服务中** → `done`（绿）：连线正常，没有要用户做的事；
/// - **连接中 / 握手中 / 重连中** → `ongoing`（转圈）：在等，而且**必须转**
///   —— 静止的图标会被读成"卡住了"（2026-10-15 真机反馈）；
/// - **其余**（未连接 / 已断开 / 连接不上）→ `error`（红）：需要用户做点什么。
///
/// 映射放在这里而不是调用方：与 [connectionLabel]（同一状态的说法）一样，
/// **一个状态只在一处决定它长什么样** —— 顶栏、以后任何地方画的点都读同一个函数。
DshStateDotState dotStateOf(ConnectionStateView state) => switch (state) {
  ConnectionStateView.serving => DshStateDotState.done,
  ConnectionStateView.connecting ||
  ConnectionStateView.handshaking ||
  ConnectionStateView.backoff => DshStateDotState.ongoing,
  _ => DshStateDotState.error,
};

/// 一个状态点。尺寸与颜色照 DSH，见文件头。
class DshStateDot extends StatefulWidget {
  const DshStateDot(this.state, {super.key});

  final DshStateDotState state;

  @override
  State<DshStateDot> createState() => _DshStateDotState();
}

class _DshStateDotState extends State<DshStateDot>
    with SingleTickerProviderStateMixin {
  /// **只在真的转圈时才建**（与 `DshStatusPill` 同一条纪律）：
  /// 无条件建会让每个不转的点都挂一个常驻 ticker，跨用例不停就污染后面的测试；
  /// `late final` 懒建则会在 `dispose` 里第一次触发创建，元素已 deactivate，直接抛。
  AnimationController? _controller;

  void _startSpin() {
    _controller ??= AnimationController(
      vsync: this,
      // 1.5s 匀速：照 `StateDot.module.css:42-45` 的 `1.5s linear`。
      duration: const Duration(milliseconds: 1500),
    );
    unawaited(_controller!.repeat());
  }

  AnimationController _spinController() {
    final existing = _controller;
    if (existing != null) return existing;
    _startSpin();
    return _controller!;
  }

  @override
  void initState() {
    super.initState();
    if (widget.state == DshStateDotState.ongoing) _startSpin();
  }

  @override
  void didUpdateWidget(DshStateDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state == oldWidget.state) return;
    if (widget.state == DshStateDotState.ongoing) {
      _startSpin();
    } else {
      _controller?.stop();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// 实心态的颜色。转圈态走 `labelTertiary`（`StateDot.module.css:39`），不走这里。
  Color get _solidColor => switch (widget.state) {
    DshStateDotState.done => DshColors.stateSuccess,
    DshStateDotState.warning => DshColors.stateWarn,
    DshStateDotState.error => DshColors.stateError,
    DshStateDotState.idle => DshColors.stateIdle,
    DshStateDotState.ongoing => DshColors.labelTertiary,
  };

  @override
  Widget build(BuildContext context) {
    if (widget.state == DshStateDotState.ongoing) {
      return SizedBox(
        width: 14,
        height: 14,
        child: RotationTransition(
          turns: _spinController(),
          child: const DshIcon(
            'loading',
            size: 14,
            color: DshColors.labelTertiary,
          ),
        ),
      );
    }
    // 实心点：10px 的槽、6px 的核（`StateDot.module.css:1-15`）。
    return SizedBox(
      width: 10,
      height: 10,
      child: Center(
        child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: _solidColor, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
