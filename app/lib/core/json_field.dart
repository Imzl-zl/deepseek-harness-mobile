/// 对**裸 JSON** 取字段的几个宽松助手：非 Map / 非目标类型一律回 `null`，从不抛。
///
/// ## 为什么在 `core/`
///
/// 它们是"取一个字段看看在不在"这一层最底的操作，被两个方向都要用：
///
/// - `data/projection.dart`（事件 → 界面条目，唯一认识事件语义处）大量使用；
/// - `model/permission.dart`（把 `session.projections` 的值解成权限档）。
///
/// 原先它们住在 `data/projection.dart` 里，于是 `model/` 要反向 import `data/`。
/// `core/` 是两边共同的底，且零平台依赖（`app-platform-boundaries.md` 的分层规则）。
///
/// **与 `wire/fields.dart` 不是一回事**：那一层是"必填字段读不出来就整包判坏"
/// （`WireFields.requireString` 抛 `WireFieldError`，由 `readObject` 收成 `WireBad`）；
/// 这里是"宽松取值"，给那些**本来就可能缺**的字段用（投影的载荷、投影值里的
/// 嵌套对象）。两者判据不同（一个 fail-closed、一个 return-null），所以不合并。
library;

/// 取一个字段（非 Map 返回 `null`）。
Object? fieldOf(Object? value, String key) => value is Map ? value[key] : null;

/// 取一个字符串字段（非字符串或空串返回 `null`）。
String? stringField(Object? value, String key) {
  final field = fieldOf(value, key);
  return field is String && field.isNotEmpty ? field : null;
}

/// 取一个整数字段（非 int 返回 `null`）。
///
/// **不收 `num`**：JSON 解出来 `1` 是 int、`1.0` 是 double，而 DSH 的
/// `retry` / `maxRetries` / `turn` 在 schema 里都是 `z.number().int()`
/// （`llm/retry` 的 `retry.ts:45-48`、`turn/end` 的 turn 号）——
/// 收到 double 说明形状变了，那时该看不出来，而不是悄悄截断。
int? intField(Object? value, String key) {
  final field = fieldOf(value, key);
  return field is int ? field : null;
}

/// 把一个值当非空字符串取（非字符串或空串返回 `null`）。
String? nonEmptyString(Object? value) =>
    (value is String && value.isNotEmpty) ? value : null;
