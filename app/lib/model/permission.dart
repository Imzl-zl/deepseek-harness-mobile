/// 权限预设：电脑侧的真目录 + 当前档位，以及手机上的展示映射。
///
/// ## 为什么名单必须从电脑侧取
///
/// 手机上曾经是**三档手抄**（`ui/dsh_composer.dart` 的 `AccessMode` 三个枚举值），
/// 点完只改本地字段。而 DSH 的预设表是**部署可配的**
/// （`packages/bundle/base/cordis.patch.yml:262-271` 配了 `read-only` /
/// `workspace-write` / `danger-full-access` 三个）：电脑上加一个预设、
/// 改一个名字，手抄的那份就对不上了。所以清单走
/// `permission.catalog`（连接器的 `@Remote('catalog')` 透传，
/// `packages/interaction/permission-presets/src/index.ts:292`），
/// 本文件只留"已知键怎么画"的展示映射。
///
/// ## 当前档位不在这里读
///
/// 它在 `permissions` 投影的 `{currentValue}`
/// （`permission-presets/src/index.ts:237-244`，wire view 在 `:243`），
/// 随 `session.projections` 一起到手机（`AppModel.permissionValue`）。
/// **同一个状态只有一个来源** —— 再开一个读面就会有两份可能对不上的真值。
///
/// ## `custom` 是显示态，不是目标
///
/// DSH 在旋钮值不匹配任何预设时给出 `custom`
/// （`derive`，`permission-presets/src/index.ts:348-361`），
/// 而它**不在 catalog 的 options 里**（`catalog()` 只列可切目标）。
/// 所以手机可以显示"当前是 custom"，但列表里不会有这一项可点。
///
/// 取舍（为何是两个方法、为何不放通用的 `command.execute`、为何风险门按预设键比对）
/// 见 `.agents/notes/implemented/2026-10-15-permission-switch-through-dsh-two-doors.md`。
library;

import '../data/projection.dart';

/// 一个可切预设（DSH 的 `PresetOption`，`permission-presets/src/types.ts:13-20`）。
class PermissionPreset {
  const PermissionPreset({
    required this.value,
    required this.name,
    this.description,
  });

  /// 稳定的预设键：配置项键、活的 `auto`、或派生的 `custom`。
  final String value;

  /// 展示名（host 给的；缺省时等于键，`optionOf` 在 `:384-390` 保证）。
  final String name;

  /// 一句话说明；没有配置就没有。
  final String? description;

  /// 是否需要风险确认门（§7.10）。
  ///
  /// **口径照 Web 客户端**：`danger-full-access` 与 `auto` 各带一道显式确认
  /// （`packages/client/ui-permission-presets/src/client/presentation.ts:4,7`
  /// 的两个常量，`src/client/index.ts:94-104` 挂确认文案）。
  bool get needsRiskGate => value == fullAccessPreset || value == autoPreset;
}

/// 预设目录（DSH 的 `PermissionCatalog`，`types.ts:26-33`）。
class PermissionCatalog {
  const PermissionCatalog({
    required this.options,
    required this.defaultOptions,
    required this.defaultPreset,
  });

  /// 全部可切预设（贡献顺序）。
  final List<PermissionPreset> options;

  /// 有资格当"以后新建会话默认值"的预设（不含 `auto`）。
  final List<PermissionPreset> defaultOptions;

  /// 配置缺省时的有效默认值。
  final String defaultPreset;

  /// 当前值对应的那一项；认不出（`custom`、或目录里没有的键）时返回 `null`。
  ///
  /// **不猜**：返回 `null` 时界面显示电脑侧给的原始值，而不是硬套一个名字。
  PermissionPreset? optionOf(String value) {
    for (final option in options) {
      if (option.value == value) return option;
    }
    return null;
  }
}

/// 完全权限的预设键（Web 的 `FULL_ACCESS_PRESET`，`presentation.ts:4`）。
const String fullAccessPreset = 'danger-full-access';

/// 实验性自动审查的预设键（Web 的 `AUTO_REVIEW_PRESET`，`presentation.ts:7`）。
const String autoPreset = 'auto';

