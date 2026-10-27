/// 模型目录（DSH `session/modelCatalog` 的**真形状**解析）。
///
/// ## 为什么必须有这个文件（2026-10-17 真机 bug）
///
/// 手机侧原来把目录解析成 `List<{provider, models:[{id}]}>` —— 一个**臆想的形状**：
/// 连接器原样过线的是 DSH `buildModelCatalog` 的返回值
/// （`packages/api/session-controller/src/catalog.ts:20-72`）：
///
/// ```ts
/// {
///   default: { provider, model, reasoningEffort? },
///   routableProviders: string[],
///   groups: [{ id, name, models: [{ id, name, description?, reasoning? }] }],
///   failures: [{ id, name, message }],
/// }
/// ```
///
/// 顶层是**对象**不是数组，于是 `catalog is! List` 直接静默返回 ——
/// `modelCatalog` 恒为 null，模型 picker 永远说"拿不到目录"。
/// 而单测全绿：测试替身给的正是那个臆想形状（`model_switch_test.dart` 旧用例）。
/// **替身复现的不是真形状，它证明的就是别的东西。**
///
/// 连接器自己的夹具（`connector/tests/models-face.test.ts` 的 `CATALOG`）
/// 从头到尾都是真形状 —— 两边各测各的，中间那一跳没人测。
///
/// Note: 为什么必须按这个形状解析（而不是旧的那个臆想 List 形状）——
/// 见 .agents/notes/implemented/2026-10-17-model-catalog-real-shape-and-effort.md
library;

import 'chat_item.dart' show ModelRef;

/// 一个可选项的推理等级（DSH `ModelReasoningEffort`：`{id, name, description?}`）。
class ModelEffort {
  const ModelEffort({required this.id, required this.name, this.description});

  final String id;

  /// 展示名（`High` / `中等`…）。没有就退到 id。
  final String name;
  final String? description;
}

/// 一个模型的推理档（DSH `ModelReasoning`）。
///
/// `defaultEffort` 为 null 时 Web 才提供"默认(Provider default)"那一项
/// （`ui-model-selection/src/client/ModelSelect.tsx:129-140`）。
class ModelReasoning {
  const ModelReasoning({required this.efforts, this.defaultEffort});

  final List<ModelEffort> efforts;
  final String? defaultEffort;

  /// 当前生效的等级（选择里带了用它，没带退到 provider 默认）。
  String? effectiveEffortOf(String? selected) => selected ?? defaultEffort;
}

/// 目录里的一个模型（DSH 的 catalog entry：`{id, name, description?, reasoning?}`）。
class ModelCatalogEntry {
  const ModelCatalogEntry({
    required this.id,
    required this.name,
    this.description,
    this.reasoning,
  });

  final String id;

  /// 展示名（`DeepSeek-V41-Flash`）。**没有才退到 id** —— 与 Web 的
  /// `currentChoice?.model.name ?? t('trigger.fallback')` 同一条链。
  final String name;
  final String? description;
  final ModelReasoning? reasoning;

  /// 界面上显示的名字。
  String get displayName => name.isNotEmpty ? name : id;
}

/// 一个 provider 分组（DSH `ModelProviderGroup`：`{id, name, models}`）。
class ModelProviderGroup {
  const ModelProviderGroup({
    required this.id,
    required this.name,
    required this.models,
  });

  final String id;
  final String name;
  final List<ModelCatalogEntry> models;
}

/// 一个拉取失败的 provider（DSH `ModelCatalogFailure`）。
///
/// **必须显示**：静默丢掉它 = "这个 provider 的 key 没配"在手机上毫无痕迹，
/// 而用户看到的是"我的 provider 不见了"。
class ModelCatalogFailure {
  const ModelCatalogFailure({
    required this.id,
    required this.name,
    required this.message,
  });

  final String id;
  final String name;
  final String message;
}

/// 整份目录（DSH `ModelCatalog`）。
class ModelCatalog {
  const ModelCatalog({
    required this.defaultSelection,
    required this.routableProviders,
    required this.groups,
    required this.failures,
  });

  /// 部署默认（未配置会话用的那个）。
  ///
  /// 用 [ModelRef] 而不是 `(provider, model)` 记录：DSH 的 `default` 就是**整个选择**
  /// （`api/session-controller/src/catalog.ts:66-71` 展开 `defaultSelection`，含
  /// `reasoningEffort`），丢了等级就得"选过一次才显示"。
  final ModelRef defaultSelection;
  final List<String> routableProviders;
  final List<ModelProviderGroup> groups;
  final List<ModelCatalogFailure> failures;

  /// 全部模型（摊平，按分组顺序）。
  List<ModelCatalogEntry> get allEntries => [
    for (final group in groups) ...group.models,
  ];

  /// 按 (provider, model) 找一项；没有就是 null。
  ModelCatalogEntry? entryOf({
    required String provider,
    required String model,
  }) {
    for (final group in groups) {
      if (group.id != provider) continue;
      for (final entry in group.models) {
        if (entry.id == model) return entry;
      }
    }
    return null;
  }

  /// 某个 (provider, model) 的展示名；目录里没有就退到 model id 本身。
  String displayNameOf({required String provider, required String model}) =>
      entryOf(provider: provider, model: model)?.displayName ?? model;

