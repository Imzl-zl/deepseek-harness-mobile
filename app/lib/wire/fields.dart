/// 字段级读法的**唯一实现**：必填 / 可选 / 降级 / 计数。
///
/// ## 这个文件为什么存在
///
/// `wire/rpc/<面>.dart` 里的解码器如果各自写 `row['x'] is Map ? … : null`，
/// 就又回到"同一件事有很多种写法"——2026-10-25 三次事故的病根都是这个形态。
/// 所以三件事只在这里定义一次：
///
/// 1. **必填字段缺失** ⇒ [WireFieldError]，由 [readObject] 在**对象边界**转成
///    [WireBad]（整个对象丢 + 计数）。理由：身份与"生产者无条件写出的键"缺失，
///    只可能是漂移，猜一个默认值就是把漂移伪装成正常数据。
/// 2. **可选字段读不出** ⇒ 该字段 `null` + **计数一次**，对象保留。
///    理由：一次坏字段不该让整条会话从列表里消失（那比空标题坏得多）。
/// 3. **可选字段缺席** ⇒ `null`，**不计数**。生产侧本来就用 `...(cond ? {} : …)`
///    决定写不写，缺席是线上的正常形态。
///
/// ## 为什么用**作用域内的异常**而不是 `WireReading` 串联
///
/// 一个对象有 5~14 个必填字段，用 `WireReading` 串联会写成 14 层 `switch`，
/// 而**失败必须成"整对象"一件事**（`WireBad(row)` 不带半成品）。
/// 所以：`require*` 在对象内部抛 [WireFieldError]，[readObject] 在那里**一处理一次**
/// 转成 `WireBad`。作用域明确（一次 `readObject` 调用）、类型明确（只捕这一个类型）、
/// 出口唯一（`reading.dart` 的计数 + 打印）—— 不是"宽 catch"。
///
/// ## 依赖方向
///
/// 本文件只依赖 `reading.dart`（纯 Dart，零 Flutter）。family 文件依赖本文件 +
/// `model/` 的模型类 + `core/sync_client.dart` 的端口。
///
/// Note: 布局与批次见 `.agents/notes/proposed/2026-10-25-wire-rpc-layer-layout.md`；
/// 取舍与判据见 `.agents/notes/implemented/2026-10-25-wire-golden-and-session-list.md`。
library;

import 'reading.dart';

/// 必填字段读不出来。**只**由 [readObject] 捕获并转成 [WireBad] —— 别处不许捕。
final class WireFieldError implements Exception {
  const WireFieldError(this.detail);

  final String detail;

  @override
  String toString() => 'WireFieldError: $detail';
}

/// 一个对象的字段读法（键都写在解码器里，类型断言全走这里）。
final class WireFields {
  WireFields(this._map, this.method);

  final Map<Object?, Object?> _map;

  /// 计数/打印时点名的那个方法名（`session.list` / `workspace.list` …）。
  final String method;

  /// 键在不在（`null` 等于不在：生产侧从不写 `null` 表示"有"）。
  bool has(String key) => _map[key] != null;

  // ---------------------------------------------------------------------
  // 必填：缺失 / 类型不对 ⇒ 抛（由 readObject 变成整对象的 WireBad）
  // ---------------------------------------------------------------------

  String requireString(String key) {
    final value = _map[key];
    if (value is String) return value;
    throw WireFieldError(_missing(key, '字符串', value));
  }

  /// 非空字符串（身份键用它：空串与缺席同罪）。
  String requireNonEmptyString(String key) {
    final value = requireString(key);
    if (value.isNotEmpty) return value;
    throw WireFieldError('$key 是空串（`$method`）');
  }

