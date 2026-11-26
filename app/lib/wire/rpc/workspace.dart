/// **工作区面**（`workspace.*`）的唯一入口。
///
/// 七种应答全是"分组 + 两列 id"或"整份顺序/集合"，而**换别名的规则只有一份**
/// （连接器 `handlers.ts:990-991` 的 `aliased`）：`sessionIds` / `archivedSessionIds` /
/// `pinnedSessionIds` 在线上都是手机见的 `sid`。这条边界的判据是"同一份载荷里只换一半
/// 就是 bug" —— 手机拿到一串它不认识的 id，分组 / 归档 / 置顶全对不上。
///
/// ## 形状的出处（`connector/src/handlers.ts`）
///
/// | 方法 | 应答 |
/// |---|---|
/// | `workspace.list` `:993-1014` | `{workspaces: [{workspaceId, title, path, createdAt, sessionIds}], archivedSessionIds, pinnedSessionIds}` |
/// | `workspace.insertSessionBefore` `:1015-1030` | `{sessionIds}`（**该工作区**的新顺序）|
/// | `workspace.insertBefore` `:1035-1047` | `{workspaceIds}`（**整份**工作区顺序；工作区 id 不是别名）|
/// | `workspace.pin` / `unpin` `:1049-1059` | `{pinnedSessionIds}`（置顶**全集**）|
/// | `workspace.archive` / `unarchive` `:1068-1082` | `{archivedSessionIds}`（归档**全集**）|
///
/// **`createdAt` 是 2026-10-25 修的那一处**：端口有（`dsh/workspaces.ts:203`）、手机也读，
/// 中间那层原先漏写了 —— 于是手机上它恒为空串，"空工作区当最旧"那条分支生产里走不到。
/// 金样收的就是这一行。
///
/// ## 失败语义
///
/// - 分组：**一条认不出就丢那一条 + 计数**（少一个分组比整个列表失败轻），
///   走的是 `readObjectList` 的统一入口；"`workspaces` 不是数组"是 [WireBad]。
/// - 集合 / 顺序（"整份真值"）：**认不出就返回 `null`**，由调用方"不动 + 如实报错"——
///   一个有损的落盘会让"哪条是归档的"错位，而症状只是"列表里少了一条"，最难查。
///   空数组**合法**（工作区被搬空了）；但"非空却全是非法项"说明形状变了，也算认不出。
///
/// Note: 布局与批次见 `.agents/notes/implemented/2026-10-25-wire-rpc-layer-layout.md`。
library;

import '../../core/snapshot_digest.dart';
import '../../core/sync_client.dart';
import '../../core/workspace_snapshot.dart';
import '../../model/workspace.dart' show WorkspaceGroup;
import '../fields.dart';
import '../reading.dart';
import 'snapshot.dart';

/// 消费方一次拿齐"三态内核 + 字段内核 + 工作区面解码"。
export '../fields.dart';
export '../reading.dart';

const String _kList = 'workspace.list';
const String _kInsertSessionBefore = 'workspace.insertSessionBefore';
const String _kInsertBefore = 'workspace.insertBefore';
const String _kPin = 'workspace.pin';
const String _kUnpin = 'workspace.unpin';
const String _kArchive = 'workspace.archive';
const String _kUnarchive = 'workspace.unarchive';
const String _kRename = 'workspace.rename';
const String _kDelete = 'workspace.delete';

// 一次解码的**值类型**（分组 + 两列 id）在 `core/workspace_snapshot.dart`
// （端口 `HostRpc` 要能返回它）；下面只剩"怎么从同一份应答里一起解出来"。

// ---------------------------------------------------------------------------
// 发请求（唯一入口）
// ---------------------------------------------------------------------------

/// 读工作区分组与两列 id。
///
/// 读不出来 ⇒ `null` + 计数一次（调用方"留空 = 不分组"，那是如实的降级：
/// 缺 `workspaceController` 的部署本来就没这个方法）。
Future<SnapshotReply<WorkspaceSnapshot?>> loadWorkspaceList(
  SyncClient client,
) => loadSnapshot(client, _kList, const {}, readWorkspaceList);

