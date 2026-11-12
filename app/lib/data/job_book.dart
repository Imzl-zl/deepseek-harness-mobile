/// 后台任务的**内存状态**（按会话分桶的任务表 + 输出缓冲 + 订阅标记 + 出错说明）。
///
/// ## 为什么它不在 `AppModel` 里
///
/// 这一簇有四个表、约 150 行（含注释），而且它的**判据全都自洽**：桶怎么归、
/// 终态怎么单向合并、输出怎么只追加。`AppModel` 在那一段里只做两件事 ——
/// 转发端口（`_writes.followJob`）和发通知，那是编排，不是状态。
///
/// 收窄计划把它整簇搬出来（`.agents/notes/proposed/2026-10-27-ui-state-design.md`
/// 的第二簇；执行顺序见 `memory.md` 的「下一步」）。搬出来的收益不是行数，是
/// **判据集中**："帧不带 sid 时归哪个桶""迟到 status 不许把终态改回 running"
/// 只在这一个文件里，`AppModel` 只剩转发。
///
/// ## 边界
///
/// - **不认识端口**：它不订阅、不 kill、不发帧。"展开任务"这件事的**网络**那一半
///   在 `AppModel`（`followJob`），这里只记"我订阅了谁"。
/// - **不认识会话**：`sid` 是它收到的字符串，它不去查会话列表，也不认 `_currentSid`
///   —— 需要"当前会话"的地方由调用方当参数传进来（[applyFrame] 的 `fallbackSid`）。
/// - **不发通知**：状态变了由调用方（`AppModel`）决定要不要 `notifyListeners`
///   与重算提醒 —— 那是通知族的事，不归状态表管。
///
/// 行为钉子见 `app/test/job_merge_test.dart` / `job_panel_test.dart`
/// （在搬移之前就在跑，搬完必须仍全绿）。
library;

import '../core/job.dart';

/// 一个任务的输出要留多少 —— **直接取宿主自己的保留量**，不是拍的。
///
/// DSH 的 `jobs-local` 只保留最近一段输出（ring）：
/// - 跑着的时候 `DEFAULT_RETAIN_BYTES = 256 * 1024`（`packages/jobs/jobs-local/src/index.ts:37`）
/// - 结算之后收紧到 `DEFAULT_SETTLED_RETAIN_BYTES = 16 * 1024`（同文件 `:40`，收紧在 `:624-628`）
///
/// 手机留得比宿主更久，等于在保留宿主已经判定"不值得留"的字节，而且它自己
/// 只增不减（`unfollow` 不释放）。所以这里跟着宿主的两档走。
///
/// **单位是字符而不是字节**：宿主按 UTF-8 字节算，而这里是一个 Dart `String`。
/// 逐个 chunk 编 UTF-8 只为了数长度不值，而任务输出绝大多数是 ASCII 日志（两者相等）；
/// 中文日志下这个上限相当于更宽松，但**仍然有界** —— 这条门禁要的是"不会无限涨"。
const int kJobOutputLiveChars = 256 * 1024;
const int kJobOutputSettledChars = 16 * 1024;

/// 一次 append 之后允许超出的余量（超出这么多的整份裁剪一次，摊还到 O(1)/字符）。
const int _kTrimSlackChars = kJobOutputLiveChars ~/ 4;

/// 输出里"前面有洞"时给界面的那一句话（`jobError` 通道，与订阅中断共用一格）。
///
/// 文案与宿主 `gapBefore` 的含义对齐：**丢了就说出来**（`ui/side_pane.dart:709-716`）。
const String kJobOutputDroppedNote = '部分输出已丢失（保留窗口之外）';

/// 内联在输出正文最前面的缺口标记（与 `gapBefore` 用的是同一句话）。
const String kJobOutputGapMarker = '…（较早的输出已被淘汰）';

/// 一个任务的输出缓冲。
class _Output {
  final StringBuffer text = StringBuffer();

  /// 前面有洞（被裁掉 / 这一条流从中途开始）。
  ///
  /// **内联在正文最前面，而不是走 `jobError`**：洞就长在开头，说在那里最不容易被
  /// 读成"这是完整日志"，而且复制出去时它跟着走。`jobError` 留给"流本身出过问题"
  /// （订阅断了 / 宿主报了 `lossy`）—— 两件事挤一个管道会让"为什么有洞"说不清。
  bool dropped = false;

