/// 一次插件清单读的结论（**两张表**），**解好之后的值**。
///
/// ## 为什么在 `core/`
///
/// 端口（`core/host_rpc.dart` 的 `HostRpc`）要能把它交出来，而端口是 `data/` 认的那一面。
/// 两个面各一发（并发）怎么合、坏一侧怎么降级，全在 `wire/rpc/plugin.dart`。
///
/// Note: 分批见 `.agents/notes/implemented/2026-11-06-p1b-batch2-catalog-family.md`。
library;

import '../model/plugins.dart' show PluginBundle, PluginRow;

/// 插件行 + 包清单。
///
/// 卸载按**包名**走，所以包清单不是插件行的派生品 —— 两张表都要。
final class PluginInventory {
  const PluginInventory({required this.rows, required this.bundles});

  final List<PluginRow> rows;
  final List<PluginBundle> bundles;
}
