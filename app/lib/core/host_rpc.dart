/// 电脑侧的两个能力口：**读**（`HostReads`）与**写**（`HostWrites`），
/// 声明在这里、实现在 `wire/`。
///
/// ## 为什么是两个口而不是一个
///
/// 不是"读和写长得不一样"，而是**失败语义相反**：
///
/// | | 读 | 写 |
/// |---|---|---|
/// | 读不到 / 失败 | 那些面显示**空态**，人继续用 | **必须大声失败**（答案/操作没进去） |
/// | 参数 | 快照参数（`sid` / `limit` / `path`） | 都带**幂等键** `requestId`（契约 §5.6） |
/// | 传输 | 即时请求 | 走 outbox（先落盘再发） |
/// | 谁需要 | `AppModel` / `HostCatalogs` / `FilePreview` | `AppModel` |
///
/// 混成一个口，调用点就看不出"这一次失败该空着还是该报错"，而这条判据会散到每个
/// `try/catch` 里。切开的代价只是多一个接口（客户端仍只多两个 getter）。
///
/// ## 形状：能力是**一个对象**，客户端只是"拿得到它"
///
/// ```text
/// AppModel ──> client.reads / client.writes（两个 getter）──> WireHostReads / WireHostWrites
/// ```
///
/// 不把方法塞进 `SyncClient`：它是全仓二十多个替身 `implements` 的端口，加一个抽象方法
/// 就得逐处补空实现（`core/sync_client.dart` 的 `LinkControl` 写过同一条理由）。
/// 也**不**让客户端自己实现这些方法：活不在客户端里（在 `wire/` 里），
/// 那样会逼出"逐方法转发"或一层转发基类 —— 那一版试过、已换掉，
/// 见 `.agents/notes/implemented/2026-11-06-p1b-hostrpc-holder.md`。
///
/// Note: 分批与代价见 `.agents/notes/proposed/2026-11-06-p1b-host-rpc-port.md`
/// 与 `implemented/2026-11-06-p1b-batch4-*`。
library;

import '../model/agent_preset.dart' show AgentPresetRoster;
import '../model/changes.dart' show ChangesSummary;
import '../model/chat_item.dart' show ModelRef;
import '../model/command.dart' show CommandOutcome;
import '../model/file_diff.dart' show FileDiff;
import '../model/mention.dart' show AtCandidate;
import '../model/model_catalog.dart' show ModelCatalog;
import '../model/permission.dart' show PermissionCatalog;
import '../model/plugins.dart' show PluginJob;
import '../model/usage_summary.dart' show UsageSummary;
import '../model/workspace_files.dart' show FileListing, FilePage;
import 'endpoint.dart' show Endpoint;
import 'job.dart' show JobRow;
import 'plugin_inventory.dart';
import 'repo_info.dart';
import 'session_list_page.dart';
import 'session_projections.dart';
import 'setting_section.dart';
import 'snapshot_digest.dart';
import 'sync_client.dart';
import 'workspace_snapshot.dart';

/// 「读电脑侧的只读面」：**读不到就是空态**，不升级成错误。
///
/// 三态（正文 / 没变 / 读不出）由 [SnapshotReply] 表达；不带三态的那几个
/// （`null` = 读不出）与对应的 `loadXxx` 逐字同形，计数与出声仍在 `wire/` 的
/// `valueOrReport` 那一处。
///
/// 实现自己持有那条连接（`WireHostReads(client)`），所以方法**不收 `client`**。
abstract interface class HostReads {
  /// 读一个会话的投影包（`session.projections`，契约 §5.7）。
  ///
  /// 返回 `notModified` 时调用方**什么都不做**（不清数据、不报错、不通知）；
  /// 正文 `null` 才是"这次读不出来" —— 两者在界面上是相反的两件事。
  Future<SnapshotReply<SessionProjections?>> projections({required String sid});

  /// 要一页会话行（`session.list`）。[limit] / [offset] 分页参数，不传就是整表。
  Future<SnapshotReply<SessionListPage>> sessionRows({int? limit, int? offset});

  /// 读若干命名空间的设置快照（`settings.describe`）。
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
  /// **没有摘要三态**：两侧都读不出才回 `null`，一侧坏了就那一侧空表。
  Future<PluginInventory?> plugins();

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

  /// 拉一次任务清单（`job.list`；后续变化走 `job` 帧的 `status`）。
  Future<SnapshotReply<List<JobRow>?>> jobList({required String sid});

  /// 问一次插件任务状态（`plugin.installStatus`，轮询用）。
  Future<PluginJob?> pluginJobStatus({required String requestId});

  /// 拉一次跨会话用量汇总（`usage.summary`）。读不出 ⇒ `null`（调用方说"拉不到"）。
  Future<UsageSummary?> usageSummary();

  /// 拉一次电脑侧自报的端点表（`endpoint.describe`）。
  Future<SnapshotReply<List<Endpoint>>> endpoints();

  /// 一次查两种 `@` 候选（`refs.files` + `refs.sessions`，并发）。
  ///
  /// 任一侧读不出 ⇒ 那一侧 `null`（调用方按"这一列没有"渲染）。
  Future<({List<AtCandidate>? files, List<AtCandidate>? sessions})>
  mentionCandidates({required String sid, required String query});
}

/// 「改电脑侧的状态」：**失败必须大声**（操作没进去不能装成功）。
///
/// 全部带幂等键 [requestId]（契约 §5.6：先落盘再发，重发安全）—— 唯一例外是
/// `respondInteraction`（它拿 `itemId` 当幂等键）与三个任务订阅（宿主不给幂等键）。
abstract interface class HostWrites {
  /// 建会话（`session.create`），回新 `sid`（读不出 ⇒ `null`，调用方大声失败）。
  Future<String?> createSession({
    String? workspaceId,
    String? agentPreset,
    required String requestId,
  });

