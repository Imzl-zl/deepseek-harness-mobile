/// 一个工作区（`workspace.list` 的行，会话列表按它分组）。
///
/// 形状与 DSH 的 `WorkspaceView` 逐字一致
/// （`packages/api/workspace-controller/src/types.ts:18-30`），
/// 只有 `sessionIds` 被连接器换成了**手机见的 sid**。
library;

/// 路径的最后一段（显示用）。**逐字移植 DSH 的 `workspaceTitleOf`**
/// （`packages/util/workspace-path/src/index.ts:58-62`）：去掉尾部所有分隔符，
/// 再从最后一个 `/` 或 `\` 之后取。
///
/// 边界照抄、不改：只有**整条都是分隔符**的路径（`'/'`、`'\'`、空串）回空串；
/// `'D:\'` 去掉尾部分隔符后还剩 `'D:'`，所以它回 `'D:'`
/// （DSH 的文档注释说的 "separator-only" 指的是前者 —— 我按语义推时写错过一次，
/// 期望值是把它原样跑一遍拿到的）。
///
/// 为什么抄这一份而不是 `p.split(...)`：分隔符**两种都要认** ——
/// 手机连的电脑可能是 Windows，路径里就是 `\`。
String workspaceTitleOf(String path) {
  var end = path.length;
  while (end > 0 && (path[end - 1] == '/' || path[end - 1] == '\\')) {
    end -= 1;
  }
  final trimmed = path.substring(0, end);
  final cut = trimmed.lastIndexOf('/');
  final cutBack = trimmed.lastIndexOf('\\');
  final separator = cut > cutBack ? cut : cutBack;
  return trimmed.substring(separator + 1);
}

/// 工作区 chip 的标签（`null` = 占位「选择工作区」）。
///
/// **链逐条照 DSH 的 `ConversationContent.tsx:89-108`**，注释里的五级也照抄：
/// 1. 刚选过的工作区（`pendingTitle`）→ 它的标题；
/// 2. 冷启动、还没有会话 → 占位（调用方根本不显示 chip，所以这里不建模）；
/// 3. 这个 blank 会话的工作区在清单里 → 它的标题；
/// 4. 清单**还没到** → 用 `cwd` 的目录名顶一下，免得刷新时标题闪一下（空 `cwd` → 占位）；
/// 5. 清单**到了但没有归属**（比如已从侧栏删掉）→ 占位，
///    **绝不拿已删目录的名字通过 `cwd` 顶上**。
///
/// "清单到了没有"在这里就是 `workspacesReady`（手机侧 = `workspace.list` 拿到过
/// 一份非空清单）。第 5 条是这条链里唯一有安全性的一条：一个被删掉的工作区目录
/// 还在会话的 `cwd` 里躺着，用它当标题会让用户以为它还活着。
String? workspaceChipLabel({
  String? pendingTitle,
  required bool workspacesReady,
  String? sessionWorkspaceTitle,
  String? cwd,
}) {
  if (pendingTitle != null && pendingTitle.isNotEmpty) return pendingTitle;
  if (sessionWorkspaceTitle != null && sessionWorkspaceTitle.isNotEmpty) {
    return sessionWorkspaceTitle;
  }
  if (workspacesReady) return null;
  if (cwd == null || cwd.isEmpty) return null;
  final base = workspaceTitleOf(cwd);
  return base.isNotEmpty ? base : cwd;
}

/// 工作区分组。
class WorkspaceGroup {
  const WorkspaceGroup({
    required this.workspaceId,
    required this.title,
    required this.path,
    required this.sessionIds,
  });

  final String workspaceId;

  /// 用户可见的名字 —— **分组头就是它**（Web 的侧栏同样用它）。
  final String title;

  /// 规范化的宿主目录。
  final String path;

  /// 归属这个工作区的会话（**手机见的 sid**）。
  final List<String> sessionIds;
}

/// 一桶:分组标签 + 属于它的 sid。
typedef WorkspaceBucket = ({String label, List<String> sessionIds});

