/// 发送模式：会话正在跑轮次时，这句话**排到下一个轮次**还是**插进当前轮次**。
///
/// DSH 原生的二选一 —— 设置项"繁忙时的发送行为"
/// （`packages/client/ui-conversation/src/client/locales.ts:73-76`，存在 Host），
/// 取值决定调 `session.startTurn`（排队）还是 `session.steer`（插话）
/// （`packages/api/../dsh-bridge/src/bridge-service.ts:368,378`）。
/// 我们这边**一个方法带 `mode` 参数**（`connector/src/handlers.ts` 的
/// `session.prompt` 收 `'queue' | 'steer'`，透到 DSH 的 `prompt(mode)`），
/// 所以照搬二选一即可，不扩方法面（设置搬运清单里这项标的就是"搬"）。
///
/// 插话只在会话正在跑轮次时可用：DSH 的文案是"仅运行中可插话发送"
/// （`locales.ts:365`），而轮次已变时 DSH 回 `session/steer-unavailable`
/// （见 `core/errors.dart`）—— 所以界面上那一项在非运行态是禁用的，
/// 不是"点了再说"。
library;

/// 见文件头。
enum SendMode {
  /// 排到下一个轮次（默认，与 DSH 的"排队发送"一致）。
  queue('排队发送', 'queue', 'queue'),

  /// 插进当前轮次（DSH 的"插话发送"；仅运行中可插话发送）。
  steer('插话发送', 'steer', 'rightUp');

  const SendMode(this.label, this.wire, this.icon);

  /// 界面上显示的名字（照 DSH 的文案）。
  final String label;

  /// 线上值：`session.prompt` 的 `mode` 参数。
  final String wire;

  /// 控制行那个 34px 图标的 DSH 图标名（`theme/dsh_icons.dart`）。
  ///
  /// 只存名字不 import theme：`model/` 是领域层，不认识视觉层。
  final String icon;

  /// 线上值 → 枚举。**认不出回 `null`**（调用方决定默认值），不猜。
  static SendMode? fromWire(Object? raw) {
    if (raw is! String) return null;
    for (final mode in SendMode.values) {
      if (mode.wire == raw) return mode;
    }
    return null;
  }
}
