/// 「读电脑侧的东西」的能力口：**端口声明在这里，实现在 `wire/`**。
///
/// ## 为什么不是 `SyncClient` 上的成员
///
/// `SyncClient` 是全仓二十多个替身 `implements` 的端口 —— 往它上面加一个抽象方法，
/// 就得逐处补空实现，而它们只测状态与投影、根本不关心"读哪台电脑的哪张目录"。
/// `core/sync_client.dart` 的 `LinkControl` 已经把这条理由写过一次，这里是同一个手法：
/// **小接口 + `is` 判定**（`AppModel` 拿 `client is HostRpc` 取它）。
///
/// ## 为什么方法上还要收一个 `SyncClient`
///
/// 端口照抄 `wire/rpc/*.dart` 里 `loadXxx(client, …)` 的形状：发请求需要它。
/// 能力本身是**跟着客户端走的**（连接层 `implements HostRpc`，工厂 `hostRpc` 收到
/// 的就是那条连接），所以生产里传进来的那个永远与能力所属的连接是同一个对象 ——
/// 这不是"两处水位"，只是形状一致。
///
/// ## 一个方法族一批
///
/// 会话族（本轮）→ 目录族 → 预览族 → 收尾，见
/// `.agents/notes/proposed/2026-11-06-p1b-host-rpc-port.md` 的「落地顺序」；
/// 会话族落地的代价与边界见
/// `.agents/notes/implemented/2026-11-06-p1b-batch1-session-family.md`。
library;

import '../model/agent_preset.dart' show AgentPresetRoster;
import '../model/model_catalog.dart' show ModelCatalog;
import '../model/permission.dart' show PermissionCatalog;
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
abstract interface class HostRpc {
  /// 读一个会话的投影包（`session.projections`，契约 §5.7）。
  ///
  /// 返回 `notModified` 时调用方**什么都不做**（不清数据、不报错、不通知）；
  /// 正文 `null` 才是"这次读不出来" —— 两者在界面上是相反的两件事，
  /// 压成同一档会让摘要命中时被当成失败（目录进 error 态并落一条错误）。
  /// 带内容摘要：键含 `sid`，不同会话的投影包是两个包。
  Future<SnapshotReply<SessionProjections?>> projections(
    SyncClient client, {
    required String sid,
  });

  /// 要一页会话行（`session.list`，契约 §5.7）。
  ///
  /// [limit] / [offset] 都可选：分页后**同方法不同参数是两个包**（摘要键含它们），
  /// 不传就是整表。带摘要 —— `notModified` 时调用方什么都不做。
  Future<SnapshotReply<SessionListPage>> sessionRows(
    SyncClient client, {
    int? limit,
    int? offset,
  });

  // ---- 目录族（设置分区 / 权限目录 / 模型目录 / Agent 预设 / 工作区 / 仓库 / 插件）----

  /// 读若干命名空间的设置快照（`settings.describe`）。
  ///
  /// 一个 section 认不出就跳过那一条（少一行设置优于整个设置页报错）。
  Future<SnapshotReply<List<SettingSection>?>> settings(
    SyncClient client, {
    required List<String> namespaces,
  });

  /// 读模型目录（`session.modelCatalog`）。`null` = 电脑侧明说"拿不到目录"。
  Future<SnapshotReply<ModelCatalog?>> modelCatalog(SyncClient client);

  /// 读权限预设目录（`permission.catalog`）。`null` = 电脑侧明说"没有目录"。
  Future<SnapshotReply<PermissionCatalog?>> permissionCatalog(
    SyncClient client,
  );

  /// 读 Agent 预设目录（`agentPresets.list`）。
  Future<SnapshotReply<AgentPresetRoster>> agentPresets(SyncClient client);

  /// 读工作区分组与两列 id（`workspace.list`）。
  Future<SnapshotReply<WorkspaceSnapshot?>> workspaces(SyncClient client);

  /// 读 `repo.info`（版本 / 能力位）。
  Future<SnapshotReply<RepoInfo?>> repoInfo(SyncClient client);

  /// 读插件清单与包清单（`plugin.list` + `plugin.listBundles`，两发并发）。
  ///
  /// **没有摘要三态**：两侧都读不出才回 `null`，一侧坏了就那一侧空表
  /// （与 `loadPluginInventory` 逐字同一条判据，那一层不在端口里复制）。
  Future<PluginInventory?> plugins(SyncClient client);
}

/// 取一个客户端的 `HostRpc` 能力；没有就**抛出**。
///
/// 为什么抛而不是回 `null`：缺能力是**装配错误**（装配点漏了
/// `SyncClientDeps.hostRpc`，或测试替身没接端口），不是"这台电脑读不出东西"。
/// 静默降级会让两者在界面上一模一样（只读面全空），而它们该由不同的人修。
///
/// 判据只写在这一处：`AppModel` 与 `HostCatalogs` 都调它（缺能力时的错误文案同一条）。
HostRpc hostRpcOf(SyncClient client) {
  if (client is HostRpc) return client as HostRpc;
  throw StateError(
    '${client.runtimeType} 没有 HostRpc 能力：读不了电脑侧的只读面。'
    '装配点要给 SyncClientDeps.hostRpc（生产是 WireHostRpc.new），'
    '测试替身要 implements HostRpc。',
  );
}

/// 「把能力转发给另一个 `HostRpc`」的**共用实现**。
///
/// 连接层（`core/sync_client_impl.dart`）与测试替身（`test/fake_sync_client.dart`）都
/// 是"能力在我身上、活儿在 `wire/` 里"的同一形状：每个方法一行 `=> target.xxx(…)`。
/// 九个方法各写三遍就是二十七处样板 —— 加一个方法要改四处，而"改漏一处"的表现是
/// 编译错误（还算好）或某个替身悄悄不转发（不好）。所以收成一处：实现方只给 [target]。
///
/// **真正的实现**是 `wire/host_rpc.dart`（它直接 `implements HostRpc`）——
/// 这一层不转发给它自己，避免"能力的实现只是转发给能力"的空转。
abstract class ForwardingHostRpc implements HostRpc {
  const ForwardingHostRpc();

  /// 真正干活的那一个（生产是 `_deps.hostRpc(this)` 造出来的 `WireHostRpc`）。
  HostRpc get target;

  @override
  Future<SnapshotReply<SessionProjections?>> projections(
    SyncClient client, {
    required String sid,
  }) => target.projections(client, sid: sid);

  @override
  Future<SnapshotReply<SessionListPage>> sessionRows(
    SyncClient client, {
    int? limit,
    int? offset,
  }) => target.sessionRows(client, limit: limit, offset: offset);

  @override
  Future<SnapshotReply<List<SettingSection>?>> settings(
    SyncClient client, {
    required List<String> namespaces,
  }) => target.settings(client, namespaces: namespaces);

  @override
  Future<SnapshotReply<ModelCatalog?>> modelCatalog(SyncClient client) =>
      target.modelCatalog(client);

  @override
  Future<SnapshotReply<PermissionCatalog?>> permissionCatalog(
    SyncClient client,
  ) => target.permissionCatalog(client);

  @override
  Future<SnapshotReply<AgentPresetRoster>> agentPresets(SyncClient client) =>
      target.agentPresets(client);

  @override
  Future<SnapshotReply<WorkspaceSnapshot?>> workspaces(SyncClient client) =>
      target.workspaces(client);

  @override
  Future<SnapshotReply<RepoInfo?>> repoInfo(SyncClient client) =>
      target.repoInfo(client);

  @override
  Future<PluginInventory?> plugins(SyncClient client) => target.plugins(client);
}
