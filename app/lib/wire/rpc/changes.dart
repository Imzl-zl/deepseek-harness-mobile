/// **改动面**（`file.changes`，只读）的唯一入口。
///
/// 形状出处 `connector/src/handlers.ts` 的 `file.changes`：
/// `{summary: {turn, files, total, added, deleted} | null}`。
///
/// ## `summary: null` 是一个**有效应答**
///
/// 它说"电脑侧没有这一轮的改动记录"（会话已释放 / 从没记录过）—— 桌面用 HTTP 404
/// 表达同一件事（`ui-deliverables/src/present-open.ts:131-139`）。
/// 所以这里**不把它当形状错**：`null` 原样交给调用方，卡片就不画。
/// 形状错（缺 `summary` 键、summary 不是对象 / 字段不齐）才走 [WireBad] + 计数。
///
/// Note: 为什么数据只来自桌面、手机不自己算 —— 见
/// `.agents/notes/proposed/2026-10-26-desktop-alignment-plan.md` 的批 B。
library;

import '../../core/sync_client.dart';
import '../../model/changes.dart' show ChangesSummary;
import '../../model/file_diff.dart' show FileDiff;
import '../fields.dart';
import '../reading.dart';

/// 消费方一次拿齐"三态内核 + 字段内核 + 改动面解码"。
export '../fields.dart';
export '../reading.dart';

const String _kChanges = 'file.changes';
const String _kDiff = 'file.diff';

/// 读取一个 `workspace/changes` 事件宣告的改动记录。
///
/// [seq] 是**事件序号**（不是路径）：宿主按 `seq` + 文件下标取比对，连接器也一样
/// （`workspace-changes/src/types.ts:88-96`）。
Future<ChangesSummary?> loadChangesSummary(
  SyncClient client, {
  required String sid,
  required int seq,
}) async {
  final result = await client.call<Object?>(_kChanges, {
    'sid': sid,
    'seq': seq,
  });
  // 显式给类型参数：`summary: null` 是有效值，推断成 `ChangesSummary` 会让它编译不过。
  return valueOrReport<ChangesSummary?>(readChangesSummary(result), _kChanges);
}

/// 读取一个改动文件的逐行比对。
///
/// [seq] 是 `workspace/changes` 事件的序号、[index] 是文件在 summary 里的下标 ——
/// **都不是路径**（宿主只认这两个坐标，`workspace-changes/src/types.ts:88-96`）。
Future<FileDiff?> loadFileDiff(
  SyncClient client, {
  required String sid,
  required int seq,
  required int index,
}) async {
  final result = await client.call<Object?>(_kDiff, {
    'sid': sid,
    'seq': seq,
    'index': index,
  });
  return valueOrReport<FileDiff?>(readFileDiff(result), _kDiff);
}

/// `file.diff` 的应答 `{diff}`；`diff: null` **是**有效值（电脑侧没有这条记录）。
WireReading<FileDiff?> readFileDiff(Object? result) {
  if (result is! Map) {
    return const WireBad('应答不是 {diff}（file.diff）');
  }
  if (!result.containsKey('diff')) {
    return const WireBad('应答里没有 diff 键（file.diff）');
  }
  final diff = result['diff'];
  if (diff == null) return const WireOk(null);
  return readObject(_kDiff, diff, (fields) {
    final parsed = FileDiff.fromWire(fields.map);
    if (parsed == null) {
      throw const WireFieldError('diff 认不出（file.diff）');
    }
    return parsed;
  });
}

/// `file.changes` 的应答 `{summary}`；`summary: null` **是**有效值。
WireReading<ChangesSummary?> readChangesSummary(Object? result) {
  if (result is! Map) {
    return const WireBad('应答不是 {summary}（file.changes）');
  }
  if (!result.containsKey('summary')) {
    return const WireBad('应答里没有 summary 键（file.changes）');
  }
  final summary = result['summary'];
  if (summary == null) return const WireOk(null);
  return readObject(_kChanges, summary, (fields) {
    final parsed = ChangesSummary.fromWire(fields.map);
    if (parsed == null) {
      throw const WireFieldError('summary 认不出（file.changes）');
    }
    return parsed;
  });
}
