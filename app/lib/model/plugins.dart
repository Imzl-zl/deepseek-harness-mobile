/// 插件清单与启停的线上形状（契约 §5.7 的 `plugin.list` / `plugin.setEnabled`）。
///
/// ## 字段以宿主的 `PluginInfo` 为准，手机上不另立一套
///
/// 行来自 `pluginManager.listPlugins()`（`packages/boot/plugin-manager/src/index.ts:439`），
/// 形状是 `PluginInventoryEntry & ({patchId} | {readOnlyReason})`
/// （`packages/boot/plugin-manager/src/types.ts:55`）。这里只做三件事：
/// 解析、决定"这一行能不能改"、把本地化文本挑成一档。
///
/// **挑语言是界面的事**（`LocalizedText` 是 `string | {en, [locale]}`，
/// `packages/util/package-manifest/src/types.ts:44`）：连接器把 `meta` 原样送过来，
/// 手机按自己的语言挑 —— 若两边各挑一次，就会出现"同一台电脑两种语言"。
///
/// ## "能不能改"只有一个判据
///
/// 宿主给 `patchId` 才是能被这一层改的行；给了 `readOnlyReason` 就是不能
/// （`management-required` = 只能从电脑的管理面改，`unaddressable` = 定位不到
/// profile 里的那一行）。**手机不猜**：没有 `patchId` 的开关就是禁用态，
/// 点它不会发请求（页面把原因写在行下方，而不是让用户点一个必然失败的开关）。
library;

/// 插件清单的一行。
class PluginRow {
  const PluginRow({
    required this.entryId,
    required this.moduleName,
    required this.enabled,
    this.fiberPhase = '',
    this.title = '',
    this.description = '',
    this.patchId = '',
    this.readOnlyReason = '',
  });

  /// 解析宿主的 `PluginInfo`；没有 `entryId` 就整行不要（认不出、也点不动）。
  static PluginRow? fromWire(Object? row) {
    if (row is! Map) return null;
    final entryId = row['entryId'];
    if (entryId is! String || entryId.isEmpty) return null;
    final moduleName = row['moduleName'];
    final fiberPhase = row['fiberPhase'];
    final patchId = row['patchId'];
    final readOnlyReason = row['readOnlyReason'];
    final meta = row['meta'];
    return PluginRow(
      entryId: entryId,
      moduleName: moduleName is String ? moduleName : '',
      enabled: row['enabled'] == true,
      fiberPhase: fiberPhase is String ? fiberPhase : '',
      title: localizedTextOf(meta is Map ? meta['title'] : null),
      description: localizedTextOf(meta is Map ? meta['description'] : null),
      patchId: patchId is String ? patchId : '',
      readOnlyReason: readOnlyReason is String ? readOnlyReason : '',
    );
  }

  /// 宿主的行 id（启停请求里的 `id`，就是它）。
  final String entryId;

  /// 模块名（`@deepseek-ai/dsh-tool-bash` 这种）—— 没有展示名时退回它。
  final String moduleName;

  /// 此刻是否启用（宿主 `PluginInfo.enabled`）。
  final bool enabled;

  /// 加载器的 fiber 阶段（宿主的原值；手机只在"停用但阶段不是空闲"时用它解释）。
  final String fiberPhase;

  /// 展示名（`meta.title` 挑出来的一档；空 = 宿主没给）。
  final String title;

  /// 展示说明（`meta.description`）。
  final String description;

  /// 宿主给的 profile patch 行 id（**有它才说明这一行能被改**）。
  final String patchId;

  /// 不能改的原因（`management-required` / `unaddressable`）。
  final String readOnlyReason;

  /// 启停成功后把这一行的状态换成**宿主回读的值**（其余字段一个不动）。
  PluginRow withEnabled(bool next) => PluginRow(
    entryId: entryId,
    moduleName: moduleName,
    enabled: next,
    fiberPhase: fiberPhase,
    title: title,
    description: description,
    patchId: patchId,
    readOnlyReason: readOnlyReason,
  );

  /// 能不能从这里启停。**判据只有一条**：宿主给了 `patchId` 且没给只读原因。
  bool get canToggle => patchId.isNotEmpty && readOnlyReason.isEmpty;

  /// 列表里那一行的主标题：展示名优先，否则模块名（不编一个名字）。
  String get displayName => title.isNotEmpty ? title : moduleName;

  /// 只读原因的人话。**这是显示映射，不是把宿主的字段翻译掉** ——
  /// 原始值仍保留在 [readOnlyReason] 里。
  String get readOnlyHint => switch (readOnlyReason) {
    'management-required' => '只能在电脑上改',
    'unaddressable' => '定位不到它的 profile 行',
    '' => '',
    _ => '不能在这里改',
  };
}

/// 一次启停的回执（宿主 `ChangeResult` 里手机用得上的那几个字段）。
class PluginToggleOutcome {
  const PluginToggleOutcome({
    required this.entryId,
    required this.enabled,
    this.application = '',
    this.restartReason = '',
  });

  /// 改的是哪一行。
  final String entryId;

  /// **回读后的**真实状态（不是我们请求的那个值 —— `overridden` 时两者不同）。
  final bool enabled;

  /// 宿主的应用结论（`applied` / `restart-required` / `overridden` / `failed` / `cancelled`）。
  final String application;

  /// `restart-required` 的原因（宿主的 `RestartReason`）。
  final String restartReason;

  /// 界面上那句话（**只解释宿主的结论**，不发明新的状态）。
  String get notice => switch (application) {
    'applied' => '',
    'restart-required' => '已保存，重启电脑侧 DSH 后生效',
    'overridden' => '被更高优先级的配置盖住了：这一行仍是${enabled ? '启用' : '停用'}',
    'failed' => '电脑侧报告这次改动失败',
    'cancelled' => '这次改动被取消了',
    '' => '',
    _ => '电脑侧回了未知结论：$application',
  };
}

/// 把宿主的 `LocalizedText`（`string | {en, [locale]}`）挑成一档。
///
/// 顺序：本身就是字符串 → `zh` → `en` → 任何一档。**没有就空串**
/// （调用方退回模块名，不编一个标题）。
String localizedTextOf(Object? value) {
  if (value is String) return value;
  if (value is! Map) return '';
  final zh = value['zh'];
  if (zh is String && zh.isNotEmpty) return zh;
  final en = value['en'];
  if (en is String && en.isNotEmpty) return en;
  for (final candidate in value.values) {
    if (candidate is String && candidate.isNotEmpty) return candidate;
  }
  return '';
}
