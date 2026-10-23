/// 抽屉行首那枚状态点：**四态、带优先级**。
///
/// ## 语义照 DSH，不自己发明
///
/// 优先级与文案来自 DSH 的会话行：待处理（审批 / 计划审查 / 提问）> 运行中 >
/// 已完成 > 空闲（`packages/client/ui-workspace/src/client/rows/Rows.tsx:344-398`
/// 的 `sessionStatuses`）；点的形态来自 `ui-primitives/src/StateDot.tsx:44-77`。
///
/// ## 为什么只有四态、没有第二枚点
///
/// DSH 在"自己在跑 + 有子智能体在跑"时会画**两枚**点（`Rows.tsx:352-362` 的
/// `subagents`）。手机侧没有 `runningSubagentCount` 这个投影（`session.list`
/// 的行里没有），而"为了一枚点去加一个字段"要先问宿主的 `SessionSummary` 有没有
/// —— 它没有，本仓也不新造。所以这里只有一枚，子智能体的"在跑"由顶栏那枚 chip
/// 表达（`dsh_app_bar.dart` 的 `running`）。
library;

/// 行首点的四种状态（顺序即优先级，从高到低）。
enum SessionDot {
  /// 有人在等这个会话（审批 / 计划审查 / 提问）。
  warning,

  /// 这个会话此刻在跑。
  ongoing,

  /// 跑完了、但用户离开之后才跑完（DSH 的 `completionUnread`）。
  done,

  /// 既没在跑，也没有未读的收口。
  idle,
}

/// 由三个**既有**事实算出一枚点 —— **不引入第四个真值**。
///
/// - [pendingCount]：待处理集合的投影（`AppModel.pendingCountOf`）；
/// - [running]：宿主 `status` 帧 / `session.list` 的 `running`
///   （`AppModel.runningOf`，唯一真值 `_runningSids`）；
/// - [completionUnread]：`AppModel.completionUnreadOf`（派生，不落盘）。
SessionDot sessionDotOf({
  required int pendingCount,
  required bool running,
  required bool completionUnread,
}) {
  if (pendingCount > 0) return SessionDot.warning;
  if (running) return SessionDot.ongoing;
  if (completionUnread) return SessionDot.done;
  return SessionDot.idle;
}
