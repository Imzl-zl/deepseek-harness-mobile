/// Agent 预设（DSH 界面上的「标准模式 / PTC 模式 / 极简模式 / 创造模式」）。
///
/// 名字与描述的解析规则**逐字移植 DSH**：内置预设走本地化字典，
/// **用户自建的元数据永不翻译** —— 判据是 `isBuiltInPreset`
/// （`packages/preset/agent-preset-registry/src/display.ts:53-55`：没有自定义 `name`
/// 且 id 在内置表里），文案表在
/// `packages/client/ui-agent-preset/src/client/locales.ts:95-102`。
///
/// 目录本身来自 `agentPresets.list`（连接器 `dsh/agent-presets.ts`），
/// **不在这里手抄一份名单**：部署可以再声明自己的预设。
library;

/// 一个可选的预设（`AgentPresetRow` 里**能用的**那些）。
class AgentPresetOption {
  const AgentPresetOption({required this.id, this.name, this.description});

  /// 稳定标识（也是显示名的兜底）。
  final String id;

  /// 预设自己发布的显示名。**内置的不发布**（`display.ts:48-49` 的注释：
  /// "A shipped preset publishes no `name`"）。
  final String? name;

  /// 一句话说明它适合干什么。
  final String? description;

  /// 是不是内置四档之一。判据逐字移植 `isBuiltInPreset`（`display.ts:53-55`）。
  bool get isBuiltIn => name == null && kBuiltInPresetCopy.containsKey(id);

  /// 显示名：内置走本地化字典，自建走它自己的 `name`，都没有就退回 id
  /// （`presetDisplayText`，`display.ts:63-73`）。
  String get displayName => _displayText(this).name;

  /// 显示描述（没有就是 `null`，界面照 Web 显示「暂无描述。」）。
  String? get displayDescription => _displayText(this).description;
}

/// 内置四档的本地化文案（`ui-agent-preset/src/client/locales.ts:95-102`，逐字）。
///
/// **它是"内置"这个判据的一半**（见 [AgentPresetOption.isBuiltIn]），
/// 所以不能删；但**它不是可选名单** —— 名单只从电脑侧来。
const Map<String, ({String name, String description})> kBuiltInPresetCopy = {
  'standard': (
    name: '标准模式',
    description: '处理代码、文件和资料，适合大多数任务。Agent 会按需使用检索、编辑和终端等工具。',
  ),
  'ptc': (
    name: 'PTC 模式',
    description: '包含标准模式的所有能力，更适合批量调用工具，并对结果进行筛选、整理、去重、统计或汇总的任务。',
  ),
  'minimal': (
    name: '极简模式',
    description: 'Agent 使用终端和图片读取工具，并支持上下文压缩，适合测试和对比其基础表现。',
  ),
  'cordis': (
    name: '创造模式',
    description: '用对话定制 DSH：让 Agent 编写插件，添加新功能或界面；也能组合工具和提示词，创建自己的模式。',
  ),
};

/// 内置预设没有描述时的兜底文案（`locales.ts:106` 的 `noDescription`）。
const String kNoPresetDescription = '暂无描述。';

({String name, String? description}) _displayText(AgentPresetOption preset) {
  if (preset.isBuiltIn) {
    final copy = kBuiltInPresetCopy[preset.id]!;
    return (name: copy.name, description: copy.description);
  }
  return (name: preset.name ?? preset.id, description: preset.description);
}

/// 电脑侧给的预设目录（`agentPresets.list` 的应答）。
class AgentPresetRoster {
  const AgentPresetRoster({
    required this.available,
    required this.options,
    this.defaultId,
  });

  /// 电脑侧说"能拿到目录"吗。
  ///
  /// `false` 是**明说**，不是"没有预设"：连接器拿不到 `agentPresets` 服务时回
  /// `{available:false}`（与 `permission.catalog` 同一条纪律）。界面据此说
  /// 「拿不到预设目录」，而不是摆一个空选择器让用户以为这台电脑没有预设。
  final bool available;

