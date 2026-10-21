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

/// 一桶:分组标签 + 属于它的 sid + 它对应的**工作区 id**。
///
/// `workspaceId` 为 `null` 表示这一组**不是真工作区**（「未分组」兜底桶，
/// 或拿不到工作区清单时的单桶「会话」）。它存在的理由只有一个：
/// `workspace.insertSessionBefore` 要求 `workspaceId`，而这些桶里的会话没有归属
/// —— 在这样的组里上移/下移**必须不可点**，否则点下去只能得到一句失败
/// （`AppModel.moveSession` 会以"会话不属于任何工作区"拒掉）。
/// 判据放在这里，抽屉（长按菜单）与内联列表读同一个值。
typedef WorkspaceBucket = ({
  String label,
  List<String> sessionIds,
  String? workspaceId,
});

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
/// 2. **置顶的排在各自分组的最前**（组内分区，见 `pinnedSessionIds`）；
/// 3. 一个会话**只进一个桶**（第一次被认领就定），不会在两个工作区里出现两遍；
/// 4. 不在任何工作区里的会话进「**未分组**」—— 如实兜底,不丢；
/// 5. `groups` 为空（拿不到工作区清单）时返回单个「会话」桶 —— **不分组**，
///    而不是按 `cwd` 猜一个分组（`cwd` 与工作区不是一对一,猜错比不分组更难查）。
///
/// [pinnedSessionIds] 来自 `workspace.list` 的 `pinnedSessionIds`
/// （registry 全局集合）。分区顺序照 DSH Web 的 `sectionMembers`
/// （`ui-workspace/src/client/tree.ts:273-287`）：**置顶在前，两个分区各自保持
/// 电脑侧给的相对顺序**。不是把置顶项提到整张表的最前 —— 它属于哪个项目仍归哪个项目。
List<WorkspaceBucket> bucketSessionsByWorkspace(
  List<String> sessionIds,
  List<WorkspaceGroup> groups, {
  Set<String> pinnedSessionIds = const {},
}) {
  /// 组内分区：置顶的在前，两边都保持原顺序。
  List<String> partitionPinned(Iterable<String> ids) {
    final all = ids.toList();
    return [
      for (final sid in all)
        if (pinnedSessionIds.contains(sid)) sid,
      for (final sid in all)
        if (!pinnedSessionIds.contains(sid)) sid,
    ];
  }

  if (groups.isEmpty) {
    return [
      if (sessionIds.isNotEmpty)
        // 没有工作区清单 ⇒ 这一组里的会话**没有 workspaceId**（上移/下移不可用）。
        (
          label: '会话',
          sessionIds: partitionPinned(sessionIds),
          workspaceId: null,
        ),
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
    if (ids.isNotEmpty) {
      out.add((
        label: group.title,
        sessionIds: partitionPinned(ids),
        workspaceId: group.workspaceId,
      ));
    }
  }
  final orphans = sessionIds.where((sid) => !claimed.contains(sid)).toList();
  if (orphans.isNotEmpty) {
    // 兜底桶：不属于任何工作区 ⇒ 上移/下移不可用（没有 workspaceId 可发）。
    out.add((
      label: '未分组',
      sessionIds: partitionPinned(orphans),
      workspaceId: null,
    ));
  }
  return out;
}

/// 在**显示顺序**里把 [sid] 移动一位所需的 Host 锚点（`beforeSid`）。
///
/// 返回 `null` = 边界 / 跨置顶分区 / 找不到会话 —— **不动**，调用方不要发请求。
/// 返回 `(beforeSid: null)` 是合法移动：移到末尾（DSH 的 `beforeSessionId?`
/// 缺省即追加，`workspace-controller/src/types.ts:107-112`）。
///
/// [displayOrder] 是该分组**已经分区过**的顺序（置顶在前）。
/// [delta] 只接受 `-1` / `1`。置顶行只在置顶块内移动，普通行不会跨过置顶块 ——
/// 与 DSH Web 的拖动门禁同一条（`WorkspaceBrowser.tsx:593-596`：
/// `drag.pinned === node.pinned`）。
({String? beforeSid})? moveAnchorInDisplayOrder({
  required List<String> displayOrder,
  required String sid,
  required int delta,
  Set<String> pinnedSessionIds = const {},
}) {
  if (delta != -1 && delta != 1) return null;
  final from = displayOrder.indexOf(sid);
  if (from < 0) return null;
  final to = from + delta;
  if (to < 0 || to >= displayOrder.length) return null;
  final pinned = pinnedSessionIds.contains(sid);
  if (pinnedSessionIds.contains(displayOrder[to]) != pinned) return null;
  if (delta < 0) return (beforeSid: displayOrder[to]);
  // 下移：锚点是"目标位的下一行"；没有下一行就是追加到末尾。
  final after = to + 1;
  return (beforeSid: after < displayOrder.length ? displayOrder[after] : null);
}
