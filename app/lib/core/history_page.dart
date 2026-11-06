/// **一页历史解出来之后的样子**：连接层只认这个形状，不认识线上字段。
///
/// ## 为什么单独一个文件
///
/// `page()` 要做三件**只有它才能做**的事：记住 `hasMore`、把"太大、要单独补取"的
/// 标记逐条 `await refetch`、再把结果按 `seq` 归位（`SessionPage.events` 承诺升序）。
/// 而"应答长什么样、判别联合是 `record` 还是 `refetch`"属于线上格式，只有 `wire/` 能断言。
///
/// 两半各守一边，中间只开 [HistoryReader] 这一个端口：`core/` 因此**不 import `wire/`**，
/// 而补取与排序仍然留在需要 `SyncClient` 状态的这一层（挪去 wire 就得把连接层状态
/// 一起搬过去）。取舍见 `.agents/notes/implemented/2026-11-06-p1-dependency-inversion.md`。
library;

import 'sync_client.dart' show SessionEvent, SyncClient;

/// 一页里的一项。
sealed class HistoryPageItem {
  const HistoryPageItem();
}

/// 一条可直接使用的记录（已经解成事件）。
final class HistoryRecordItem extends HistoryPageItem {
  const HistoryRecordItem(this.event);

  final SessionEvent event;
}

/// 一条"太大、要单独补取"的标记：带它的 `seq`，由连接层 `await refetch`。
///
/// **跳过它等于在会话里留一个静默的洞**（2026-10-22 之前就是这样：>1 MiB 的条目
/// 在手机上一个都看不到，而界面不报错、也不缺页）。
final class HistoryRefetchItem extends HistoryPageItem {
  const HistoryRefetchItem(this.seq);

  final int seq;
}

/// `session.page` 的一页。
class HistoryPage {
  const HistoryPage({required this.items, required this.hasMore});

  final List<HistoryPageItem> items;

  /// 还有没有更早的一页。**每一页都带**（连接层据此记住水位方向）。
  final bool hasMore;
}

/// 读 `session.page` / `session.refetch`：**声明在这里、实现在 `wire/rpc/session_page.dart`**。
///
/// 两个方法都用 `null` 表示"读不出来"，而且**报缺陷的动作在实现里**
/// （`wire/reading.dart` 的 `WireDiagnostics`）—— 连接层只负责把它折成
/// `SessionPage.failure`（"翻页失败"必须让用户看得见：只计数不回报等于"上滑没反应"）。
abstract interface class HistoryReader {
  /// 取 `sid` 在 `beforeSeq` 之前的一页。
  Future<HistoryPage?> loadPage(
    SyncClient client, {
    required String sid,
    required int beforeSeq,
    required int maxMessages,
    required int minMessages,
    required int minTurns,
  });

  /// 补取一条被标记替代的大条目。
  Future<SessionEvent?> loadRefetched(
    SyncClient client, {
    required String sid,
    required int seq,
  });
}
