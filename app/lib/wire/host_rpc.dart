/// `HostRpc` 的实现：**形状知识仍然只在 `wire/`**（本文件只是把它接到端口上）。
///
/// ## 它做什么、不做什么
///
/// 什么都不加：发请求、带摘要、解码、把形状缺陷报给 `WireDiagnostics` 全在
/// `wire/rpc/*.dart` 的 `loadXxx` 里（`wire/rpc/snapshot.dart` 的 `loadSnapshot`
/// 统一做"三态 + 计数"）。这一层只把端口的方法名对应到那些函数上 ——
/// 两边写两套判据的话，"读不出来要不要计数"迟早有两份答案。
///
/// 它**持有那条连接**（构造时给一次），所以端口的方法不再收 `client`。
/// 装配点把它当工厂给连接层（`hostRpc: WireHostRpc.new`），
/// `core/sync_client_impl.dart` 就因此能在**不 import `wire/`** 的前提下拿到它。
///
/// Note: 为什么不是"客户端自己实现 HostRpc"见
/// `.agents/notes/implemented/2026-11-06-p1b-hostrpc-holder.md`。
library;

import '../core/host_rpc.dart';
import '../core/plugin_inventory.dart';
import '../core/repo_info.dart';
import '../core/session_list_page.dart';
import '../core/setting_section.dart';
import '../core/snapshot_digest.dart';
import '../core/sync_client.dart';
import '../core/workspace_snapshot.dart';
import '../model/agent_preset.dart' show AgentPresetRoster;
import '../model/model_catalog.dart' show ModelCatalog;
import '../model/permission.dart' show PermissionCatalog;
import 'rpc/permission.dart';
import 'rpc/plugin.dart';
import 'rpc/preset.dart';
import 'rpc/projections.dart';
import 'rpc/repo.dart';
import 'rpc/session.dart';
import 'rpc/settings.dart';
import 'rpc/workspace.dart';

/// 端口 `HostRpc` 的唯一实现（会话族 + 目录族）。
///
/// 每个方法一行：**判据全在被它转过去的那个 `loadXxx` 里**（形状、三态、计数）。
final class WireHostRpc implements HostRpc {
  const WireHostRpc(this.client);

  /// 这条连接（工厂 `hostRpc` 收到的那一个）。
  final SyncClient client;

  @override
  Future<SnapshotReply<SessionProjections?>> projections({
    required String sid,
  }) => loadSessionProjections(client, sid: sid);

  @override
  Future<SnapshotReply<SessionListPage>> sessionRows({
    int? limit,
    int? offset,
  }) => loadSessionList(client, limit: limit, offset: offset);

  @override
  Future<SnapshotReply<List<SettingSection>?>> settings({
    required List<String> namespaces,
  }) => loadSettings(client, namespaces: namespaces);

  @override
  Future<SnapshotReply<ModelCatalog?>> modelCatalog() =>
      loadModelCatalog(client);

  @override
  Future<SnapshotReply<PermissionCatalog?>> permissionCatalog() =>
      loadPermissionCatalog(client);

  @override
  Future<SnapshotReply<AgentPresetRoster>> agentPresets() =>
      loadAgentPresets(client);

  @override
  Future<SnapshotReply<WorkspaceSnapshot?>> workspaces() =>
      loadWorkspaceList(client);

  @override
  Future<SnapshotReply<RepoInfo?>> repoInfo() => loadRepoInfo(client);

  @override
  Future<PluginInventory?> plugins() => loadPluginInventory(client);
}
