/// **斜杠命令面**（`command.execute`）的唯一入口。
///
/// 形状出处 `connector/src/handlers.ts:1122-1145`：
/// 参数 `{sid, line}`（带幂等键），应答 `{matched, execution?: {result: {kind, text}}}`。
///
/// **这个回执形状与 `permission.switch` 逐字相同**（两者都是宿主的 `CommandRunView`），
/// 所以解码器只有一个：[readCommandOutcome]。`wire/rpc/permission.dart` 也用它 ——
/// 同一个形状两个方法，**一个读者**。
///
/// `matched: false` 是**合法应答**：电脑侧没有这条命令（DSH 对认不出的命令回 `undefined`），
/// 手机据此按 Web 的输入流水线退成普通消息（`machine.ts:170-175`）。那不是形状错。
///
/// Note: 布局与批次见 `.agents/notes/proposed/2026-10-25-wire-rpc-layer-layout.md`。
library;

import '../../core/sync_client.dart';
import '../../model/command.dart' show CommandOutcome, parseCommandOutcome;
import '../reading.dart';

/// 消费方拿齐"三态内核 + 命令面解码"。
export '../reading.dart';

const String _kExecute = 'command.execute';

/// 跑一条斜杠命令。
///
/// 回执认不出 ⇒ `null` + 计数一次（调用方**如实报错**，不把"读不懂"当成功）。
Future<CommandOutcome?> executeCommand(
  SyncClient client, {
  required String sid,
  required String line,
  required String requestId,
}) async {
  final result = await client.call<Object?>(_kExecute, {
    'sid': sid,
    'line': line,
  }, requestId: requestId);
  return valueOrReport(readCommandOutcome(result), _kExecute);
}

/// `{matched, execution?}` → [CommandOutcome]。
///
/// [method] 只用于计数/打印时点名（`command.execute` / `permission.switch` 共用这一份）。
WireReading<CommandOutcome> readCommandOutcome(
  Object? result, {
  String method = _kExecute,
}) {
  final outcome = parseCommandOutcome(result);
  if (outcome == null) {
    return WireBad('应答不是 {matched, execution?}（`$method`）');
  }
  return WireOk(outcome);
}
