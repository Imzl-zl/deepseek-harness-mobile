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

/// 工作区 chip 的占位文案。
///
/// **只有这一处定义**：hero 的 chip（`ui/conversation_hero.dart`）与输入栏的门槛
/// （`data/composer_gate.dart` 的 "缺工作区" 那句）读同一个常量 ——
/// 桌面也是同一句（`hero.chooseWorkspace`，`EmptyHero.tsx:55-58`），分两处写就会漂。
const String kWorkspacePlaceholder = '选择工作区';

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
    this.createdAt = '',
  });

  final String workspaceId;

  /// 用户可见的名字 —— **分组头就是它**（Web 的侧栏同样用它）。
  final String title;

  /// 规范化的宿主目录。
  final String path;

  /// 归属这个工作区的会话（**手机见的 sid**）。
  final List<String> sessionIds;

  /// 工作区**创建时刻**（ISO 字符串，电脑侧原样给的）。
  ///
  /// 只在 [newSessionWorkspaceId] 里用一次：DSH 的 `recentWorkspace`
  /// （`packages/client/ui-workspace/src/client/navigation.ts:553-572`）对
  /// **没有任何会话**的工作区拿 `Date.parse(createdAt)` 当它的"最近时刻"。
  /// 空字符串 = 电脑侧没给（那时按"永远最旧"处理，不猜一个时间）。
  final String createdAt;
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

/// 新建会话该落在哪个工作区（`null` = 这台电脑一个工作区都没有）。
///
/// ## 链逐条照 DSH 的 `startSession`
///
/// `packages/client/ui-workspace/src/client/navigation.ts:320-334`：
/// `显式给的 ?? 当前会话所在工作区 ?? 最近工作区`。
/// "最近"是 `recentWorkspace`（同文件 `:553-572`）：每个工作区里**会话的最大
/// `updatedAt`**，取最大的那个；并列时按宿主给的行序（先出现的赢）。
///
/// **为什么必须有这一条**：`session.create` 不带 `workspaceId` 时，宿主只按
/// `defaultCwd` 建会话、**不把它记进任何工作区的账本**
/// （`packages/api/session-controller/src/commands.ts:116-148`：只有给了
/// `workspaceId` 才 `workspace.attachSession`）。而手机侧的会话行没有
/// `workspaceId`，分组只能读 `workspace.list` 的 `sessionIds` ——
/// 于是不带 `workspaceId` 建的会话在抽屉里**永远落在「未分组」**。
///
/// ## 空工作区靠 `createdAt` 参与比较（2026-10-22 起对齐）
///
/// DSH 对**没有任何会话**的工作区用 `Date.parse(workspace.createdAt)` 当它的
/// "最近时刻"（`packages/client/ui-workspace/src/client/navigation.ts:565`），
/// 所以"刚建的空工作区"能赢过"很久没动过的老工作区"。
/// 手机侧以前没有这个字段（连接器只转四个字段），只能把"没有会话"记成 `-1` ——
/// 那是**已记过的偏离**；现在 `workspace.list` 带 `createdAt` 了，这一层照 DSH 比。
///
/// `createdAt` 是空串（电脑侧没给 / 老连接器）时仍然按 `-1` 处理 —— **不猜一个时间**。
String? newSessionWorkspaceId({
  String? explicit,
  String? currentWorkspaceId,
  required List<WorkspaceGroup> groups,
  required int Function(String sid) updatedAtOf,
}) {
  if (explicit != null && explicit.isNotEmpty) return explicit;
  if (currentWorkspaceId != null && currentWorkspaceId.isNotEmpty) {
    return currentWorkspaceId;
  }
  String? best;
  var bestAt = -1;
  for (final group in groups) {
    // 有会话 ⇒ 取会话里最大的 `updatedAt`；没有会话 ⇒ 取工作区自己的 `createdAt`。
    var latest = group.sessionIds.isEmpty ? _parseIso(group.createdAt) : -1;
    for (final sid in group.sessionIds) {
      final at = updatedAtOf(sid);
      if (at > latest) latest = at;
    }
    if (best == null || latest > bestAt) {
      best = group.workspaceId;
      bestAt = latest;
    }
  }
  return best;
}

