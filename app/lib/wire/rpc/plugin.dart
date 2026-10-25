/// **插件面**（`plugin.*`）的唯一入口。
///
/// 形状出处 `connector/src/handlers.ts`：
///
/// | 方法 | 应答 |
/// |---|---|
/// | `plugin.list` `:1252` | `{plugins: [...]}`（行由 `model/plugins.dart` 的 `PluginRow.fromWire` 解）|
/// | `plugin.listBundles` `:1254` | `{bundles: [...]}`（`PluginBundle.fromWire`）|
/// | `plugin.setEnabled` `:1256-1294` | `{enabled, application?, restartReason?}`（**回读后的真值**）|
/// | `plugin.install` / `plugin.remove` `:1225-1243` | `{requestId}`（发起即返回；`requestId` 既是幂等键也是句柄）|
/// | `plugin.installStatus` `:1247` | 任务状态（`PluginJob.fromWire`）|
/// | `plugin.cancelInstall` `:1244` | `{status}`（宿主的三档之一）|
///
/// ## 两条纪律落在这里
///
/// 1. **`setEnabled` 的 `enabled` 是回读后的真值**，不是我们请求的那个值
///    （宿主在 `overridden` 时给的是终态）。所以解码器只认应答，调用方据此就地更正那一行。
/// 2. **发起即返回**：安装/卸载真实跑 pnpm、常超 60 s 请求超时，所以它们的应答只有 `requestId`；
///    结论靠 `plugin.installStatus` 轮询（与 `session.projections` 同一种节奏）。
///
/// `plugin.install` / `plugin.remove` 的**参数形状不同**（`{spec}` / `{name}`），所以在
/// 这里分成两个函数 —— 旧实现用一个 `_startPluginJob(method, body)` 把方法名当参数传，
/// 那正好是"方法名 + 参数形状各在一处、且都可以被调用方拼错"的形态。
///
/// Note: 布局与批次见 `.agents/notes/proposed/2026-10-25-wire-rpc-layer-layout.md`。
library;

import '../../core/sync_client.dart';
import '../../model/plugins.dart' show PluginBundle, PluginJob, PluginRow;
import '../fields.dart';
import '../reading.dart';

/// 消费方一次拿齐"三态内核 + 字段内核 + 插件面解码"。
export '../fields.dart';
export '../reading.dart';

const String _kList = 'plugin.list';
const String _kBundles = 'plugin.listBundles';
const String _kSetEnabled = 'plugin.setEnabled';
const String _kInstall = 'plugin.install';
const String _kRemove = 'plugin.remove';
const String _kStatus = 'plugin.installStatus';
const String _kCancel = 'plugin.cancelInstall';

/// 一次插件清单读的结论：**两张表**（插件行 + 包）。
///
/// 两个面各一发（并发）：卸载按包名走，所以包清单不是插件行的派生品。
final class PluginInventoryWire {
  const PluginInventoryWire({required this.rows, required this.bundles});

  final List<PluginRow> rows;
  final List<PluginBundle> bundles;
}

/// 读插件清单与包清单（两发并发）。
///
/// 任一侧读不出来 ⇒ 那一侧空表（另一侧照常给），并计一次数；
/// **两侧都读不出来**才返回 `null`（调用方把插件页画成"读取失败"）。
Future<PluginInventoryWire?> loadPluginInventory(SyncClient client) async {
  final answers = await Future.wait<WireReading<List<Object?>>?>([
    _readList(client, _kList, 'plugins'),
    _readList(client, _kBundles, 'bundles'),
  ]);
  final rows = valueOrReport(answers[0]!, _kList);
  final bundles = valueOrReport(answers[1]!, _kBundles);
  if (rows == null && bundles == null) return null;
  return PluginInventoryWire(
    rows: [
      for (final row in rows ?? const <Object?>[]) ?PluginRow.fromWire(row),
    ],
    bundles: [
      for (final row in bundles ?? const <Object?>[])
        ?PluginBundle.fromWire(row),
    ],
  );
}

/// 启停一行：回**宿主回读后的真值**（不是我们请求的那个值）。
Future<({bool enabled, String application, String restartReason})?>
setPluginEnabled(
  SyncClient client, {
  required String id,
  required bool enabled,
  required String requestId,
}) async {
  final result = await client.call<Object?>(_kSetEnabled, {
    'id': id,
    'enabled': enabled,
  }, requestId: requestId);
  return valueOrReport(readPluginToggle(result), _kSetEnabled);
}