/// 某个会话归属的工作区；`null` = 这份清单里没有它（清单为空时也回 `null`）。
///
/// 判据是 `WorkspaceView.sessionIds`（不是 `cwd`）—— 手机侧的会话行里
/// **没有** `workspaceId`（契约 §5.7 的 `workspace.list` 那一行），
/// 所以这是唯一的归属来源。
WorkspaceGroup? workspaceGroupOf(String sid, List<WorkspaceGroup> groups) {
  for (final group in groups) {
    if (group.sessionIds.contains(sid)) return group;
  }
  return null;
}

/// 一个会话在列表里**可不可见**。
///
/// **规则逐条照 DSH Web 的 `sessionVisible`**
/// （`packages/client/ui-workspace/src/client/tree.ts:238-255`）:
/// 1. `origin === 'subagent'` 的**不列**（子智能体的子会话不是用户的历史条目，
///    Web 同样不列；2026-10-15 真机对比:Web 的 anatomy-test 3 条,手机 4 条,
///    多的那条就是子智能体会话）;
/// 2. `blank`（从没被 agent 跑过）且**不是当前会话**的**不列**;
/// 3. 已归档的默认不列 —— 照 Web 的默认过滤档(`ArchivedFilter === 'default'`)
///    的 `case 'default': return !archived.has(session.id)`
///    (`tree.ts:247-248`;归档集来自 `workspace.list` 的 `archivedSessionIds`)。
///    **归档不是删除**:手机上它们在「归档」列表里,取消归档就回到原位
///    (Web 的原注释:`archived sessions … their accounting slots remain either way
///    so unarchiving restores position`,`tree.ts:234-236`)。
///
/// 连接器一直在发 `subagent` / `blank` 两个标志（`connector/src/dsh/sessions.ts`），
/// 归档集则由 `workspace.list` 给（`archivedSessionIds`，同样过别名）。
bool sessionVisible({
  required bool subagent,
  required bool blank,
  required bool isCurrent,
  required bool archived,
}) {
  if (subagent) return false;
  if (archived) return false;
  if (blank && !isCurrent) return false;
  return true;
}

/// 把会话按工作区分桶。**纯函数**——分组规则只有这一份,抽屉与内联列表都用它。
///
/// 规则:
/// 1. **顺序照 groups**（电脑侧给的行序即偏好），不为排序自己发明一套；
/// 2. 一个会话**只进一个桶**（第一次被认领就定），不会在两个工作区里出现两遍；
/// 3. 不在任何工作区里的会话进「**未分组**」—— 如实兜底,不丢；
/// 4. `groups` 为空（拿不到工作区清单）时返回单个「会话」桶 —— **不分组**，
///    而不是按 `cwd` 猜一个分组（`cwd` 与工作区不是一对一,猜错比不分组更难查）。
List<WorkspaceBucket> bucketSessionsByWorkspace(
  List<String> sessionIds,
  List<WorkspaceGroup> groups,
) {
  if (groups.isEmpty) {
    return [
      if (sessionIds.isNotEmpty) (label: '会话', sessionIds: [...sessionIds]),
    ];
  }
  final wanted = sessionIds.toSet();
  final claimed = <String>{};
  final out = <WorkspaceBucket>[];
  for (final group in groups) {
    // **已认领的再报也要排除**:同一个 sid 被两个工作区同时报到时(电脑侧数据
    // 不一致),第一次认领就定 —— 否则同一个会话在两个项目下各出现一遍。
    final ids = group.sessionIds
        .where((sid) => wanted.contains(sid) && !claimed.contains(sid))
        .toList();
    claimed.addAll(ids);
    if (ids.isNotEmpty) out.add((label: group.title, sessionIds: ids));
  }
  final orphans = sessionIds.where((sid) => !claimed.contains(sid)).toList();
  if (orphans.isNotEmpty) out.add((label: '未分组', sessionIds: orphans));
  return out;
}