/// 置顶 / 取消置顶：回**置顶全集**（`null` = 应答认不出，调用方如实报错）。
Future<Set<String>?> workspacePin(
  SyncClient client, {
  required String sid,
  required String requestId,
}) async {
  final result = await client.call<Object?>(_kPin, {
    'sid': sid,
  }, requestId: requestId);
  return valueOrReport(readPinnedSet(result), _kPin);
}

Future<Set<String>?> workspaceUnpin(
  SyncClient client, {
  required String sid,
  required String requestId,
}) async {
  final result = await client.call<Object?>(_kUnpin, {
    'sid': sid,
  }, requestId: requestId);
  return valueOrReport(readPinnedSet(result), _kUnpin);
}

/// 归档 / 取消归档：回**归档全集**。
///
/// `stopActivity` **只在为真时才带这个键**：DSH 判的是 `=== true`，
/// 塞一个 `false` 进去是另一种语义（`connector/src/dsh/workspaces.ts` 的注释）。
Future<Set<String>?> workspaceArchive(
  SyncClient client, {
  required String sid,
  required bool stopActivity,
  required String requestId,
}) async {
  final result = await client.call<Object?>(_kArchive, {
    'sid': sid,
    // ignore: use_null_aware_elements
    if (stopActivity) 'stopActivity': true,
  }, requestId: requestId);
  return valueOrReport(readArchivedSet(result), _kArchive);
}

Future<Set<String>?> workspaceUnarchive(
  SyncClient client, {
  required String sid,
  required String requestId,
}) async {
  final result = await client.call<Object?>(_kUnarchive, {
    'sid': sid,
  }, requestId: requestId);
  return valueOrReport(readArchivedSet(result), _kUnarchive);
}

/// 同工作区内重排会话：回**该工作区**的新顺序。
///
/// `beforeSid` 为 `null` = 追加到末尾（DSH 的 `beforeSessionId?` 缺省语义）；
/// **不给这个键**而不是给空串（空串会被宿主当成一个不存在的锚点）。
Future<List<String>?> workspaceInsertSessionBefore(
  SyncClient client, {
  required String workspaceId,
  required String sid,
  required String? beforeSid,
  required String requestId,
}) async {
  final result = await client.call<Object?>(_kInsertSessionBefore, {
    'workspaceId': workspaceId,
    'sid': sid,
    // ignore: use_null_aware_elements
    if (beforeSid != null) 'beforeSid': beforeSid,
  }, requestId: requestId);
  return valueOrReport(readSessionOrder(result), _kInsertSessionBefore);
}

/// 工作区自己重排：回**整份**工作区顺序（工作区 id 不是别名，原样给）。
Future<List<String>?> workspaceInsertBefore(
  SyncClient client, {
  required String workspaceId,
  required String? beforeWorkspaceId,
  required String requestId,
}) async {
  final result = await client.call<Object?>(_kInsertBefore, {
    'workspaceId': workspaceId,
    // ignore: use_null_aware_elements
    if (beforeWorkspaceId != null) 'beforeWorkspaceId': beforeWorkspaceId,
  }, requestId: requestId);
  return valueOrReport(readWorkspaceOrder(result), _kInsertBefore);
}

/// 改工作区标题：回**改后的那一行**（`null` = 应答认不出）。
///
/// **标题原样发**，不在这里 `trim`：宿主先 `trim()` 再判空
/// （`workspace-controller/src/commands.ts:74-77`），空标题会回
/// `gateway/bad-request`；重名回 `workspace/name-conflict`。两条都在
/// `ERROR_TABLE` 里、原样到手机，这一层再判一次就是两份规则。
Future<WorkspaceGroup?> workspaceRename(
  SyncClient client, {
  required String workspaceId,
  required String title,
  required String requestId,
}) async {
  final result = await client.call<Object?>(_kRename, {
    'workspaceId': workspaceId,
    'title': title,
  }, requestId: requestId);
  return valueOrReport(readRenameWorkspace(result), _kRename);
}