  void reset({bool dropped = false}) {
    text.clear();
    this.dropped = dropped;
  }

  void append(String chunk) => text.write(chunk);

  /// 超过 [kJobOutputLiveChars] 就只留尾巴（保留最近的）。
  ///
  /// 返回是否真的裁了。
  bool trim({int cap = kJobOutputLiveChars}) {
    if (text.length <= cap + _kTrimSlackChars) return false;
    final whole = text.toString();
    text
      ..clear()
      ..write(whole.substring(whole.length - cap));
    dropped = true;
    return true;
  }

  int get length => text.length;

  /// 去掉第一行（裁掉的开头是半行时，不要让它当一个残缺的行显示）。
  void dropPartialHead() {
    final whole = text.toString();
    final newline = whole.indexOf('\n');
    if (newline < 0) return;
    text
      ..clear()
      ..write(whole.substring(newline + 1));
  }

  @override
  String toString() =>
      dropped ? '$kJobOutputGapMarker\n${text.toString()}' : text.toString();
}

class JobBook {
  JobBook();

  /// 会话 → 那一会话的任务表。**按 sid 分桶**：切会话看的是那一会话的任务。
  final Map<String, List<JobRow>> _jobs = {};

  /// 正在订阅的任务（`sid` → `jobId` 集合）。展开时 follow、收起时 unfollow。
  final Map<String, Set<String>> _followed = {};

  /// 每个任务已收到的输出（`jobId` → 文本）。**只追加，不重排** ——
  /// 输出是日志，重排会让"读到这里"失去意义。
  ///
  /// 上限跟宿主走（见 [kJobOutputLiveChars]）；**重开流时整份换掉**（见 `applyFrame`）。
  final Map<String, _Output> _output = {};

  /// 任务帧流出问题（订阅中断 / 帧解不开）时给界面的一句话。
  final Map<String, String> _errors = {};

  // ---- 读面 ----

  List<JobRow> jobsOf(String sid) => List.unmodifiable(_jobs[sid] ?? const []);

  /// 某个任务已收到的输出文本（没有订阅过就是空串）。
  String outputOf(String jobId) => _output[jobId]?.toString() ?? '';

  /// 某个任务的订阅问题；`null` = 没问题。
  String? errorOf(String jobId) => _errors[jobId];

  bool isFollowed(String sid, String jobId) =>
      _followed[sid]?.contains(jobId) ?? false;

  /// 已建桶的会话（`refreshJobs` 前先建桶要用）。
  Iterable<String> get sids => _jobs.keys;

  // ---- 写面（状态） ----

  /// **先建桶再早退**：`job` 帧不带 sid，只能靠"这个会话有桶"归位。
  /// 桶不存在时帧会被丢 —— 而表现是"任务在跑但没有输出"，最难查的那类。
  void ensureBucket(String sid) {
    _jobs.putIfAbsent(sid, () => <JobRow>[]);
  }

  /// 把一次 `job.list` 快照并进桶里。
  ///
  /// 判据（**终态单向**）只有一份：`core/job.dart` 的 [mergeJobSnapshot]。
  /// 这里只负责"桶"（哪个会话），不重复规则本身 —— 快照与 `status` 推送会赛跑
  /// （请求早于完成、回来晚于推送），两条写路径必须共用同一条规则，
  /// 否则下一次只会修好一条（2026-10-26 评审）。
  void applySnapshot(String sid, List<JobRow> rows) {
    _jobs[sid] = mergeJobSnapshot(_jobs[sid] ?? const <JobRow>[], rows);
  }

