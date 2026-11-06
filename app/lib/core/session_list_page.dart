/// 一页会话行（`session.list`）**解好之后的值**。
///
/// ## 为什么在 `core/`
///
/// 端口（`core/host_rpc.dart` 的 `HostRpc`）要能把它交出来，而端口是 `data/` 认的
/// 那一面。行本身是 `model/chat_item.dart` 的 `SessionSummary`（连接器自造的行，
/// 见 `wire/rpc/session.dart` 的文件头）；这里只有"一页 + 还有没有下一段"这一层。
///
/// **线上形状不在这里**：`{sessions: [...], hasMore}` 的拆包、一行坏掉的处置、
/// 可选字段的缺省，全在 `wire/rpc/session.dart` 的 `loadSessionList` / `readSessionList`。
library;

import '../model/chat_item.dart' show SessionSummary;

/// 一页会话行 + "还有没有下一段"（连接器 `hasMore`）。
///
/// 不传 `limit` 就是整表 + `hasMore: false`（`connector/src/handlers.ts` 的
/// `session.list`）：于是"没有再下一页"正好是事实，不需要版本判断。
typedef SessionListPage = ({List<SessionSummary> sessions, bool hasMore});
