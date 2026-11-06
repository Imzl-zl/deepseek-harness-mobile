/// 「读电脑侧的东西」的能力口：**端口声明在这里，实现在 `wire/`**。
///
/// ## 形状：能力是**一个对象**，客户端只是"拿得到它"
///
/// ```text
/// AppModel / HostCatalogs ──> client.hostRpc（1 个 getter）──> WireHostRpc ──> wire 的 loadXxx
/// ```
///
/// 不把九个方法塞进 `SyncClient`：它是全仓二十多个替身 `implements` 的端口，加一个抽象方法
/// 就得逐处补空实现，而它们只测状态与投影、不关心"读哪台电脑的哪张目录"
/// （`core/sync_client.dart` 的 `LinkControl` 写过同一条理由）。
///
/// 也**不**让客户端自己去实现这九个方法：`LinkControl` 的活是客户端干的（断链），
/// `HostRpc` 的活不是（在 `wire/` 里解码）。曾经那样做过一版，结果是为了"转发"再造一个
/// `ForwardingHostRpc` 基类 —— 一层多余的中转，加一个方法要改四处。
/// 现在客户端只证明"我这一条连接上有一个 `HostRpc`"（[HostRpcHolder] 的一个 getter），
/// 请求由 `HostRpc` 自己带着跑（它在构造时就拿到了那条连接）。
///
/// Note: 为什么这么定（含被换掉的那一版）见
/// `.agents/notes/implemented/2026-11-06-p1b-hostrpc-holder.md`；
/// 分批见 `.agents/notes/proposed/2026-11-06-p1b-host-rpc-port.md`。
library;

import '../model/agent_preset.dart' show AgentPresetRoster;
import '../model/changes.dart' show ChangesSummary;
import '../model/file_diff.dart' show FileDiff;
import '../model/model_catalog.dart' show ModelCatalog;
import '../model/permission.dart' show PermissionCatalog;
import '../model/workspace_files.dart' show FileListing, FilePage;
import 'plugin_inventory.dart';
import 'repo_info.dart';
import 'session_list_page.dart';
import 'session_projections.dart';
import 'setting_section.dart';
import 'snapshot_digest.dart';
import 'sync_client.dart';
import 'workspace_snapshot.dart';

/// 读电脑侧的只读快照与目录（`data/` 认识的那一面，不认识线上形状）。
///
/// 失败一律走"`null` 正文 + `WireDiagnostics` 计一次数"（诊断照旧由 `wire/` 那层报，
/// 它正是知道形状的那一处）；三态（正文 / 没变 / 读不出）由 [SnapshotReply] 表达。
///
/// 实现自己持有那条连接（`WireHostRpc(client)`），所以方法**不再收 `client`** ——
/// 每个调用点都传同一个对象只是个需要解释的参数。
abstract interface class HostRpc {
  /// 读一个会话的投影包（`session.projections`，契约 §5.7）。
  ///
  /// 返回 `notModified` 时调用方**什么都不做**（不清数据、不报错、不通知）；
  /// 正文 `null` 才是"这次读不出来" —— 两者在界面上是相反的两件事，
  /// 压成同一档会让摘要命中时被当成失败（目录进 error 态并落一条错误）。
  /// 带内容摘要：键含 `sid`，不同会话的投影包是两个包。
  Future<SnapshotReply<SessionProjections?>> projections({required String sid});

  /// 要一页会话行（`session.list`，契约 §5.7）。
  ///
  /// [limit] / [offset] 都可选：分页后**同方法不同参数是两个包**（摘要键含它们），
  /// 不传就是整表。带摘要 —— `notModified` 时调用方什么都不做。
  Future<SnapshotReply<SessionListPage>> sessionRows({int? limit, int? offset});

  // ---- 目录族（设置分区 / 权限目录 / 模型目录 / Agent 预设 / 工作区 / 仓库 / 插件）----

  /// 读若干命名空间的设置快照（`settings.describe`）。
  ///
  /// 一个 section 认不出就跳过那一条（少一行设置优于整个设置页报错）。
  Future<SnapshotReply<List<SettingSection>?>> settings({
    required List<String> namespaces,
  });

  /// 读模型目录（`session.modelCatalog`）。`null` = 电脑侧明说"拿不到目录"。
  Future<SnapshotReply<ModelCatalog?>> modelCatalog();

  /// 读权限预设目录（`permission.catalog`）。`null` = 电脑侧明说"没有目录"。
  Future<SnapshotReply<PermissionCatalog?>> permissionCatalog();

  /// 读 Agent 预设目录（`agentPresets.list`）。
  Future<SnapshotReply<AgentPresetRoster>> agentPresets();

  /// 读工作区分组与两列 id（`workspace.list`）。
  Future<SnapshotReply<WorkspaceSnapshot?>> workspaces();

  /// 读 `repo.info`（版本 / 能力位）。
  Future<SnapshotReply<RepoInfo?>> repoInfo();

  /// 读插件清单与包清单（`plugin.list` + `plugin.listBundles`，两发并发）。
  ///
  /// **没有摘要三态**：两侧都读不出才回 `null`，一侧坏了就那一侧空表
  /// （与 `loadPluginInventory` 逐字同一条判据，那一层不在端口里复制）。
  Future<PluginInventory?> plugins();

  // ---- 预览族（文件预览 / 目录列举 / 改动清单）----
  //
  // 四个方法都**没有摘要三态**（与对应的 `loadXxx` 一样回可空值）：读不出就是 `null`，
  // 计数与出声在 `wire/` 那一层（`valueOrReport`）。

  /// 列一个目录（`file.list`；[path] 空串 = 工作区根）。
  Future<FileListing?> fileListing({required String sid, required String path});

  /// 读一页文本（`file.read`；[offset] / [limit] 缺省用宿主的页默认）。
  Future<FilePage?> filePage({
    required String sid,
    required String path,
    int? offset,
    int? limit,
  });

  /// 读一条改动记录（`file.changes`；[seq] 是**事件序号**，不是路径）。
  Future<ChangesSummary?> changesSummary({
    required String sid,
    required int seq,
  });

  /// 读一个改动文件的逐行比对（`file.diff`；[seq] + [index] 是宿主只认的坐标）。
  Future<FileDiff?> fileDiff({
    required String sid,
    required int seq,
    required int index,
  });
}

/// 「我这一条连接上有一个 `HostRpc`」—— 客户端兼作这个，**只多一个 getter**。
///
/// 单独一个 1 成员接口而不是让客户端实现 [HostRpc] 的九个方法：见文件头。
abstract interface class HostRpcHolder {
  /// 这条连接的读能力（生产是 `WireHostRpc`，构造时拿到同一条连接）。
  HostRpc get hostRpc;
}

/// 取一个客户端的 `HostRpc`；没有就**抛出**。
///
/// 为什么抛而不是回 `null`：缺能力是**装配错误**（装配点漏了
/// `SyncClientDeps.hostRpc`，或测试替身没接端口），不是"这台电脑读不出东西"。
/// 静默降级会让两者在界面上一模一样（只读面全空），而它们该由不同的人修。
///
/// 判据只写在这一处：`AppModel` 与 `HostCatalogs` 都调它（缺能力时的错误文案同一条）。
HostRpc hostRpcOf(SyncClient client) {
  if (client is HostRpcHolder) return (client as HostRpcHolder).hostRpc;
  throw StateError(
    '${client.runtimeType} 没有 HostRpc 能力：读不了电脑侧的只读面。'
    '装配点要给 SyncClientDeps.hostRpc（生产是 WireHostRpc.new），'
    '测试替身要 implements HostRpcHolder。',
  );
}
