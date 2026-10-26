/// **设置面**（`settings.*`）的唯一入口。
///
/// 形状出处 `connector/src/handlers.ts:1167-1198`：
///
/// | 方法 | 应答 |
/// |---|---|
/// | `settings.describe` | `{sections: [{ns, revision, values, secrets}]}` |
/// | `settings.update` | `{section: null \| {ns, revision, values, secrets}}` |
///
/// **`section: null` 是合法应答**（宿主对"写了个没有对应快照的 ns"会给 `null`）——
/// 那不是漂移，所以解成 `WireOk(null)` 且不计数。**缺 `section` 这个键**才是漂移。
///
/// 一个 section 里手机只用三样：`ns`（认哪一行）、`revision`（下一写的乐观锁）、
/// `values`（那一行的当前值）。`secrets` **不声明** —— 密钥值不回传手机（契约 §7.5），
/// 少声明一个键就少一处要维护的漂移面。
///
/// Note: 布局与批次见 `.agents/notes/proposed/2026-10-25-wire-rpc-layer-layout.md`。
library;

import '../../core/sync_client.dart';
import '../fields.dart';
import '../reading.dart';

/// 消费方一次拿齐"三态内核 + 字段内核 + 设置面解码"。
export '../fields.dart';
export '../reading.dart';

const String _kDescribe = 'settings.describe';
const String _kUpdate = 'settings.update';

/// 一个命名空间的设置快照（`settings.describe` / `settings.update` 的同一形状）。
final class SettingSectionWire {
  const SettingSectionWire({
    required this.ns,
    required this.revision,
    required this.values,
  });

  final String ns;

  /// 乐观并发用的版本号：写回时当 `expectedRevision`。**类型不声明**（宿主给 `unknown`，
  /// 手机只做"原样带回去"这一件事）。
  final Object? revision;

  /// 已剔除 `role('secret')` 字段的设置值。
  final Map<String, Object?> values;
}

/// 读若干命名空间的快照（读方法：不带幂等键）。
///
/// 一个 section 认不出就**跳过那一条**（少一行设置优于整个设置页报错）；
/// `sections` 不是数组才是 [WireBad]。
Future<List<SettingSectionWire>?> loadSettings(
  SyncClient client, {
  required List<String> namespaces,
}) async {
  final result = await client.call<Object?>(_kDescribe, {
    'namespaces': namespaces,
  });
  return valueOrReport(readSettings(result), _kDescribe);
}

/// 改一个字段（**只发新值**），回改完之后的快照。
///
/// `section: null` ⇒ 返回 `null` 且**不计数**（见文件头）；调用方照"这一行没刷新"处理。
Future<SettingSectionWire?> updateSettingValue(
  SyncClient client, {
  required String ns,
  required List<String> path,
  required Object? value,
  required Object? expectedRevision,
  required String requestId,
}) async {
  final result = await client.call<Object?>(_kUpdate, {
    'ns': ns,
    'path': path,
    'value': value,
    'expectedRevision': expectedRevision,
  }, requestId: requestId);
  return valueOrReport<SettingSectionWire?>(
    readSettingSection(result),
    _kUpdate,
  );
}

/// `settings.describe` 的应答：`{sections: [...]}`。
WireReading<List<SettingSectionWire>> readSettings(Object? result) =>
    readObjectList(
      result,
      method: _kDescribe,
      key: 'sections',
      build: _sectionOf,
    );

/// `settings.update` 的应答：`{section: null | {...}}`。
WireReading<SettingSectionWire?> readSettingSection(Object? result) =>
    readObject(_kUpdate, result, (fields) {
      // **用 `containsKey` 而不是"取不到就当缺席"**：`section: null` 是合法应答
      // （宿主没有给出新快照），两者在这里必须分开。
      if (!fields.map.containsKey('section')) {
        throw const WireFieldError('应答里没有 section 键（`settings.update`）');
      }
      final raw = fields.map['section'];
      // `null` 是合法应答（宿主没有给出新快照），不是漂移。
      if (raw == null) return null;
      if (raw is! Map) {
        throw const WireFieldError('section 不是对象（`settings.update`）');
      }
      // 解不出 ⇒ 抛，由 readObject 折成 WireBad（计数只发生一次）。
      return _sectionOf(WireFields(raw, _kUpdate));
    });

/// 一个 section：`ns` 必填，`revision` / `values` 可选。
///
/// 解不出就抛 [WireFieldError]（由 `readObject` 计数一次）——
/// **不在里面先 `report` 再返回 `null`**，否则同一个缺陷会记两次。
SettingSectionWire _sectionOf(WireFields fields) {
  final ns = fields.requireNonEmptyString('ns');
  final values = fields.map['values'];
  return SettingSectionWire(
    ns: ns,
    revision: fields.map['revision'],
    // `values` 缺席/不是对象 ⇒ 空映射（"这一行没值"与"没读到"在界面同一表现）。
    values: values is Map ? values.cast<String, Object?>() : const {},
  );
}