/// ISO 时间串 → 毫秒 epoch；解析不了回 `-1`（**不知道就是最旧**，不猜）。
int _parseIso(String iso) {
  if (iso.isEmpty) return -1;
  return DateTime.tryParse(iso)?.millisecondsSinceEpoch ?? -1;
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

/// 每个工作区**默认显示**多少条非 blank 会话。
///
/// 照桌面 `SESSION_WATERMARK_BASE = 5`
/// （`packages/client/ui-workspace/src/client/rows/WorkspaceBrowser.tsx:55`）：
/// 多出来的收进那一行「展开其余 {n} 个会话」（`locales.ts:34`，用在 `:665`）。
const int kSessionWatermarkBase = 5;

/// 自动抬高的上限（桌面 `SESSION_WATERMARK_AUTO_MAX = 50`，同文件 `:57`）。
///
/// 桌面把"在跑 / 有子在跑 / 等你答 / 有未读 / 当前"这些会话排除在裁剪之外，
/// 抬高到刚好覆盖它们；上限保证一个堆满运行中会话的组不会把整列撑爆。
const int kSessionWatermarkAutoMax = 50;

/// 按 watermark 裁一组会话。**纯函数**，判据逐条照桌面 `watermarkRows`
/// （`WorkspaceBrowser.tsx:60-70`）：
///
/// - **blank 行恒显示**，且**不占**名额（桌面 `if (session.blank) return true`）；
/// - 其余按顺序计数，超过 watermark 的进 `hiddenCount`。
///
/// [mustShow] 对应桌面的 [requiredWatermark]：里面出现的会话（在跑 / 有子在跑 /
/// 有待处理 / 当前）**必须可见**，于是把 watermark 抬到刚好覆盖它（不超过
/// [kSessionWatermarkAutoMax]）。
({List<String> rows, int hiddenCount}) watermarkRowsOf(
  List<String> sessionIds, {
  bool Function(String sid)? isBlank,
  Set<String> mustShow = const <String>{},
  int watermark = kSessionWatermarkBase,
}) {
  final blank = isBlank ?? (String _) => false;
  var effective = watermark;
  var counted = 0;
  for (final sid in sessionIds) {
    if (blank(sid)) continue;
    counted += 1;
    if (!mustShow.contains(sid)) continue;
    final wanted = counted <= kSessionWatermarkAutoMax
        ? counted
        : kSessionWatermarkAutoMax;
    if (wanted > effective) effective = wanted;
  }
  final rows = <String>[];
  var seen = 0;
  for (final sid in sessionIds) {
    if (blank(sid)) {
      rows.add(sid);
      continue;
    }
    seen += 1;
    if (seen <= effective) rows.add(sid);
  }
  return (rows: rows, hiddenCount: sessionIds.length - rows.length);
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

/// 拖动落下时该发给 Host 的锚点（`beforeSid`）。
///
/// [targetSid] 是被落上的那一行，[after] 表示落在它的**下半**（= 插到它后面）。
///
/// 返回 `null` = **不该发请求**：拖到自己身上 / 跨置顶分区 / 位置没变 /
/// 找不到会话。跨分区那条与 DSH Web 的拖动门禁同一条
/// （`WorkspaceBrowser.tsx:593-596` 的 `drag.pinned === node.pinned`）——
/// 置顶行只能在置顶块内挪，普通行不能越过置顶块。
///
/// 与 [moveAnchorInDisplayOrder] 的区别：那个是"移一位"，这个是"拖到任意一行"。
/// 两者共用同一条分区门禁与同一种返回形状，调用方不必分辨。
({String? beforeSid})? dropAnchorInDisplayOrder({
  required List<String> displayOrder,
  required String sid,
  required String targetSid,
  required bool after,
  Set<String> pinnedSessionIds = const {},
}) {
  if (sid == targetSid) return null;
  final from = displayOrder.indexOf(sid);
  final targetIndex = displayOrder.indexOf(targetSid);
  if (from < 0 || targetIndex < 0) return null;
  if (pinnedSessionIds.contains(sid) != pinnedSessionIds.contains(targetSid)) {
    return null;
  }
  // 先把自己摘出去再算插入点：不摘的话"落点在原位置"会算成移动一位。
  final rest = [
    for (final id in displayOrder)
      if (id != sid) id,
  ];
  final at = rest.indexOf(targetSid) + (after ? 1 : 0);
  final next = [...rest]..insert(at, sid);
  // 顺序没变 ⇒ 不发请求（重发一条"原地重排"只会让 UI 闪一下）。
  var same = true;
  for (var i = 0; i < next.length; i += 1) {
    if (next[i] != displayOrder[i]) {
      same = false;
      break;
    }
  }
  if (same) return null;
  return (beforeSid: at >= rest.length ? null : rest[at]);
}