/// 发起一次安装（`{spec}`）。回任务 id（**同一个 id 就是幂等键**）。
Future<String?> startPluginInstall(
  SyncClient client, {
  required String spec,
  required String requestId,
}) => _startJob(client, _kInstall, {'spec': spec}, requestId);

/// 卸载一个**包**（`{name}`，不是包内的插件 id）。
Future<String?> removePluginBundle(
  SyncClient client, {
  required String name,
  required String requestId,
}) => _startJob(client, _kRemove, {'name': name}, requestId);

/// 问一次任务状态（轮询用）。
Future<PluginJob?> pluginJobStatus(
  SyncClient client, {
  required String requestId,
}) async {
  final result = await client.call<Object?>(_kStatus, {'requestId': requestId});
  return valueOrReport(readPluginJob(result), _kStatus);
}

/// 取消一次安装：回宿主的三档状态（原样）。
Future<String?> cancelPluginInstall(
  SyncClient client, {
  required String requestId,
}) async {
  final result = await client.call<Object?>(_kCancel, {'requestId': requestId});
  return valueOrReport(readPluginCancelStatus(result), _kCancel);
}

// ---------------------------------------------------------------------------
// 纯解码
// ---------------------------------------------------------------------------

/// `plugin.list` 的应答 `{plugins: [...]}`（行由 `model/plugins.dart` 解）。
WireReading<List<Object?>> readPluginList(Object? result) =>
    _readListFrom(result, _kList, 'plugins');

/// `plugin.listBundles` 的应答 `{bundles: [...]}`。
WireReading<List<Object?>> readPluginBundles(Object? result) =>
    _readListFrom(result, _kBundles, 'bundles');

/// `plugin.setEnabled` 的应答。
///
/// `enabled` 必须**是布尔**：它是"回读后的真值"，读不出来就不能假装切成功了。
/// `application` / `restartReason` 可选（宿主只在需要时给）。
WireReading<({bool enabled, String application, String restartReason})>
readPluginToggle(Object? result) => readObject(_kSetEnabled, result, (fields) {
  final enabled = fields.requireBool('enabled');
  return (
    enabled: enabled,
    application: fields.optionalString('application') ?? '',
    restartReason: fields.optionalString('restartReason') ?? '',
  );
});

/// `plugin.install` / `plugin.remove` 的应答 `{requestId}`（发起即返回）。
WireReading<String> readPluginJobStart(
  Object? result, {
  required String method,
}) => readObject(
  method,
  result,
  (fields) => fields.requireNonEmptyString('requestId'),
);

/// `plugin.installStatus` 的应答（本体由 `model/plugins.dart` 的 `PluginJob.fromWire` 解）。
WireReading<PluginJob> readPluginJob(Object? result) =>
    readObject(_kStatus, result, (fields) {
      final job = PluginJob.fromWire(fields.map);
      if (job == null) {
        throw const WireFieldError('任务状态认不出（plugin.installStatus）');
      }
      return job;
    });

/// `plugin.cancelInstall` 的应答 `{status}`。
WireReading<String> readPluginCancelStatus(Object? result) => readObject(
  _kCancel,
  result,
  (fields) => fields.requireNonEmptyString('status'),
);

// ---------------------------------------------------------------------------

Future<String?> _startJob(
  SyncClient client,
  String method,
  Map<String, Object?> body,
  String requestId,
) async {
  final result = await client.call<Object?>(method, body, requestId: requestId);
  // 电脑侧回的是它自己记下的那个 id（正常等于我们发的）；读不出来就**回我们发的那个**，
  // 因为那个 id 已经作为幂等键发出去了，轮询必须用同一个。
  return valueOrReport(readPluginJobStart(result, method: method), method) ??
      requestId;
}

Future<WireReading<List<Object?>>?> _readList(
  SyncClient client,
  String method,
  String key,
) async =>
    _readListFrom(await client.call<Object?>(method, const {}), method, key);

WireReading<List<Object?>> _readListFrom(
  Object? result,
  String method,
  String key,
) {
  if (result is! Map) return WireBad('应答不是 {$key: [...]}（`$method`）');
  final rows = result[key];
  if (rows is! List) return WireBad('应答里没有 $key 数组（`$method`）');
  return WireOk(List<Object?>.unmodifiable(rows));
}
