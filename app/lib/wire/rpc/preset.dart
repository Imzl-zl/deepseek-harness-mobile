/// **Agent 预设面**（`agentPresets.list`）的唯一入口。
///
/// 形状出处 `connector/src/handlers.ts:1152-1158`：
/// `{available: false}` 或 `{available: true, roster: {presets: [...]}}`。
///
/// **`available: false` 不是形状错**：它是电脑侧的明说（"这台没有预设目录"）。
/// 界面据此说"拿不到预设目录"，而不是把"电脑侧没给"显示成"这台电脑一个预设都没有"
/// ——后者会让用户以为预设被删了。
///
/// **目录本体不进这个文件**：`roster.presets` 的逐项解析（`broken` 跳过、
/// `isDefault` 认默认、`name` / `description` 可空）在
/// `model/agent_preset.dart` 的 `parseAgentPresetRoster`（与 `parseTokenUsage` 同一条：
/// 值解析住 `model/`，`wire/` 只负责"从哪一层取"）。
///
/// 这里**只搬调用**（方法名与参数形状是协议知识）；`parseAgentPresetRoster`
/// 自己已经处理了 `available` 与 `roster` 两层，再造一个 envelope 断言是重复。
///
/// Note: 布局与批次见 `.agents/notes/implemented/2026-10-25-wire-rpc-layer-layout.md`。
library;

import '../../core/sync_client.dart';
import '../../model/agent_preset.dart'
    show AgentPresetRoster, parseAgentPresetRoster;

/// 方法名只在这里出现一次（`connector/src/handlers.ts:1152`）。
const String _kList = 'agentPresets.list';

/// 读一次预设目录。
///
/// 应答**从不抛**：`parseAgentPresetRoster` 对"不是对象 / `available` 不是 true /
/// `roster` 不是对象"一律回 `available: false`，界面据此说"拿不到目录"。
/// 所以这里不需要 `WireReading` —— 加一层只会把"电脑侧没给"改写成"我们读不懂"，
/// 而那两件事在界面上是同一句话。
Future<AgentPresetRoster> loadAgentPresets(SyncClient client) async {
  final result = await client.call<Object?>(_kList, const {});
  return parseAgentPresetRoster(result);
}