/// 派生的"不匹配任何预设"显示态（`permission-presets/src/index.ts:79` 的 `CUSTOM_PRESET`）。
const String customPreset = 'custom';

/// 解 `permission.catalog` 的应答：`{available, catalog}`。
///
/// **认不出返回 `null`，不造空目录** —— 空目录会被读成"这台电脑没有预设"，
/// 而真实原因可能是 `permissionPresets` 服务不在、或应答形状变了。
/// 两者对用户是不同的事（一个是去电脑上配，一个是查连接）。
PermissionCatalog? parsePermissionCatalog(Object? raw) {
  if (raw is! Map) return null;
  if (raw['available'] != true) return null;
  final catalog = raw['catalog'];
  if (catalog is! Map) return null;
  final options = _presetsOf(catalog['options']);
  if (options == null) return null;
  final defaultOptions = _presetsOf(catalog['defaultOptions']);
  if (defaultOptions == null) return null;
  final defaultPreset = catalog['defaultPreset'];
  if (defaultPreset is! String || defaultPreset.isEmpty) return null;
  return PermissionCatalog(
    options: options,
    defaultOptions: defaultOptions,
    defaultPreset: defaultPreset,
  );
}

/// 解一组预设选项。缺字段的项**跳过**，整组不是数组时返回 `null`。
List<PermissionPreset>? _presetsOf(Object? raw) {
  if (raw is! List) return null;
  final out = <PermissionPreset>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final value = entry['value'];
    final name = entry['name'];
    // 缺 value 就没办法把它作为切换目标发回去（`permission.switch` 要它）；
    // 缺 name 就没什么可显示的。两种都跳过这一项，而不是摆一行空壳。
    if (value is! String || value.isEmpty) continue;
    if (name is! String || name.isEmpty) continue;
    final description = entry['description'];
    out.add(
      PermissionPreset(
        value: value,
        name: name,
        description: description is String && description.isNotEmpty
            ? description
            : null,
      ),
    );
  }
  return out;
}

/// `permissions` 投影的线格式（`{currentValue}`，`permission-presets/src/index.ts:243`）。
///
/// 从 `session.projections` 的值映射里取。**认不出返回 `null`**：
/// 投影没注册（这台电脑没装权限插件）与"这一帧没有这个键"是同一件事，
/// 而两者的正确表现都是"不知道当前档位"—— 界面显示空态，不猜一个。
String? parsePermissionValue(Object? projections) {
  final raw = fieldOf(projections, 'permissions');
  if (raw is! Map) return null;
  final value = raw['currentValue'];
  return value is String && value.isNotEmpty ? value : null;
}

/// 一次切换的结论（连接器 `permission.switch` 的应答）。
class PermissionSwitch {
  const PermissionSwitch({required this.matched, this.kind, this.text});

  /// 电脑上有没有 `/permission` 这个命令。
  ///
  /// `false` 的语义是 DSH 的 `commands.execute` 回 `undefined`
  /// （`interaction/commands/src/index.ts:366-370`：语法或名字没解析出来）——
  /// 与 Web 客户端的推导逐字一致（`session-controller/.../session.ts:390`）。
  final bool matched;

  /// DSH 的 `result.kind`：`success` / `error`。
  final String? kind;

  /// DSH 的 `result.text`。**原文照显，不翻译** ——
  /// `unknown preset "yolo" (available: …)` 这种话是电脑侧权威的措辞，
  /// 自己抄一份就会在 DSH 改词时静默分叉。
  final String? text;

  /// 这次切换在电脑侧成功了（命令在、且 DSH 回 success）。
  bool get succeeded => matched && kind == 'success';
}

/// 解 `permission.switch` 的应答：`{matched, execution?}`。
///
/// **认不出返回 `null`**（调用方按失败留声），不猜一个"成功"。
PermissionSwitch? parsePermissionSwitch(Object? raw) {
  if (raw is! Map) return null;
  final matched = raw['matched'];
  if (matched is! bool) return null;
  final execution = raw['execution'];
  if (!matched) return const PermissionSwitch(matched: false);
  if (execution is! Map) return null;
  final result = execution['result'];
  if (result is! Map) return null;
  final kind = result['kind'];
  final text = result['text'];
  return PermissionSwitch(
    matched: true,
    kind: kind is String ? kind : null,
    text: text is String && text.isNotEmpty ? text : null,
  );
}

