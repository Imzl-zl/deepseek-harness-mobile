/// 后台任务结束要不要发通知（设备本地策略，默认 **关**）。
///
/// ## 为什么默认关
///
/// 通知的判据是"需要你动手"：审批、提问、整轮跑完都属于它；而"某个后台命令
/// 跑完了"不需要任何操作。一次会话里五个命令 = 五条通知，用户会被训练成
/// 见通知就关权限。
///
/// 但长任务**失败**时那一轮可能还要跑二十分钟，所以留一个可主动订阅的档，
/// 而不是彻底删掉这一类。取舍见
/// `.agents/notes/proposed/2026-11-13-notify-only-actionable.md`。
library;

/// 三档：关 / 仅失败·已停止 / 全部。
enum TaskNoticePolicy {
  off('关', 'off'),
  failures('仅失败', 'failures'),
  all('全部', 'all');

  const TaskNoticePolicy(this.label, this.wire);

  /// 设置页那一行显示的名字。
  final String label;

  /// 落盘值（`device.notify_tasks`）。
  final String wire;

  /// 认不出回 `null`（调用方按 [off] 处理，不猜）。
  static TaskNoticePolicy? fromWire(Object? raw) {
    if (raw is! String) return null;
    for (final value in values) {
      if (value.wire == raw) return value;
    }
    return null;
  }

  /// 这条任务状态该不该提醒。`running` / `stopping` 永远不会走到这里
  /// （调用方只对落终态的行问）。
  bool allows(String jobStatus) => switch (this) {
    TaskNoticePolicy.off => false,
    // `failed` / `killed` 是需要人看的两个收口（`core/job.dart` 的 statusText）。
    TaskNoticePolicy.failures => jobStatus == 'failed' || jobStatus == 'killed',
    TaskNoticePolicy.all => true,
  };
}