  /// 某个 (provider, model) 在给定 effort 下的展示名；目录里没有就退到 effort id。
  ///
  /// 与 Web 的 `effortLabel` 同一条链（`ModelSelect.tsx:122-128`）：
  /// 生效等级 → efforts 里找 name → 找不到用 id 本身。
  String effortNameOf({
    required String provider,
    required String model,
    required String? effort,
  }) {
    final reasoning = entryOf(provider: provider, model: model)?.reasoning;
    if (reasoning == null) return effort ?? '';
    final effective = reasoning.effectiveEffortOf(effort);
    if (effective == null) return '';
    for (final level in reasoning.efforts) {
      if (level.id == effective) return level.name;
    }
    return effective;
  }
}

/// 解析 `session.modelCatalog` 的应答（`{available, catalog}`）。
///
/// **认不出就给 null**：`available` 不为 true、`catalog` 不是对象、或分组形状
/// 不对，都统一成"没有目录"—— 界面据此说"拿不到目录"，而不是摆一个空列表
/// （空列表会被读成"没有可用模型"，而真实原因可能是 key 没配）。
ModelCatalog? parseModelCatalog(Object? raw) {
  if (raw is! Map) return null;
  if (raw['available'] != true) return null;
  return parseModelCatalogValue(raw['catalog']);
}

/// 解析目录本体（DSH `ModelCatalog` 的形状）。
///
/// 逐字段转型、**不整体 cast**：畸形数据（键不是字符串、models 不是数组）
/// 要么跳过那一项，要么整份作废 —— 两者都比把畸形带进界面好。
ModelCatalog? parseModelCatalogValue(Object? raw) {
  if (raw is! Map) return null;
  final groups = <ModelProviderGroup>[];
  final rawGroups = raw['groups'];
  if (rawGroups is List) {
    for (final group in rawGroups) {
      if (group is! Map) continue;
      final id = group['id'];
      final name = group['name'];
      if (id is! String || id.isEmpty) continue;
      final models = <ModelCatalogEntry>[];
      final rawModels = group['models'];
      if (rawModels is List) {
        for (final entry in rawModels) {
          if (entry is! Map) continue;
          final modelId = entry['id'];
          if (modelId is! String || modelId.isEmpty) continue;
          models.add(
            ModelCatalogEntry(
              id: modelId,
              // `name` 缺省时留空串，由 `displayName` 退到 id（不在这里猜）。
              name: entry['name'] is String ? entry['name'] as String : '',
              description: entry['description'] is String
                  ? entry['description'] as String
                  : null,
              reasoning: _reasoningOf(entry['reasoning']),
            ),
          );
        }
      }
      // 空分组不进目录：一个"有组无模型"的行在picker 里只是一个空标题。
      if (models.isEmpty) continue;
      groups.add(
        ModelProviderGroup(
          id: id,
          name: name is String && name.isNotEmpty ? name : id,
          models: models,
        ),
      );
    }
  }
  final failures = <ModelCatalogFailure>[];
  final rawFailures = raw['failures'];
  if (rawFailures is List) {
    for (final failure in rawFailures) {
      if (failure is! Map) continue;
      final id = failure['id'];
      if (id is! String || id.isEmpty) continue;
      failures.add(
        ModelCatalogFailure(
          id: id,
          name: failure['name'] is String ? failure['name'] as String : id,
          message: failure['message'] is String
              ? failure['message'] as String
              : '',
        ),
      );
    }
  }
  if (groups.isEmpty) return null;
  final defaultRaw = raw['default'];
  final defaultProvider = defaultRaw is Map ? defaultRaw['provider'] : null;
  final defaultModel = defaultRaw is Map ? defaultRaw['model'] : null;
  final defaultEffort = defaultRaw is Map
      ? defaultRaw['reasoningEffort']
      : null;
  return ModelCatalog(
    defaultSelection: ModelRef(
      provider: defaultProvider is String ? defaultProvider : '',
      model: defaultModel is String ? defaultModel : '',
      reasoningEffort: defaultEffort is String && defaultEffort.isNotEmpty
          ? defaultEffort
          : null,
    ),
    routableProviders: (raw['routableProviders'] is List
        ? (raw['routableProviders'] as List).whereType<String>().toList()
        : const <String>[]),
    groups: groups,
    failures: failures,
  );
}

ModelReasoning? _reasoningOf(Object? raw) {
  if (raw is! Map) return null;
  final efforts = <ModelEffort>[];
  final rawEfforts = raw['efforts'];
  if (rawEfforts is List) {
    for (final effort in rawEfforts) {
      if (effort is! Map) continue;
      final id = effort['id'];
      if (id is! String || id.isEmpty) continue;
      efforts.add(
        ModelEffort(
          id: id,
          name: effort['name'] is String ? effort['name'] as String : id,
          description: effort['description'] is String
              ? effort['description'] as String
              : null,
        ),
      );
    }
  }
  if (efforts.isEmpty) return null;
  final defaultEffort = raw['defaultEffort'];
  return ModelReasoning(
    efforts: efforts,
    defaultEffort: defaultEffort is String && defaultEffort.isNotEmpty
        ? defaultEffort
        : null,
  );
}
