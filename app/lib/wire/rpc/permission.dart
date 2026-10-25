/// **权限面**（`permission.*`）的唯一入口。
///
/// 两条方法，形状出处 `connector/src/handlers.ts:1088-1111`：
///
/// | 方法 | 应答 |
/// |---|---|
/// | `permission.catalog` `:1088-1094` | `{available: false}` 或 `{available: true, catalog}` |
/// | `permission.switch` `:1098-1111` | `{matched, execution?: {result: {kind, text}}}`（`CommandRunView`）|
///
/// **`available: false` 是电脑侧的明说**（"这个部署没配预设表"），不是形状错：
/// 它解成 `null` 且**不计数**；界面据此说"拿不到目录"，不摆三档手抄的名字
/// （2026-10-15 之前输入栏的权限档正是三个写死的枚举值）。
///
/// **`available: true` 却不给 `catalog`** 才是漂移 ⇒ [WireBad] + 计数。
///
/// `permission.switch` 的应答与 `command.execute` **逐字相同**（同一个
/// `CommandRunView`，`connector/src/dsh/permissions.ts` 的 `PermissionSwitchView = CommandRunView`），
/// 所以解析器只有一个：`model/command.dart` 的 `parseCommandOutcome`。
///
/// Note: 布局与批次见 `.agents/notes/proposed/2026-10-25-wire-rpc-layer-layout.md`。
library;

import '../../core/sync_client.dart';
import '../../model/command.dart' show CommandOutcome, parseCommandOutcome;
import '../../model/permission.dart'
    show PermissionCatalog, parsePermissionCatalog;
import '../fields.dart';
import '../reading.dart';

/// 消费方一次拿齐"三态内核 + 字段内核 + 权限面解码"。
export '../fields.dart';
export '../reading.dart';

const String _kCatalog = 'permission.catalog';
const String _kSwitch = 'permission.switch';

/// 读预设目录（`null` = 电脑侧明说"没有目录"）。
Future<PermissionCatalog?> loadPermissionCatalog(SyncClient client) async {
  final result = await client.call<Object?>(_kCatalog, const {});
  return valueOrReport<PermissionCatalog?>(
    readPermissionCatalog(result),
    _kCatalog,
  );
}

/// 切权限档：回电脑侧的结论（`matched` / `execution`）。
///
/// 回执认不出 ⇒ `null` + 计数一次，由调用方**如实报错**（不把"认不出"当成成功）。
Future<CommandOutcome?> switchPermissionPreset(
  SyncClient client, {
  required String sid,
  required String preset,
  required String requestId,
}) async {
  final result = await client.call<Object?>(_kSwitch, {
    'sid': sid,
    'preset': preset,
  }, requestId: requestId);
  return valueOrReport(readPermissionSwitch(result), _kSwitch);
}

/// `permission.catalog` 的应答。
///
/// `available` 必须**是布尔**（连接器无条件写出它）；`false` ⇒ `WireOk(null)`。
/// `true` ⇒ `catalog` 必须存在且能被 `parsePermissionCatalog` 认出来 ——
/// 目录本体（`options` / `defaultOptions` / `defaultPreset`）的解析仍在
/// `model/permission.dart`（与 `parseTokenUsage` 同一条：值解析住 `model/`）。
WireReading<PermissionCatalog?> readPermissionCatalog(Object? result) =>
    readObject(_kCatalog, result, (fields) {
      final available = fields.requireBool('available');
      if (!available) return null;
      final catalog = fields.requireMap('catalog');
      final parsed = parsePermissionCatalog({
        'available': true,
        'catalog': catalog,
      });
      if (parsed == null) {
        throw const WireFieldError('catalog 认不出（permission.catalog）');
      }
      return parsed;
    });

/// `permission.switch` 的应答（形状与 `command.execute` 同一个）。
WireReading<CommandOutcome> readPermissionSwitch(Object? result) {
  final outcome = parseCommandOutcome(result);
  if (outcome == null) {
    return const WireBad('应答不是 {matched, execution?}（`permission.switch`）');
  }
  return WireOk(outcome);
}
