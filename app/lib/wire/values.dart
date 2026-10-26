/// **跨面共享的值解析**：同一份投影/引用形状出现在多个面时，解析器只住这里。
///
/// 这些不是"字段读法"（那在 `wire/fields.dart`），而是**值对象**的形状：
/// 同一个值在 `session.list` 的行里与 `session.projections` 的应答里都出现，
/// 就必须只有一份解析，否则两处会各自演化（2026-10-26 评审的第 5 条）。
///
/// Note: 取舍见 `.agents/notes/proposed/2026-10-26-wire-review-fixes.md`（第 4 批）。
library;

import '../model/chat_item.dart' show ModelRef;
import 'fields.dart';

/// `{provider, model, reasoningEffort?}` → [ModelRef]。
///
/// - 缺席 ⇒ `null`，**不计数**（投影没落 / 子会话取不到，都是正常形态）；
/// - 在但不是对象 ⇒ 计数一次；
/// - 是对象但缺 `provider` / `model` ⇒ `null`、不计数（硬填空串会让界面
///   显示一个空的模型名，那比"未选择"更糟）。
ModelRef? modelRefOf(Object? raw, WireFields fields) {
  if (raw == null) return null;
  if (raw is! Map) {
    fields.report('模型引用不是对象：$raw');
    return null;
  }
  final provider = raw['provider'];
  final model = raw['model'];
  if (provider is! String || provider.isEmpty) return null;
  if (model is! String || model.isEmpty) return null;
  final effort = raw['reasoningEffort'];
  return ModelRef(
    provider: provider,
    model: model,
    reasoningEffort: effort is String && effort.isNotEmpty ? effort : null,
  );
}

/// `modelSelection` 投影 → `next ?? lastUsed` → [ModelRef]。
///
/// **`next ?? lastUsed` 与 DSH 的线格式逐字一致**
/// （`packages/api/session-controller/src/model-selection-projection.ts:65`
/// 的 `view: state => ({lastUsed, next: state.pending ?? state.lastUsed})`），
/// 与连接器的 `modelOf` 也是同一条（`connector/src/dsh/models.ts:92-101`）。
///
/// `lastUsed` / `next` 都是 `null` 是**正常**（新会话、投影还没落），不计数。
ModelRef? modelSelectionOf(Object? raw, WireFields fields) {
  if (raw == null) return null;
  if (raw is! Map) {
    fields.report('modelSelection 不是对象：$raw');
    return null;
  }
  return modelRefOf(raw['next'] ?? raw['lastUsed'], fields);
}