  /// 应用一条 `job` 帧。**只认四种 kind**（`core/job.dart` 的 sealed 类），
  /// 漏一种编译期就红。
  ///
  /// ## `JobOpened` = 一条新流开始，缓冲**整份换掉**
  ///
  /// 宿主 `follow` 的契约（`packages/api/job-controller/src/types.ts:55-62`）：
  /// 不给 `from` 就从**最老的保留字节**开始重放。而手机展开是 `follow`、收起是
  /// `unfollow` —— 于是"展开 → 收起 → 再展开"会收到一遍重放。
  /// 之前的写法是 `putIfAbsent`（保留旧缓冲），于是同一段日志**会被追加两遍**。
  /// `opened` 带着 `from`，正好告诉我们这条流从哪儿开始：
  /// - `from == 0`：从头重放 ⇒ 干净重置；
  /// - `from > 0`：宿主已经淘汰了前面一段 ⇒ 重置 **并显式标注有洞**。
  ///
  /// 返回"要不要重算提醒"：**只有开任务 / 状态帧要**。输出帧按 chunk 计，
  /// 跟着算一遍提醒太浪费。
  bool applyFrame(JobFrame frame, {String? fallbackSid}) {
    switch (frame) {
      case JobOpened(:final row, :final from):
        _applyRow(row, fallbackSid: fallbackSid);
        // `from > 0` = 宿主已经淘汰了前面一段 ⇒ 重置 + 内联标出洞。
        _output[row.id] = _Output()..reset(dropped: from > 0);
        _errors.remove(row.id);
      case JobOutput(:final jobId, :final chunks, :final lossy):
        final buffer = _output.putIfAbsent(jobId, _Output.new);
        for (final chunk in chunks) {
          if (chunk.gapBefore) {
            buffer.append('$kJobOutputGapMarker\n');
            _errors[jobId] = kJobOutputDroppedNote;
          }
          buffer.append(chunk.text);
        }
        if (lossy) _errors[jobId] = kJobOutputDroppedNote;
        if (buffer.trim()) buffer.dropPartialHead();
      case JobStatus(:final row, :final jobId):
        _applyRow(row, fallbackSid: fallbackSid);
        // 结算之后宿主把 ring 收紧（`jobs-local/src/index.ts:624-628`）：
        // 跟着收紧，别替它留着它已经丢掉的字节。
        final settled = _output[jobId];
        if (!row.isLive &&
            settled != null &&
            settled.length > kJobOutputSettledChars) {
          settled.trim(cap: kJobOutputSettledChars);
          settled.dropPartialHead();
        }
      case JobError(:final jobId, :final message):
        _errors[jobId] = message;
    }
    return frame is JobOpened || frame is JobStatus;
  }

  /// 记"我订阅了这个任务"（幂等）。
  ///
  /// 返回 `false` = 已经订阅过（调用方据此跳过一次网络往返 —— 重复 follow
  /// 会让 UI 上出现"点了两下、输出翻倍"）。
  bool markFollowed(String sid, String jobId) {
    final followed = _followed.putIfAbsent(sid, () => <String>{});
    if (!followed.add(jobId)) return false;
    _output.putIfAbsent(jobId, _Output.new);
    _errors.remove(jobId);
    return true;
  }

  void markUnfollowed(String sid, String jobId) {
    _followed[sid]?.remove(jobId);
  }

  /// 收不到输出时的说明（订阅没开成 / 停任务失败）。
  void setError(String jobId, String message) => _errors[jobId] = message;

  void _applyRow(JobRow row, {String? fallbackSid}) {
    // **帧上带了 sid 就按它归桶**（连接器盖的）：这是唯一可靠的归属信息，
    // 猜的代价是"正在看的会话不显示 chip、别的会话凭空多一个"。
    //
    // 2026-10-15 之前的做法是 `_jobs.keys.last`（地图插入序）——用户先开 A 再开 B，
    // B 里新起的任务被归到 A，于是**正在看的 B 看不到后台任务**。
    // 只有老连接器（帧不带 sid）才退回"当前会话"，且只在它的桶已存在时归。
    final targetSid = row.sid ?? fallbackSid;
    if (targetSid != null && _jobs.containsKey(targetSid)) {
      _put(targetSid, row);
      return;
    }
    // 全局更新：任务在**任何**已建桶的会话里都同步（同 id 覆盖）。
    // 这是为了"用户在 A 看任务、B 也开过"时状态不分裂 —— 但不新建桶
    // （硬塞进一个错误的会话比丢一帧更糟）。
    for (final sid in _jobs.keys) {
      if (_jobs[sid]!.any((j) => j.id == row.id)) {
        _put(sid, row);
        return;
      }
    }
  }

  void _put(String sid, JobRow row) {
    final bucket = _jobs[sid]!;
    final index = bucket.indexWhere((j) => j.id == row.id);
    // **同一份合并规则**：终态单向（`core/job.dart` 的 [mergeJobRow]）。
    // 推送路径也曾漏过这条 —— 一条迟到的 `status` 帧会把已结束的任务改回 running。
    final merged = mergeJobRow(index >= 0 ? bucket[index] : null, row);
    _jobs[sid] = index >= 0
        ? [...bucket..[index] = merged]
        : [...bucket, merged];
  }
}