/// DSH 内置三个预设键 → 手机上的图标与文案。
///
/// **这不是预设清单**（清单见 [PermissionCatalog]），只是"已知键怎么画"。
/// 认不出的键照样显示（用 host 给的 `name`），只是没有专用图标与本地文案。
class KnownPreset {
  const KnownPreset(this.value, this.icon, this.label);

  final String value;

  /// DSH 图标名（`theme/dsh_icons.dart`）。只存名字：`model/` 不认识视觉层。
  final String icon;

  /// 本地文案（照 `docs/design-and-tech-plan.md` 的三档措辞）。
  final String label;

  static const KnownPreset readOnly = KnownPreset(
    'read-only',
    'permissionReadOnly',
    '只读',
  );
  static const KnownPreset workspaceWrite = KnownPreset(
    'workspace-write',
    'permissionWorkspaceWrite',
    '工作区内可改',
  );
  static const KnownPreset fullAccess = KnownPreset(
    fullAccessPreset,
    'permissionFullAccess',
    '完全权限',
  );

  static const List<KnownPreset> _all = [readOnly, workspaceWrite, fullAccess];

  /// 值 → 已知预设；认不出返回 `null`。
  static KnownPreset? of(String value) {
    for (final known in _all) {
      if (known.value == value) return known;
    }
    return null;
  }
}

/// 输入栏那个 34px 权限 chip 的展示值（图标 + 文案 + 是否告警色）。
class PermissionChip {
  const PermissionChip({
    required this.icon,
    required this.label,
    required this.warn,
  });

  final String icon;
  final String label;
  final bool warn;
}

/// 中性的权限图标：当前档位认不出来时用它。
///
/// **不硬套一个内置档位** —— 那把"电脑上是另一个预设"显示成"是只读"，
/// 比显示一个中性图标糟得多。DSH 图标集里没有"未知权限"，
/// `shield` 是三个 `permission*` 之外最接近的那个。
const String neutralPermissionIcon = 'shield';

/// 预设的展示名。口径照 Web 的 `displayPermissionPreset`
/// （`packages/client/ui-permission-presets/src/client/presentation.ts:44-53`）：
/// 内置键、且 host 没有另给标签时用本地文案，否则用 host 的标签。
///
/// "host 没有另给标签"的判据是 `name === value`：DSH 的 `optionOf`
/// （`permission-presets/src/index.ts:384-390`）在配置没写 `name` 时
/// **回显键本身**，而 `read-only` 这种原始键对用户不可读。
/// 部署真配了 `name` 时它优先 —— 那是部署自己的措辞。
String displayPresetName(PermissionPreset option) {
  final known = KnownPreset.of(option.value);
  if (known != null && option.name == option.value) return known.label;
  return option.name;
}

/// 当前档位 → chip 展示值。
///
/// - 认识的内置键：专用图标 + 本地文案；
/// - 不认识的键（`auto` / `custom` / 部署自建的预设）：中性图标 + host 给的 `name`；
/// - 拿不到当前值（投影没这个键）：中性图标 + `未知`。
///
/// 告警色口径照 Web 与设计文档：`danger-full-access` 与 `auto`
/// （`ui-permission-presets/src/client/presentation.ts:4,7`；
/// `docs/design-and-tech-plan.md` §7.2"完全权限 / Auto review 用告警色"）。
PermissionChip permissionChipOf({
  required String? value,
  required PermissionCatalog? catalog,
}) {
  if (value == null) {
    return const PermissionChip(
      icon: neutralPermissionIcon,
      label: '未知',
      warn: false,
    );
  }
  final warn = value == fullAccessPreset || value == autoPreset;
  final known = KnownPreset.of(value);
  if (known != null) {
    return PermissionChip(icon: known.icon, label: known.label, warn: warn);
  }
  final option = catalog?.optionOf(value);
  return PermissionChip(
    icon: neutralPermissionIcon,
    label: option == null ? value : displayPresetName(option),
    warn: warn,
  );
}
