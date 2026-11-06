/// 一个命名空间的设置快照（`settings.describe` / `settings.update` 的同一形状），
/// **解好之后的值**。
///
/// ## 为什么在 `core/`
///
/// 端口（`core/host_rpc.dart` 的 `HostRpc`）要能把它交出来，而端口是 `data/` 认的那一面。
/// 线上形状不在这里：`{sections: [...]}` / `{section: null | {...}}` 的拆包、缺 `ns` 怎么处置，
/// 全在 `wire/rpc/settings.dart`。
///
/// Note: 分批见 `.agents/notes/implemented/2026-11-06-p1b-batch2-catalog-family.md`。
library;

/// 一个命名空间的设置快照。
///
/// 手机只用三样：`ns`（认哪一行）、`revision`（下一写的乐观锁）、`values`（那一行的当前值）。
/// `secrets` **不声明** —— 密钥值不回传手机（契约 §7.5），少声明一个键就少一处要维护的漂移面。
final class SettingSection {
  const SettingSection({
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