  /// 可选的预设（**已按 DSH 的客户端规则滤掉 broken 的**，见 [parseAgentPresetRoster]）。
  final List<AgentPresetOption> options;

  /// 部署的默认预设（roster 行里 `isDefault: true` 的那个）；没有就是 `null`。
  ///
  /// 用它兜底会话的 `agentPreset` 投影为空的情形 —— DSH 的 hero chip 打开的也是
  /// "staged 的选择，初始就是部署默认"（`ui-agent-preset/src/client/AgentPresetSeat.tsx:11`）。
  final String? defaultId;

  /// 某个 id 的显示名；不认识就回 id 本身（照 `AgentPresetLabel.tsx:60-65`：
  /// 目录里找不到时**直接显示 id**，不隐藏也不猜）。
  String displayNameOf(String id) {
    for (final option in options) {
      if (option.id == id) return option.displayName;
    }
    return id;
  }

  /// 认不认识这个 id（用来决定那枚 chip 显示名字还是 id）。
  bool has(String id) => options.any((option) => option.id == id);
}

/// 解析 `agentPresets.list` 的应答。
///
/// **过滤 `broken` 的那一步在这里，不在连接器**：那是客户端规则 ——
/// Web 的 `presetOptions` 只留 `broken === undefined` 的项
/// （`ui-agent-preset/src/client/settings-store.ts:119-127`），而设置页的管理区
/// 却要把 broken 的也列出来（同文件 `:109-110`）。手机这一轮要的是**选择器**，
/// 所以照 `presetOptions` 过滤；连接器整包透传（它不该替这一屏做决定）。
///
/// 形状认不出就回 `available: false`：**不猜**。
AgentPresetRoster parseAgentPresetRoster(Object? result) {
  if (result is! Map) {
    return const AgentPresetRoster(available: false, options: []);
  }
  if (result['available'] != true) {
    return const AgentPresetRoster(available: false, options: []);
  }
  final roster = result['roster'];
  if (roster is! Map) {
    return const AgentPresetRoster(available: false, options: []);
  }
  final rows = roster['presets'];
  if (rows is! List) {
    return const AgentPresetRoster(available: false, options: []);
  }
  final options = <AgentPresetOption>[];
  String? defaultId;
  for (final row in rows) {
    if (row is! Map) continue;
    // `broken` 有值 = 这个预设组合不起来（DSH 只在失败时给这个字段）。
    // 选择器不列它；管理页才列（那条路手机这一轮不做）。
    if (row['broken'] != null) continue;
    final id = row['id'];
    if (id is! String || id.isEmpty) continue;
    if (row['isDefault'] == true) defaultId = id;
    final name = row['name'];
    final description = row['description'];
    options.add(
      AgentPresetOption(
        id: id,
        name: name is String && name.isNotEmpty ? name : null,
        description: description is String && description.isNotEmpty
            ? description
            : null,
      ),
    );
  }
  return AgentPresetRoster(
    available: true,
    options: options,
    defaultId: defaultId,
  );
}

/// 从 `session.projections` 的信封里取当前会话的 `agentPreset`。
///
/// 投影的 `wire view` 就是 `string | null`
/// （`packages/preset/agent-preset-registry/src/session.ts:35-44` 的
/// `viewSchema = z.union([z.string(), z.null()])`；Web 的读法见
/// `ui-agent-preset/src/client/AgentPresetLabel.tsx:46-49`）。
/// **`null` 表示这个会话没有记过预设**（老会话 / 这台电脑没有预设服务），
/// 界面据此显示 id 或退回默认，不猜一个档。
String? parseAgentPresetValue(Map<String, Object?>? projections) {
  final raw = projections?['agentPreset'];
  return raw is String && raw.isNotEmpty ? raw : null;
}
