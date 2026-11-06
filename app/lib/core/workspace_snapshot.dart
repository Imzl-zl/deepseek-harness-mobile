/// `workspace.list` 的一次解码：分组 + 两列 id（**同一份应答**），**解好之后的值**。
///
/// ## 为什么在 `core/`
///
/// 端口（`core/host_rpc.dart` 的 `HostRpc`）要能把它交出来，而端口是 `data/` 认的那一面。
/// 字段怎么拆、缺键怎么处置，全在 `wire/rpc/workspace.dart`。
///
/// 分成三次解析会让"列表看过一眼、归档/置顶集还是旧的"，所以它们只能一起出。
///
/// Note: 分批见 `.agents/notes/implemented/2026-11-06-p1b-batch2-catalog-family.md`。
library;

import '../model/workspace.dart' show WorkspaceGroup;

/// 工作区分组 + 归档/置顶两列 id。
final class WorkspaceSnapshot {
  const WorkspaceSnapshot({
    required this.groups,
    required this.archivedSessionIds,
    required this.pinnedSessionIds,
  });

  final List<WorkspaceGroup> groups;
  final Set<String> archivedSessionIds;
  final Set<String> pinnedSessionIds;
}