/// 注销一个工作区（**只删注册，目录与会话都留着**）。
///
/// 回 `bool` 而不是 `void`：`null` = 应答认不出（调用方如实报错、不动本地表），
/// `true` = 宿主确认删掉了。宿主只回 `{deleted: true}`，所以除了"没有抛错"
/// 没有别的信息可用 —— 但**认不出**（形状变了）与**已删除**必须能分开，
/// 否则一个坏应答会被当成成功，界面上那一行凭空消失。
Future<bool?> workspaceDelete(
  SyncClient client, {
  required String workspaceId,
  required String requestId,
}) async {
  final result = await client.call<Object?>(_kDelete, {
    'workspaceId': workspaceId,
  }, requestId: requestId);
  if (result is! Map) return _unreadableDelete();
  if (WireFields(result, _kDelete).map['deleted'] != true) {
    return _unreadableDelete();
  }
  return true;
}

/// `workspace.delete` 认不出时的唯一出口：计一次数、交 `null`。
///
/// 走 [valueOrReport] 的同一条纪律（那一条是"计数 + 交付"绑在一起，
/// 见 `reading.dart:17` 的注释）—— 这里没有解码器可传，所以用 [WireBad]
/// 造一个只为了拿同一个出口，不另写一套 `report + return null`。
bool? _unreadableDelete() => valueOrReport(
  const WireBad<bool>('应答不是 {deleted: true}（`workspace.delete`）'),
  _kDelete,
);

// ---------------------------------------------------------------------------
// 纯解码
// ---------------------------------------------------------------------------

/// `workspace.rename` 的应答 → 改后的那一行。
///
/// 形状与 `workspace.list` 的一行**同构**（`connector/src/handlers.ts` 的
/// `workspace.rename` 就是拿同一组键拼的），所以这里直接复用列表行的构造器 ——
/// 两个地方各写一份解析，迟早有一边漏掉 `createdAt`（那种漏写发生过一次，
/// 见 `_kList` 上面的注释）。
WireReading<WorkspaceGroup> readRenameWorkspace(Object? result) {
  if (result is! Map) {
    return const WireBad('应答不是 {workspace}（`workspace.rename`）');
  }
  final fields = WireFields(result, _kRename);
  final row = fields.map['workspace'];
  if (row is! Map) {
    return const WireBad('workspace 认不出（`workspace.rename`）');
  }
  try {
    return WireOk(_groupOf(WireFields(row, _kRename)));
  } on WireFieldError catch (error) {
    return WireBad('workspace 行认不出（`workspace.rename`）：${error.detail}');
  }
}

/// `workspace.list` 的应答 → 分组 + 两列 id。
///
/// 一条分组认不出就**跳过那一条**（少一个分组比整个列表失败轻）；
/// 但 `workspaces` 不是数组、或两列 id 认不出 ⇒ [WireBad]（那是"整份真值"读不出来）。
WireReading<WorkspaceSnapshot> readWorkspaceList(Object? result) {
  if (result is! Map) {
    return const WireBad('应答不是 {workspaces, …}（`workspace.list`）');
  }
  // 分组行走**同一个** `{key: [...]}` 入口：坏一条丢一条 + 计数，
  // 而不是每个面自己写一遍"取 Map → 取 key → 判 List"。
  final rows = readObjectList<WorkspaceGroup>(
    result,
    method: _kList,
    key: 'workspaces',
    build: _groupOf,
  );
  if (rows is WireBad<List<WorkspaceGroup>>) {
    return WireBad(rows.detail);
  }
  if (rows is! WireOk<List<WorkspaceGroup>>) {
    return const WireBad('workspaces 读不出来（`workspace.list`）');
  }

  final fields = WireFields(result, _kList);
  final archived = _idsOf(fields, 'archivedSessionIds');
  if (archived == null) {
    return const WireBad('archivedSessionIds 认不出（`workspace.list`）');
  }
  final pinned = _idsOf(fields, 'pinnedSessionIds');
  if (pinned == null) {
    return const WireBad('pinnedSessionIds 认不出（`workspace.list`）');
  }

  return WireOk(
    WorkspaceSnapshot(
      groups: rows.value,
      archivedSessionIds: archived,
      pinnedSessionIds: pinned,
    ),
  );
}