  int requireInt(String key) {
    final value = _map[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    throw WireFieldError(_missing(key, '数字', value));
  }

  bool requireBool(String key) {
    final value = _map[key];
    if (value is bool) return value;
    throw WireFieldError(_missing(key, '布尔', value));
  }

  Map<Object?, Object?> requireMap(String key) {
    final value = _map[key];
    if (value is Map) return value;
    throw WireFieldError(_missing(key, '对象', value));
  }

  List<Object?> requireList(String key) {
    final value = _map[key];
    if (value is List) return value;
    throw WireFieldError(_missing(key, '数组', value));
  }

  // ---------------------------------------------------------------------
  // 可选：缺席 ⇒ null（不计数）；在但读不出 ⇒ null + 计数一次
  // ---------------------------------------------------------------------

  String? optionalString(String key) {
    final value = _map[key];
    if (value == null) return null;
    if (value is String) return value;
    _report('$key 在但不是字符串：$value');
    return null;
  }

  /// 可选 + **空串按缺席**（生产侧会原样透传宿主的空串，那不是漂移）。
  String? optionalNonEmptyString(String key) {
    final value = optionalString(key);
    return (value == null || value.isEmpty) ? null : value;
  }

  /// 可选 + **空串算漂移**（生产侧明确不为空串写这个键，如 `parentSessionId`）。
  String? optionalAlias(String key) {
    final value = _map[key];
    if (value == null) return null;
    if (value is String && value.isNotEmpty) return value;
    _report('$key 在但不是可用的非空字符串：$value');
    return null;
  }

  int? optionalInt(String key) {
    final value = _map[key];
    if (value == null) return null;
    if (value is num) return value.toInt();
    _report('$key 在但不是数字：$value');
    return null;
  }

  bool? optionalBool(String key) {
    final value = _map[key];
    if (value == null) return null;
    if (value is bool) return value;
    _report('$key 在但不是布尔：$value');
    return null;
  }

  Map<Object?, Object?>? optionalMap(String key) {
    final value = _map[key];
    if (value == null) return null;
    if (value is Map) return value;
    _report('$key 在但不是对象：$value');
    return null;
  }

  List<Object?>? optionalList(String key) {
    final value = _map[key];
    if (value == null) return null;
    if (value is List) return value;
    _report('$key 在但不是数组：$value');
    return null;
  }

  /// **投影信封** `{kind, asOfSeq, values}` → `values`。
  ///
  /// `session.list` 行里的 `.projections`、以及若干 `*.projections` 提示都是这个形状。
  /// **它不是扁平 map**：`session.projections` 的**应答**才是扁平 `values`
  /// （`connector/src/dsh/projections.ts:68-72` 拆掉了信封）——那种用 [flatValues]。
  /// 信封坏 ⇒ 计数一次（信封本身坏了，只报一次，不按字段报四次）。
  Map<Object?, Object?>? envelopeValues(String key) {
    final raw = _map[key];
    if (raw == null) return null;
    if (raw is Map) {
      final values = raw['values'];
      if (values is Map) return values;
    }
    _report('$key 在但不是信封 {kind, asOfSeq, values}：$raw');
    return null;
  }

  /// 出声（计数由 `WireDiagnostics` 统一做，与 `reading.dart` 同一个出口）。
  void report(String detail) => _report(detail);

  void _report(String detail) => WireDiagnostics.report(method, detail);

  String _missing(String key, String expected, Object? actual) => actual == null
      ? '缺 $key（期望$expected，`$method`）'
      : '$key 不是$expected：$actual';
}

/// 读一个**扁平 `values` 映射**（`session.projections` 的应答形态）。
///
/// 与 [WireFields.envelopeValues] 是一对：**同一个名字的两种形状**，各自一个入口，
/// 谁用错谁在类型上就过不去（这里收的是"已经是 values 的那个对象"）。
Map<Object?, Object?>? flatValues(Object? raw) => raw is Map ? raw : null;

/// 读一个对象：**必填缺失 ⇒ 整对象 [WireBad]**；可选读不出 ⇒ 计数 + `null`（对象保留）。
///
/// 这是所有 family 解码器唯一的行/对象入口。`build` 里只用 [WireFields] 的方法，
/// 不许再碰裸 `Map`（否则"同一件事只有一种写法"就不成立了）。
WireReading<T> readObject<T>(
  String method,
  Object? raw,
  T Function(WireFields fields) build,
) {
  if (raw is Map) {
    try {
      return WireOk(build(WireFields(raw, method)));
    } on WireFieldError catch (error) {
      return WireBad(error.detail);
    }
  }
  return WireBad('载荷不是对象（`$method`）');
}

/// 读 `{<key>: [...]}` 形态的应答（`{sessions}` / `{items}` / `{jobs}` / `{plugins}`
/// / `{bundles}` / `{files}` / `{references}` …）。
///
/// 分两档，与 `wire/reading.dart` 的语义一致：
/// - **信封错**（`result` 不是对象、或没有 `key` 数组）⇒ 整天 [WireBad]；
/// - **单个条目坏** ⇒ 丢那一条 + 计数一次，其余照常返回。
///
/// 丢条目而不是整天失败，是因为"一条坏行让整个列表消失"比"少一条"坏得多
/// ——`session.list` 那次事故就是这个形态。
WireReading<List<T>> readObjectList<T>(
  Object? result, {
  required String method,
  required String key,
  required T Function(WireFields fields) build,
}) {
  if (result is! Map) {
    return WireBad('应答不是 {$key: [...]}（`$method`）');
  }
  final raw = result[key];
  if (raw is! List) {
    return WireBad('应答里没有 $key 数组（`$method`）');
  }
  final out = <T>[];
  for (final entry in raw) {
    final decoded = readObject(method, entry, build);
    switch (decoded) {
      case WireOk<T>(:final value):
        out.add(value);
      case WireSkip<T>():
        break;
      case WireBad<T>(:final detail):
        WireDiagnostics.report(method, detail);
    }
  }
  return WireOk(List<T>.unmodifiable(out));
}

/// 读"成功回执"形态（`{accepted: true}` / `{stopped: bool}` 之类）。
///
/// 认不出就是 [WireBad]：**回执读不出来不能当成成功**（`settings.update` 曾经
/// 认不出仍 `return true`，见设计笔记 Alternatives 里 d 方案那一条）。
WireReading<T> readReceipt<T>(
  String method,
  Object? result,
  T Function(WireFields fields) build,
) => readObject(method, result, build);
