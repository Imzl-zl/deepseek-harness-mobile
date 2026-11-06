/// `HostWrites` 的实现：**形状知识仍然只在 `wire/`**。
///
/// 每个方法一行：方法名、参数形状、幂等键怎么给全在被它转过去的那个函数里；
/// 这一层不判"成功没成功"（回执认不出 ⇒ 那个函数已经计过数并回 `null`）。
///
/// `rpc/*.dart` 一律加 `as wire` 前缀：`createSession` / `killJob` / `cancelSession`
/// 这些名字在端口与 `wire/` 里**同名**，不带前缀的调用会解析回本类的方法
/// （无限递归，或"参数个数不对"）。
///
/// Note: 为什么读写分两个口见 `core/host_rpc.dart` 的文件头；
/// 分批与代价见 `.agents/notes/implemented/2026-11-06-p1b-batch4-read-write-ports.md`。
library;

import '../core/host_rpc.dart';
import '../core/setting_section.dart';
import '../core/sync_client.dart';
import '../model/chat_item.dart' show ModelRef;
import '../model/command.dart' show CommandOutcome;
import 'rpc/command.dart' as wire;
import 'rpc/interaction.dart' as wire;
import 'rpc/job.dart' as wire;
import 'rpc/permission.dart' as wire;
import 'rpc/plugin.dart' as wire;
import 'rpc/session.dart' as wire;
import 'rpc/settings.dart' as wire;
import 'rpc/subagent.dart' as wire;
import 'rpc/workspace.dart' as wire;

/// 端口 `HostWrites` 的唯一实现。
final class WireHostWrites implements HostWrites {
  const WireHostWrites(this.client);

  /// 这条连接（工厂 `hostRpc` 收到的那一个）。
  final SyncClient client;

  @override
  Future<String?> createSession({
    String? workspaceId,
    String? agentPreset,
    required String requestId,
  }) => wire.createSession(
    client,
    workspaceId: workspaceId,
    agentPreset: agentPreset,
    requestId: requestId,
  );

  @override
  Future<String?> forkSession({required String sid, int? atSeq}) =>
      wire.forkSession(client, sid: sid, atSeq: atSeq);

  @override
  Future<ModelRef?> selectModel({
    required String sid,
    required String provider,
    required String model,
    String? reasoningEffort,
    required String requestId,
  }) => wire.selectModel(
    client,
    sid: sid,
    provider: provider,
    model: model,
    reasoningEffort: reasoningEffort,
    requestId: requestId,
  );

  @override
  Future<void> cancelSession({required String sid}) =>
      wire.cancelSession(client, sid: sid);

  @override
  Future<void> updateQueue({
    required String sid,
    required String itemId,
    required Map<String, Object?> action,
    required String requestId,
  }) => wire.updateQueueAction(
    client,
    sid: sid,
    itemId: itemId,
    action: action,
    requestId: requestId,
  );

  @override
  Future<void> sendPrompt({
    required String sid,
    required List<Object?> content,
    required String mode,
    required String requestId,
  }) => wire.sendPrompt(
    client,
    sid: sid,
    content: content,
    mode: mode,
    requestId: requestId,
  );

  @override
  Future<void> sendSubagentPrompt({
    required String sid,
    required List<Object?> content,
    required String mode,
    required String requestId,
  }) => wire.sendSubagentPrompt(
    client,
    sid: sid,
    content: content,
    mode: mode,
    requestId: requestId,
  );

  @override
  Future<CommandOutcome?> executeCommand({
    required String sid,
    required String line,
    required String requestId,
  }) => wire.executeCommand(client, sid: sid, line: line, requestId: requestId);

  @override
  Future<CommandOutcome?> switchPermission({
    required String sid,
    required String preset,
    required String requestId,
  }) => wire.switchPermissionPreset(
    client,
    sid: sid,
    preset: preset,
    requestId: requestId,
  );

  @override
  Future<void> respondInteraction({
    required String sid,
    required String itemId,
    required List<Map<String, Object?>> answers,
  }) => wire.respondInteraction(
    client,
    sid: sid,
    itemId: itemId,
    answers: answers,
  );

  @override
  Future<SettingSection?> updateSetting({
    required String ns,
    required List<String> path,
    required Object? value,
    required Object? expectedRevision,
    required String requestId,
  }) => wire.updateSettingValue(
    client,
    ns: ns,
    path: path,
    value: value,
    expectedRevision: expectedRevision,
    requestId: requestId,
  );

  @override
  Future<({bool enabled, String application, String restartReason})?>
  setPluginEnabled({
    required String id,
    required bool enabled,
    required String requestId,
  }) => wire.setPluginEnabled(
    client,
    id: id,
    enabled: enabled,
    requestId: requestId,
  );

  @override
  Future<String?> installPlugin({
    required String spec,
    required String requestId,
  }) => wire.startPluginInstall(client, spec: spec, requestId: requestId);

  @override
  Future<String?> removePlugin({
    required String name,
    required String requestId,
  }) => wire.removePluginBundle(client, name: name, requestId: requestId);

  @override
  Future<String?> cancelPluginInstall({required String requestId}) =>
      wire.cancelPluginInstall(client, requestId: requestId);

  @override
  Future<Set<String>?> pinSession({
    required String sid,
    required String requestId,
  }) => wire.workspacePin(client, sid: sid, requestId: requestId);

  @override
  Future<Set<String>?> unpinSession({
    required String sid,
    required String requestId,
  }) => wire.workspaceUnpin(client, sid: sid, requestId: requestId);

  @override
  Future<Set<String>?> archiveSession({
    required String sid,
    required bool stopActivity,
    required String requestId,
  }) => wire.workspaceArchive(
    client,
    sid: sid,
    stopActivity: stopActivity,
    requestId: requestId,
  );

  @override
  Future<Set<String>?> unarchiveSession({
    required String sid,
    required String requestId,
  }) => wire.workspaceUnarchive(client, sid: sid, requestId: requestId);

  @override
  Future<List<String>?> moveSession({
    required String workspaceId,
    required String sid,
    required String? beforeSid,
    required String requestId,
  }) => wire.workspaceInsertSessionBefore(
    client,
    workspaceId: workspaceId,
    sid: sid,
    beforeSid: beforeSid,
    requestId: requestId,
  );

  @override
  Future<List<String>?> moveWorkspace({
    required String workspaceId,
    required String? beforeWorkspaceId,
    required String requestId,
  }) => wire.workspaceInsertBefore(
    client,
    workspaceId: workspaceId,
    beforeWorkspaceId: beforeWorkspaceId,
    requestId: requestId,
  );

  @override
  Future<void> followJob({required String sid, required String jobId}) =>
      wire.followJobOutput(client, sid: sid, jobId: jobId);

  @override
  Future<void> unfollowJob({required String sid, required String jobId}) =>
      wire.unfollowJobOutput(client, sid: sid, jobId: jobId);

  @override
  Future<String?> killJob({required String sid, required String jobId}) =>
      wire.killJob(client, sid: sid, jobId: jobId);
}
