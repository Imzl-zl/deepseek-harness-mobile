/// **子会话面**（`subagent.*`）的唯一入口。
///
/// 今天只有一条：`subagent.prompt` —— 给**可继续子会话**投递一条人写的消息。
///
/// ## 为什么它必须是独立方法（不能复用 `session.prompt`）
///
/// 对子会话直接调 `session.prompt` 会被宿主拒成
/// `internal: session "…" is owned by subagent routing`（2026-10-21 真机实测，
/// 手机上表现成一句「发送失败」）。宿主唯一的写入口是 `SubagentRuntime.prompt`
/// （`packages/subagent/subagent/src/index.ts:447`）——连接器把它暴露成
/// `subagent.prompt`（`connector/src/handlers.ts:804-830`）。
///
/// ## 应答不读
///
/// `{accepted}` 今天没有任何消费者（`sendSubagentPrompt` 直接 `call<void>`），
/// 所以这里**只搬调用**（方法名与参数形状是协议知识），不造 decoder ——
/// 造一个没人读的 decoder 等于给"我们校验过了"的假象。
///
/// Note: 布局与批次见 `.agents/notes/implemented/2026-10-25-wire-rpc-layer-layout.md`。
library;

import '../../core/sync_client.dart';

/// 方法名只在这里出现一次（`connector/src/handlers.ts:804`）。
const String _kPrompt = 'subagent.prompt';

/// 给可继续子会话发一条人写的消息。参数形状与 `session.prompt` 逐字相同
/// （`sid` + `content` + `mode` + 顶层 `requestId`，`connector/src/handlers.ts:804-830`）。
Future<void> sendSubagentPrompt(
  SyncClient client, {
  required String sid,
  required List<Object?> content,
  required String mode,
  required String requestId,
}) => client.call<void>(_kPrompt, {
  'sid': sid,
  'content': content,
  'mode': mode,
}, requestId: requestId);