/// `{pinnedSessionIds}` → 置顶全集。认不出 ⇒ [WireBad]。
WireReading<Set<String>> readPinnedSet(Object? result) =>
    _setReading(result, _kPin, 'pinnedSessionIds');

/// `{archivedSessionIds}` → 归档全集。认不出 ⇒ [WireBad]。
WireReading<Set<String>> readArchivedSet(Object? result) =>
    _setReading(result, _kArchive, 'archivedSessionIds');

/// `{sessionIds}` → 该工作区的新顺序（**空数组合法**：工作区被搬空了）。
WireReading<List<String>> readSessionOrder(Object? result) {
  if (result is! Map) {
    return const WireBad('应答不是 {sessionIds}（`workspace.insertSessionBefore`）');
  }
  final ids = _idsOf(WireFields(result, _kInsertSessionBefore), 'sessionIds');
  if (ids == null) {
    return const WireBad('sessionIds 认不出（`workspace.insertSessionBefore`）');
  }
  return WireOk(ids.toList(growable: false));
}

/// `{workspaceIds}` → 整份工作区顺序。
WireReading<List<String>> readWorkspaceOrder(Object? result) {
  if (result is! Map) {
    return const WireBad('应答不是 {workspaceIds}（`workspace.insertBefore`）');
  }
  final ids = _idsOf(WireFields(result, _kInsertBefore), 'workspaceIds');
  if (ids == null) {
    return const WireBad('workspaceIds 认不出（`workspace.insertBefore`）');
  }
  return WireOk(ids.toList(growable: false));
}

// ---------------------------------------------------------------------------

WireReading<Set<String>> _setReading(
  Object? result,
  String method,
  String key,
) {
  if (result is! Map) return WireBad('应答不是 {$key}（`$method`）');
  final ids = _idsOf(WireFields(result, method), key);
  if (ids == null) return WireBad('$key 认不出（`$method`）');
  return WireOk(ids);
}

/// 一列 sid：必须是数组、只收非空字符串。
///
/// **"非空却全是非法项"算认不出**（返回 `null`）：那说明形状变了，
/// 而落一个空集会静默地把归档/置顶清空。空数组本身**合法**。
Set<String>? _idsOf(WireFields fields, String key) {
  // **不在这里 `report`**：认不出由调用方折成 WireBad 并计一次数。
  // 两处都报会让同一个缺陷记两次（2026-10-26 评审）。
  final raw = fields.map[key];
  if (raw is! List) return null;
  final out = <String>{};
  for (final id in raw) {
    if (id is String && id.isNotEmpty) out.add(id);
  }
  if (raw.isNotEmpty && out.isEmpty) return null;
  return out;
}

/// 一条工作区分组。
///
/// **五个键都是必填**：连接器逐键构造、不 spread（`connector/src/handlers.ts:996-1009`），
/// 而且 `createdAt` 就是"空工作区当最近"那条链的输入（漏过它一次，2026-10-25）。
/// 缺一个就到不了界面 ⇒ 这一条丢掉 + 计数（由 `readObjectList` 记一次）。
WorkspaceGroup _groupOf(WireFields fields) {
  final id = fields.requireNonEmptyString('workspaceId');
  final title = fields.requireNonEmptyString('title');
  final sessionIds = _idsOf(fields, 'sessionIds');
  if (sessionIds == null) {
    throw const WireFieldError('sessionIds 认不出（`workspace.list`）');
  }
  return WorkspaceGroup(
    workspaceId: id,
    title: title,
    path: fields.requireString('path'),
    // `createdAt`（ISO）：手机只拿它比"谁更新"。连接器无条件写它。
    createdAt: fields.requireString('createdAt'),
    sessionIds: sessionIds.toList(growable: false),
  );
}
