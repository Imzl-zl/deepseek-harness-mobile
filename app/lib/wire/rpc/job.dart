/// **后台任务面**（`job.*`）的唯一入口。
///
/// 形状出处 `connector/src/handlers.ts`：
///
/// | 方法 | 应答 | 手机拿它做什么 |
/// |---|---|---|
/// | `job.list` `:1319-1330` | `{jobs: [{id, kind, label, status, startedAt, outputTotal, progress?, detail?, finishedAt?}]}` | 任务清单的一次性快照 |
/// | `job.follow` `:1483-1498` | `{from}`（宿主的起点） | **不读**：输出走 `job` 帧 |
/// | `job.unfollow` `:1500-1505` | `{stopped: bool}` | **不读** |
/// | `job.kill` `:1331-1339` | `{outcome: 'requested'|'already-finished'}` | 停任务的结论 |
///
/// `follow` / `unfollow` 是**只搬调用**：它们的作用在服务端（开/关一条流），
/// 应答里的数字对界面没有意义 —— 造一个没人读的 decoder 等于给"我们校验过了"的假象。
///
/// `job.list` 的行**不带 `sid`**（那次本来就知道是哪个会话）；`job` **帧**里的行才有
/// （连接器盖的，归桶靠它）。所以这里的行解码不声明 `sid`：帧路径由
/// `core/job.dart` 的 `parseJobFrame` 负责，两条路各自只有一个读者。
///
/// Note: 布局与批次见 `.agents/notes/implemented/2026-10-25-wire-rpc-layer-layout.md`。
library;

import '../../core/job.dart' show JobRow;
import '../../core/sync_client.dart';
import '../fields.dart';
import '../reading.dart';

/// 消费方一次拿齐"三态内核 + 字段内核 + 任务面解码"。
export '../fields.dart';
export '../reading.dart';

const String _kList = 'job.list';
const String _kFollow = 'job.follow';
const String _kUnfollow = 'job.unfollow';
const String _kKill = 'job.kill';

/// 拉一次任务清单（快照；后续变化走 `job` 帧的 `status`）。
Future<List<JobRow>?> loadJobList(
  SyncClient client, {
  required String sid,
}) async {
  final result = await client.call<Object?>(_kList, {'sid': sid});
  return valueOrReport(readJobList(result), _kList);
}

/// 订阅一个任务的输出流（**应答不读**：输出走 `job` 帧）。
Future<void> followJobOutput(
  SyncClient client, {
  required String sid,
  required String jobId,
}) => client.call<void>(_kFollow, {'sid': sid, 'jobId': jobId});

/// 退订（**应答不读**）。
Future<void> unfollowJobOutput(
  SyncClient client, {
  required String sid,
  required String jobId,
}) => client.call<void>(_kUnfollow, {'sid': sid, 'jobId': jobId});

/// 停一个任务：回宿主的结论（`requested` / `already-finished`）；认不出 ⇒ `null` + 计数。
Future<String?> killJob(
  SyncClient client, {
  required String sid,
  required String jobId,
}) async {
  final result = await client.call<Object?>(_kKill, {
    'sid': sid,
    'jobId': jobId,
  });
  return valueOrReport(readJobKillOutcome(result), _kKill);
}

// ---------------------------------------------------------------------------
// 纯解码
// ---------------------------------------------------------------------------

/// `job.list` 的应答 `{jobs: [...]}`。
///
/// 一行认不出就**跳过那一行**（少一个任务优于整个任务面板报错）；`jobs` 不是数组才是 [WireBad]。
WireReading<List<JobRow>> readJobList(Object? result) =>
    readObjectList(result, method: _kList, key: 'jobs', build: _jobRowOf);

/// `job.kill` 的应答 `{outcome}`。
WireReading<String> readJobKillOutcome(Object? result) => readObject(
  _kKill,
  result,
  (fields) => fields.requireNonEmptyString('outcome'),
);

/// 一行任务（`job.list` 的形状）。
///
/// **六个键是必填**：连接器无条件写出它们（`connector/src/dsh/jobs.ts:47-59`
/// 的 `toRow`，协议侧 `protocol/job-output.ts:54-67` 也声明为必填）。
/// 缺一个就是漂了 ⇒ 整行丢 + 计数，**不拿默认值兜** ——
/// `status ?? 'running'` 正是"任务永远转"的形态（2026-10-26 评审）。
/// `progress` / `detail` / `finishedAt` / `sid` 才是可选的（生产侧按条件展开）。
JobRow _jobRowOf(WireFields fields) {
  return JobRow(
    id: fields.requireNonEmptyString('id'),
    kind: fields.requireString('kind'),
    label: fields.requireString('label'),
    status: fields.requireString('status'),
    startedAt: fields.requireInt('startedAt'),
    outputTotal: fields.requireInt('outputTotal'),
    progress: fields.optionalNonEmptyString('progress'),
    detail: fields.optionalNonEmptyString('detail'),
    finishedAt: fields.optionalInt('finishedAt'),
    // `job.list` 的行不带会话：那次请求本来就知道是哪个会话。
    sid: fields.optionalString('sid'),
  );
}
