/// `HostReads` 的实现：**形状知识仍然只在 `wire/`**（本文件只是把它接到端口上）。
///
/// 每个方法一行：判据全在被它转过去的那个 `loadXxx` 里（形状、三态、计数）。
/// 它持有那条连接（构造时给一次），所以端口方法不再收 `client`。
///
/// `rpc/*.dart` 一律加 `as wire` 前缀：`pluginJobStatus` 这类名字在端口与
/// `wire/` 里同名，不带前缀的调用会解析回**本类的方法**（无限递归或"参数不对"）。
///
/// Note: 为什么读写分两个口见 `core/host_rpc.dart` 的文件头；
/// 分批与代价见 `.agents/notes/implemented/2026-11-06-p1b-batch4-read-write-ports.md`。
library;

import '../core/endpoint.dart' show Endpoint;
import '../core/host_rpc.dart';
import '../core/job.dart' show JobRow;
import '../core/plugin_inventory.dart';
import '../core/repo_info.dart';
import '../core/session_list_page.dart';
import '../core/session_projections.dart';
import '../core/setting_section.dart';
import '../core/snapshot_digest.dart';
import '../core/sync_client.dart';
import '../core/workspace_snapshot.dart';
import '../model/agent_preset.dart' show AgentPresetRoster;
import '../model/changes.dart' show ChangesSummary;
import '../model/file_diff.dart' show FileDiff;
import '../model/mention.dart' show AtCandidate;
import '../model/model_catalog.dart' show ModelCatalog;
import '../model/permission.dart' show PermissionCatalog;
import '../model/plugins.dart' show PluginJob;
import '../model/usage_summary.dart' show UsageSummary;
import '../model/workspace_files.dart' show FileListing, FilePage;
import 'rpc/changes.dart' as wire;
import 'rpc/endpoint.dart' as wire;
import 'rpc/file.dart' as wire;
import 'rpc/job.dart' as wire;
import 'rpc/permission.dart' as wire;
import 'rpc/plugin.dart' as wire;
import 'rpc/preset.dart' as wire;
import 'rpc/projections.dart' as wire;
import 'rpc/refs.dart' as wire;
import 'rpc/repo.dart' as wire;
import 'rpc/session.dart' as wire;
import 'rpc/settings.dart' as wire;
import 'rpc/usage.dart' as wire;
import 'rpc/workspace.dart' as wire;

/// 端口 `HostReads` 的唯一实现。
final class WireHostReads implements HostReads {
  const WireHostReads(this.client);

  /// 这条连接（工厂 `hostRpc` 收到的那一个）。
  final SyncClient client;

  @override
  Future<SnapshotReply<SessionProjections?>> projections({
    required String sid,
  }) => wire.loadSessionProjections(client, sid: sid);

  @override
  Future<SnapshotReply<SessionListPage>> sessionRows({
    int? limit,
    int? offset,
  }) => wire.loadSessionList(client, limit: limit, offset: offset);

  @override
  Future<SnapshotReply<List<SettingSection>?>> settings({
    required List<String> namespaces,
  }) => wire.loadSettings(client, namespaces: namespaces);

  @override
  Future<SnapshotReply<ModelCatalog?>> modelCatalog() =>
      wire.loadModelCatalog(client);

  @override
  Future<SnapshotReply<PermissionCatalog?>> permissionCatalog() =>
      wire.loadPermissionCatalog(client);

  @override
  Future<SnapshotReply<AgentPresetRoster>> agentPresets() =>
      wire.loadAgentPresets(client);

  @override
  Future<SnapshotReply<WorkspaceSnapshot?>> workspaces() =>
      wire.loadWorkspaceList(client);

  @override
  Future<SnapshotReply<RepoInfo?>> repoInfo() => wire.loadRepoInfo(client);

  @override
  Future<PluginInventory?> plugins() => wire.loadPluginInventory(client);

  @override
  Future<FileListing?> fileListing({
    required String sid,
    required String path,
  }) => wire.loadFileListing(client, sid: sid, path: path);

  @override
  Future<FilePage?> filePage({
    required String sid,
    required String path,
    int? offset,
    int? limit,
  }) => wire.loadFilePage(
    client,
    sid: sid,
    path: path,
    offset: offset,
    limit: limit,
  );

  @override
  Future<ChangesSummary?> changesSummary({
    required String sid,
    required int seq,
  }) => wire.loadChangesSummary(client, sid: sid, seq: seq);

  @override
  Future<FileDiff?> fileDiff({
    required String sid,
    required int seq,
    required int index,
  }) => wire.loadFileDiff(client, sid: sid, seq: seq, index: index);

  @override
  Future<SnapshotReply<List<JobRow>?>> jobList({required String sid}) =>
      wire.loadJobList(client, sid: sid);

  @override
  Future<PluginJob?> pluginJobStatus({required String requestId}) =>
      wire.pluginJobStatus(client, requestId: requestId);

  @override
  Future<UsageSummary?> usageSummary() => wire.loadUsageSummary(client);

  @override
  Future<SnapshotReply<List<Endpoint>>> endpoints() =>
      wire.loadEndpoints(client);

  @override
  Future<({List<AtCandidate>? files, List<AtCandidate>? sessions})>
  mentionCandidates({required String sid, required String query}) =>
      wire.loadMentionCandidates(client, sid: sid, query: query);
}
