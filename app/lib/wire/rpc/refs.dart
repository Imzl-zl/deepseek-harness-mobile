/// **`@` 候选面**（`refs.files` / `refs.sessions`，只读）的唯一入口。
///
/// 形状出处 `connector/src/handlers.ts:1206-1230`：
/// `refs.files` → `{files: [...]}`、`refs.sessions` → `{sessions: [...]}`；
/// 参数 `{sid, query}`（`query` 可以是空串 —— 用户刚打完 `@` 时就是"这个目录下有什么"）。
///
/// **两个方法并发发一次**（面板一行里两种候选都要，串行只是多等一个往返），
/// 所以这里给的是两个 async 函数 + 一个把它们并起来的 [loadMentionCandidates]。
///
/// 行本体的解析（`path` / `kind` / `mention` / `label`）在 `model/mention.dart` 的
/// `AtCandidate.fromFileRow` / `fromSessionRow` —— **单独一行认不出就跳过那一行**，
/// 不计数：那可能是"这条候选的形状我们不认识"，而它的正确表现就是"不显示这一条"，
/// 不是"整次查询失败"。只有**信封**坏（`files` / `sessions` 不是数组）才 [WireBad]。
///
/// Note: 布局与批次见 `.agents/notes/proposed/2026-10-25-wire-rpc-layer-layout.md`。
library;

import '../../core/sync_client.dart';
import '../../model/mention.dart' show AtCandidate;
import '../reading.dart';

/// 消费方一次拿齐"三态内核 + 字段内核 + 候选面解码"。
export '../fields.dart';
export '../reading.dart';

const String _kFiles = 'refs.files';
const String _kSessions = 'refs.sessions';

/// 查文件 / 目录候选。
Future<List<AtCandidate>?> loadRefsFiles(
  SyncClient client, {
  required String sid,
  required String query,
}) async {
  final result = await client.call<Object?>(_kFiles, {
    'sid': sid,
    'query': query,
  });
  return valueOrReport(readRefsFiles(result), _kFiles);
}

/// 查跨会话引用候选。
Future<List<AtCandidate>?> loadRefsSessions(
  SyncClient client, {
  required String sid,
  required String query,
}) async {
  final result = await client.call<Object?>(_kSessions, {
    'sid': sid,
    'query': query,
  });
  return valueOrReport(readRefsSessions(result), _kSessions);
}

/// 一次查两种候选（**并发**：面板一行里两列都要）。
///
/// 任一侧读不出来 ⇒ 那一侧 `null`（调用方按"这一列没有"渲染），另一侧照常给。
Future<({List<AtCandidate>? files, List<AtCandidate>? sessions})>
loadMentionCandidates(
  SyncClient client, {
  required String sid,
  required String query,
}) async {
  final answers = await Future.wait<Object?>([
    loadRefsFiles(client, sid: sid, query: query),
    loadRefsSessions(client, sid: sid, query: query),
  ]);
  return (
    files: answers[0] as List<AtCandidate>?,
    sessions: answers[1] as List<AtCandidate>?,
  );
}

/// `refs.files` 的应答 `{files: [...]}`。
WireReading<List<AtCandidate>> readRefsFiles(Object? result) =>
    _candidatesOf(result, _kFiles, 'files', AtCandidate.fromFileRow);

/// `refs.sessions` 的应答 `{sessions: [...]}`。
WireReading<List<AtCandidate>> readRefsSessions(Object? result) =>
    _candidatesOf(result, _kSessions, 'sessions', AtCandidate.fromSessionRow);

WireReading<List<AtCandidate>> _candidatesOf(
  Object? result,
  String method,
  String key,
  AtCandidate? Function(Object? row) parse,
) {
  if (result is! Map) return WireBad('应答不是 {$key: [...]}（`$method`）');
  final rows = result[key];
  if (rows is! List) return WireBad('应答里没有 $key 数组（`$method`）');
  final out = <AtCandidate>[];
  for (final row in rows) {
    // 单独一行认不出就跳过：那是"这一条候选不认识"，不是"整次查询坏了"。
    final candidate = parse(row);
    if (candidate != null) out.add(candidate);
  }
  return WireOk(List<AtCandidate>.unmodifiable(out));
}