  /// 在一轮收口处分支（`session.fork`），回子会话 `sid`。
  Future<String?> forkSession({required String sid, int? atSeq});

  /// 切模型（`session.select-model`），回电脑侧选定的那个。
  Future<ModelRef?> selectModel({
    required String sid,
    required String provider,
    required String model,
    String? reasoningEffort,
    required String requestId,
  });

  /// 打断当前轮次（`session.cancel`；应答不读）。
  Future<void> cancelSession({required String sid});

  /// 变异一个排队项（`session.updateQueue`；应答不读）。
  Future<void> updateQueue({
    required String sid,
    required String itemId,
    required Map<String, Object?> action,
    required String requestId,
  });

  /// 跑一条斜杠命令（`command.execute`）。回执认不出 ⇒ `null`（调用方如实报错）。
  Future<CommandOutcome?> executeCommand({
    required String sid,
    required String line,
    required String requestId,
  });

  /// 切权限档（`permission.switch`）。回执认不出 ⇒ `null`。
  Future<CommandOutcome?> switchPermission({
    required String sid,
    required String preset,
    required String requestId,
  });

  /// 答复一次审批/提问（`interaction.respond`）。**失败照原样抛**。
  Future<void> respondInteraction({
    required String sid,
    required String itemId,
    required List<Map<String, Object?>> answers,
  });

  /// 改一个设置字段（`settings.update`，只发新值）。
  ///
  /// `section: null` 是合法应答（宿主没给新快照）⇒ 返回 `null` 且**不计数**。
  Future<SettingSection?> updateSetting({
    required String ns,
    required List<String> path,
    required Object? value,
    required Object? expectedRevision,
    required String requestId,
  });

  /// 启停一个插件（`plugin.setEnabled`），回宿主**回读后的真值**。
  Future<({bool enabled, String application, String restartReason})?>
  setPluginEnabled({
    required String id,
    required bool enabled,
    required String requestId,
  });

  /// 发起一次安装（`plugin.install`），回任务 id。
  Future<String?> installPlugin({
    required String spec,
    required String requestId,
  });

  /// 卸载一个**包**（`plugin.remove`，按包名）。
  Future<String?> removePlugin({
    required String name,
    required String requestId,
  });

  /// 取消一次安装（`plugin.cancelInstall`），回宿主的三档状态。
  Future<String?> cancelPluginInstall({required String requestId});

  /// 置顶一个会话（`workspace.pin`），回**置顶全集**。
  Future<Set<String>?> pinSession({
    required String sid,
    required String requestId,
  });

  /// 取消置顶（`workspace.unpin`），回置顶全集。
  Future<Set<String>?> unpinSession({
    required String sid,
    required String requestId,
  });

  /// 归档（`workspace.archive`），回归档全集。
  ///
  /// [stopActivity] 只在为真时才带那个键（宿主判的是 `=== true`）。
  Future<Set<String>?> archiveSession({
    required String sid,
    required bool stopActivity,
    required String requestId,
  });

  /// 取消归档（`workspace.unarchive`），回归档全集。
  Future<Set<String>?> unarchiveSession({
    required String sid,
    required String requestId,
  });

  /// 同工作区内重排会话（`workspace.insertSessionBefore`），回该工作区的新顺序。
  ///
  /// [beforeSid] 为 `null` = 追加到末尾（**不给这个键**，不是给空串）。
  Future<List<String>?> moveSession({
    required String workspaceId,
    required String sid,
    required String? beforeSid,
    required String requestId,
  });

  /// 工作区自己重排（`workspace.insertBefore`），回整份工作区顺序。
  Future<List<String>?> moveWorkspace({
    required String workspaceId,
    required String? beforeWorkspaceId,
    required String requestId,
  });

  /// 订阅一个任务的输出流（`job.follow`；应答不读，输出走 `job` 帧）。
  Future<void> followJob({required String sid, required String jobId});

  /// 退订任务输出（`job.unfollow`；应答不读）。
  Future<void> unfollowJob({required String sid, required String jobId});

  /// 停一个任务（`job.kill`），回宿主的结论（认不出 ⇒ `null`）。
  Future<String?> killJob({required String sid, required String jobId});
}

/// 「我这一条连接上有那两个口」—— 客户端兼作这个，**只多两个 getter**。
abstract interface class HostRpcHolder {
  /// 读能力（读不到就是空态）。
  HostReads get reads;

  /// 写能力（失败必须大声）。
  HostWrites get writes;
}

/// 取一个客户端的能力口；没有就**抛出**。
///
/// 为什么抛而不是回 `null`：缺能力是**装配错误**（装配点漏了
/// `SyncClientDeps.hostRpc`，或测试替身没接端口），不是"这台电脑读不出东西"。
/// 静默降级会让两者在界面上一模一样（只读面全空），而它们该由不同的人修。
///
/// 判据只写在这一处（`AppModel` / `HostCatalogs` / `FilePreview` 都调它）。
HostRpcHolder hostRpcOf(SyncClient client) {
  if (client is HostRpcHolder) return client as HostRpcHolder;
  throw StateError(
    '${client.runtimeType} 没有 HostRpc 能力：读不了电脑侧，也操作不了它。'
    '装配点要给 SyncClientDeps.hostRpc（生产是 WireHostRpc.new），'
    '测试替身要 implements HostRpcHolder。',
  );
}
