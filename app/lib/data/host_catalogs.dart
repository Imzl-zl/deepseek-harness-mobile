/// 宿主侧的**只读目录面**：模型目录 / 权限预设目录 / Agent 预设目录。
///
/// ## 为什么把它们从 `AppModel` 里搬出来
///
/// 三个目录同形：一次 `session.*` 只读请求 → 解析 → 缓存在字段里 → 界面读 getter；
/// 失败一律**只留声不升级**（"拉不到目录"不该变成"会话列表也失败了"）。
/// 在 `AppModel` 里它们是三份复制粘贴，而 `AppModel` 已经 4000+ 行 ——
/// 收窄计划的第一簇（`.agents/notes/proposed/2026-10-27-appmodel-narrowing.md`）。
///
/// ## 边界
///
/// - 这不是新的状态库，也不做持久化：目录每次连上都重新拉（宿主才是真值）；
/// - `onChange` 由装配方给（`AppModel` 传 `notifyListeners` 的守卫版），
///   于是这一层不认识 `ChangeNotifier`，可以纯 Dart 测；
/// - 失败**静默**：picker 自己会说"拿不到目录"，这里不重复报错
///   （与原来的 catch 语义逐字相同）。
library;

import '../core/sync_client.dart';
import '../model/agent_preset.dart';
import '../model/model_catalog.dart';
import '../model/permission.dart';
import '../wire/rpc/permission.dart' as wire;
import '../wire/rpc/preset.dart' as wire;
import '../wire/rpc/session.dart' as wire;

class HostCatalogs {
  HostCatalogs({required this.client, required this.onChange});

  final SyncClient client;

  /// 目录变了（**已去重**：值没变就不调）。
  final void Function() onChange;

  ModelCatalog? get modelCatalog => _modelCatalog;
  ModelCatalog? _modelCatalog;

  PermissionCatalog? get permissionCatalog => _permissionCatalog;
  PermissionCatalog? _permissionCatalog;

  AgentPresetRoster? get agentPresetRoster => _agentPresetRoster;
  AgentPresetRoster? _agentPresetRoster;

  /// 权限目录由投影/设置页回填时用（同值不通知）。
  void setPermissionCatalog(PermissionCatalog? catalog) {
    if (identical(catalog, _permissionCatalog)) return;
    _permissionCatalog = catalog;
    onChange();
  }

  /// 拉一次模型目录。形状（`{available, catalog}` 与目录本体）在
  /// `wire/rpc/session.dart` 的 `readModelCatalog`；这里只知道"目录可能拿不到"。
  Future<void> refreshModels() async {
    try {
      final catalog = await wire.loadModelCatalog(client);
      if (catalog == _modelCatalog) return;
      _modelCatalog = catalog;
      onChange();
    } catch (_) {
      // **兜住所有异常，不只 `ProtocolException`**：目录是附属信息，
      // 解析错 / 类型不对 / 超时都不该逃逸成未处理的异步错误，
      // 更不该把"拉不到模型目录"升级成"会话列表也失败了"。
    }
  }

  /// 拉一次权限预设目录。`available: false` 是电脑侧的明说（⇒ null）。
  Future<void> refreshPermissions() async {
    try {
      final catalog = await wire.loadPermissionCatalog(client);
      setPermissionCatalog(catalog);
    } catch (_) {
      // 同 `refreshModels`：只留声，不升级。
    }
  }

  /// 拉一次 Agent 预设目录（目录本体的解析仍在 `model/agent_preset.dart`）。
  Future<void> refreshPresets() async {
    try {
      final roster = await wire.loadAgentPresets(client);
      _agentPresetRoster = roster;
      onChange();
    } catch (_) {
      // 同上。
    }
  }
}
