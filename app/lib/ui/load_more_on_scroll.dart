/// 会话列表「滚到快底 ⇒ 要下一页」的接线片（两个表面共用：首页内联列表 + 抽屉）。
///
/// ## 判据不在这里
///
/// "到没到历史那一端"的唯一判据是 `ui/load_older_trigger.dart` 的 [shouldLoadOlder]
/// —— 对话流的历史翻页用的也是它。这里**只做两件这一层才有的事**：
///
/// 1. **只认 `ScrollUpdateNotification`**：`ListView` 会为即将进入视口的内容预构建，
///    用"末尾那一行被构建"当触发点，在列表还短的时候首帧就会把后面几页一起吞下来
///    —— 等于把分页又变回整表。布局变化产生的是 `ScrollMetricsNotification`，不算。
/// 2. **不吞通知**：列表 / 滚动条还有别的监听器。
///
/// **不自己防重入**：`AppModel.loadMoreSessionRows` 有在飞闸（`_loadingMore`），
/// 这里再放一层闸就是同一个判据的两处表达。
///
/// ## 与"末尾那一行按钮"的分工
///
/// 自动触发是主路径（数据页的手感：还没到底就已经在拉）。末尾那一行「加载更多会话」
/// 仍然保留：它是"还有更多"的**可见说明**，也是自动触发够不到时（比如阈值内停住）
/// 的手动兜底。
library;

import 'package:flutter/widgets.dart';

import 'load_older_trigger.dart';

/// 包一层：滚到历史那一端就调 [onLoadMore]。
class LoadMoreOnScroll extends StatelessWidget {
  const LoadMoreOnScroll({
    super.key,
    required this.hasMore,
    required this.onLoadMore,
    required this.child,
  });

  final bool hasMore;
  final VoidCallback? onLoadMore;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final callback = onLoadMore;
    if (!hasMore || callback == null) return child;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // 会话列表是"最新在最上面"的普通列表，历史那一端在**下方**
        // ⇒ 与倒序列表的"历史端"同一个几何判据（`reverse: true` 那一支）。
        if (notification is ScrollUpdateNotification &&
            shouldLoadOlder(
              pixels: notification.metrics.pixels,
              maxScrollExtent: notification.metrics.maxScrollExtent,
              hasMore: hasMore,
            )) {
          callback();
        }
        return false;
      },
      child: child,
    );
  }
}
