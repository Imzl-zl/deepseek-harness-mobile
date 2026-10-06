/// 恢复判定与快照分页拼接（契约 §5.4、§5.5）。
///
/// 这是**手机侧**的那一半：电脑侧负责"给出增量或快照"，手机侧负责
/// "收到之后怎么落到本地"。两者在 `protocol/fixtures/` 里被同一个场景脚本驱动
/// （三角色回放：手机 ⇄ 中转 ⇄ 桥接）。
///
/// ## 两条不变量（fixtures 全局守着）
///
/// - **I3：恢复只有两种结果** —— 完整增量（`delta`）或基线快照（`snapshot`），
///   不存在"少给几条"的第三种。所以 [RecoveryOutcome] 是封闭的两支。
/// - **I4：瞬时事实无条件回带** —— `pendingApprovals` / `computerOnline` 这类
///   不随修订号推进的事实，每次恢复都要重新给一遍（它们不在事件日志里，
///   漏了就永远停在旧值）。
///
/// ## 接收端的三条规则（契约 §5.4 规则 5）
///
/// - **重复帧**（`seq <= 已收到水位`）丢弃并计数 —— 不丢会让同一条内容出现两次；
/// - **前向空洞**（`seq > 水位 + 1`）**不入库**并计数 —— 真实实现据此触发一次重订；
///   硬塞进去会让本地内容出现"跳号"，而跳号在读路径上无从修复；
/// - **快照分页期间**到达的 `ev` **只缓存不渲染**，分页收口时按 seq 顺序合并 ——
///   否则分页会把中途的新事件覆盖掉（"UI 闪回旧内容"）。
///
/// 移植源：`connector/tests/fixtures.test.ts` 的设备侧替身（行为基准），
/// 以及 `connector/src/protocol/recovery.ts` 的电脑侧对应物。
library;

import 'items.dart';

/// 恢复只有两种结果（不变量 I3）。
enum RecoveryOutcome { delta, snapshot }

/// 快照必须**带原因**（契约 §5.4）。
enum SnapshotReason {
  /// 增量缓冲已经裁过这个水位（手机落后太多）。
  windowMissed,

  /// 手机手里的水位比电脑侧还新（本地库被回滚/换机）。
  revisionNewer,

  /// 电脑侧发现本地历史被重写。
  historyRewritten,

  /// 会话不存在。
  noSession,
}

/// 枚举 ↔ 线上字符串（契约里是 kebab-case）。
const Map<SnapshotReason, String> snapshotReasonWire = <SnapshotReason, String>{
  SnapshotReason.windowMissed: 'window-missed',
  SnapshotReason.revisionNewer: 'revision-newer',
  SnapshotReason.historyRewritten: 'history-rewritten',
  SnapshotReason.noSession: 'no-session',
};

/// 从线上字符串解析。**非法值抛错**，不静默降级成某个默认值 ——
/// 静默降级会让"电脑侧给了个我们不认识的原因"变成"看起来正常"。
SnapshotReason snapshotReasonOf(String wire) {
  for (final entry in snapshotReasonWire.entries) {
    if (entry.value == wire) return entry.key;
  }
  throw ArgumentError('未知快照原因: $wire');
}

/// 瞬时事实：不随修订号推进，恢复时**无条件回带**（不变量 I4）。
///
/// 用 map 而不是固定字段：DSH 侧的事实集合会随版本增减，
/// 而这一层的职责是"原样带回来"，不是"理解每一个"。
typedef TransientFacts = Map<String, Object?>;

/// 设备侧看到的一次恢复应答。
///
/// 它比电脑侧的应答宽：`source` 还可能是 `relay`（中转窗口直接补课）。
class RecoveryAnswer {
  const RecoveryAnswer({
    required this.sid,
    required this.source,
    required this.outcome,
    required this.items,
    required this.transient,
    this.transientSource = 'bridge',
    this.from,
    this.to,
    this.reason,
    this.asOfSeq,
    this.hasMore,
  });

  final String sid;

  /// `bridge`（电脑侧）或 `relay`（中转窗口）。
  ///
  /// **瞬时事实永远来自电脑侧**（见 [transientSource]）—— 中转不合成任何内容。
  final String source;
  final RecoveryOutcome outcome;
  final List<ItemRecord> items;
  final TransientFacts transient;

  /// 这份 [transient] 是谁给的。
  ///
  /// **恒为 `bridge`**（不变量 I4）：中转只搬运帧，不合成瞬时事实。
  /// 单独一个字段而不是靠 [source] 推断 —— 两者确实会不同：中转窗口直接补课的
  /// 增量应答 `source == 'relay'`，但那份瞬时事实仍然必须由电脑侧提供。
  /// 少了这个字段，"瞬时事实来自哪里"就没有可断言的落点。
  final String transientSource;

  /// 仅增量有。
  final int? from;
  final int? to;

  /// 仅快照有。
  final SnapshotReason? reason;
  final int? asOfSeq;
  final bool? hasMore;
}

/// 快照分页期间的状态。
class _SnapshotState {
  _SnapshotState(this.asOfSeq);

  int asOfSeq;
  final Map<String, ItemRecord> acc = <String, ItemRecord>{};
  final Map<String, ItemRecord> buffered = <String, ItemRecord>{};
}

/// 设备侧（手机）的会话状态机。
///
/// 一个 owner 持有一切：水位、条目、瞬时事实、分页状态。UI 只读它的产物 ——
/// 不存在第二处"该不该重建"的判断（那正是会分叉的地方）。
class DeviceSession {
  DeviceSession({
    Map<String, int>? since,
    Map<String, Map<String, String>>? items,
  })  : _since = <String, int>{...?since},
        _items = <String, Map<String, String>>{
          for (final entry in (items ?? const <String, Map<String, String>>{}).entries)
            entry.key: <String, String>{...entry.value},
        },
        _received = <String, int>{...?since};

  /// 手机侧「已落盘」的游标（`persisted` 报的就是它）。
  final Map<String, int> _since;

  /// 手机侧「已收到」的最大序号。**它与 [_since] 不是一回事**：
  /// 收到不等于落盘，快照分页期间两者会拉开距离。
  final Map<String, int> _received;

  /// sid → (itemId → text)。upsert-only。
  final Map<String, Map<String, String>> _items;

  final Map<String, TransientFacts> _transient = <String, TransientFacts>{};
  final Map<String, _SnapshotState> _snapshots = <String, _SnapshotState>{};

  /// 前向空洞次数（契约 §5.4 规则 5）。真实实现据此触发一次重订。
  final Map<String, int> gaps = <String, int>{};

  /// 重复投递丢弃次数。
  final Map<String, int> duplicates = <String, int>{};

  /// 收到的每一次应答（按顺序）—— fixtures 按它断言"恢复应答次数与形状"。
  final List<RecoveryAnswer> answers = <RecoveryAnswer>[];

  /// 已落盘水位（只读视图）。
  Map<String, int> get cursors => Map<String, int>.unmodifiable(_since);

  /// 已收到水位（只读视图）。
  Map<String, int> get received => Map<String, int>.unmodifiable(_received);

  /// 某会话的可见条目（itemId → text）。
  Map<String, String> itemsOf(String sid) => Map<String, String>.unmodifiable(_items[sid] ?? const {});

  /// 某会话当前的瞬时事实。
  TransientFacts transientOf(String sid) => Map<String, Object?>.unmodifiable(_transient[sid] ?? const {});

  /// 该会话的落盘水位。
  int sinceOf(String sid) => _since[sid] ?? 0;

  /// 是否有一个未收口的快照分页。
  bool hasOpenSnapshot(String sid) => _snapshots.containsKey(sid);

  /// 收到一条 `ev`（或补课事件）时的接收规则（契约 §5.4 规则 5）。
  ///
  /// 分页期间只缓存不落库 —— 分页收口时会按 seq 合并。
  void receive(String sid, String itemId, String text, int seq) {
    final snapshot = _snapshots[sid];
    if (snapshot != null) {
      snapshot.buffered[itemId] = ItemRecord(itemId: itemId, text: text, seq: seq);
      return;
    }
    _upsert(sid, itemId, text, seq);
  }

  /// upsert 的三条规则：重复丢弃、空洞不入库、其余按 seq 前进。
  void _upsert(String sid, String itemId, String text, int seq) {
    final seen = _received[sid] ?? 0;
    if (seq <= seen) {
      duplicates[sid] = (duplicates[sid] ?? 0) + 1;
      return;
    }
    if (seq > seen + 1) {
      gaps[sid] = (gaps[sid] ?? 0) + 1;
      return;
    }
    final map = _items.putIfAbsent(sid, () => <String, String>{});
    // upsert-only：同 itemId 覆盖，不新增。
    map[itemId] = text;
    _received[sid] = seq;
  }

  /// 落盘水位前进（渲染/落盘之后才调 —— 快照分页期间**不动**）。
  void commit(String sid, int seq) {
    final current = _since[sid] ?? 0;
    if (seq > current) _since[sid] = seq;
  }

  /// 把一次恢复应答落到本地（契约 §5.4）。
  ///
  /// 增量：逐条 upsert，并把已收到水位推到 `to`。
  /// 快照：**分页期间不落盘、不渲染**，每页累积；`hasMore` 为假时整体替换。
  void applyAnswer(RecoveryAnswer answer) {
    answers.add(answer);
    final sid = answer.sid;
    _transient[sid] = Map<String, Object?>.from(answer.transient);

    if (answer.outcome == RecoveryOutcome.delta) {
      for (final item in answer.items) {
        _upsert(sid, item.itemId, item.text, item.seq);
      }
      final to = answer.to ?? 0;
      if (to > (_received[sid] ?? 0)) _received[sid] = to;
      _snapshots.remove(sid);
      return;
    }

    // 快照：分页期间不落盘、不渲染；每页都累积，期间到达的 ev 一律缓存。
    final state = _snapshots.putIfAbsent(sid, () => _SnapshotState(answer.asOfSeq ?? 0));
    state.asOfSeq = answer.asOfSeq ?? state.asOfSeq;
    for (final item in answer.items) {
      state.acc[item.itemId] = item;
    }

    if (answer.hasMore != true) {
      // 收口：分页累积的内容 + 期间缓存的事件，按 seq 顺序合并。
      final merged = <String, String>{
        for (final entry in state.acc.entries) entry.key: entry.value.text,
      };
      final buffered = state.buffered.values.toList()
        ..sort((a, b) => a.seq.compareTo(b.seq));
      for (final item in buffered) {
        merged[item.itemId] = item.text;
      }
      _items[sid] = merged;

      var highest = state.asOfSeq;
      for (final item in state.acc.values) {
        if (item.seq > highest) highest = item.seq;
      }
      for (final item in buffered) {
        if (item.seq > highest) highest = item.seq;
      }
      _received[sid] = highest;
      commit(sid, highest);
      _snapshots.remove(sid);
    }
  }

  /// 手机侧与给定条目表是否一致（`expect.converged` 用）。
  bool convergedWith(String sid, Map<String, String> other) {
    final mine = _items[sid] ?? const <String, String>{};
    if (mine.length != other.length) return false;
    for (final entry in other.entries) {
      if (mine[entry.key] != entry.value) return false;
    }
    return true;
  }
}

/// 恢复判定的输入：窗口状态（增量缓冲覆盖到哪）。
class WindowState {
  const WindowState({required this.trimmedTo, required this.covered});

  /// 缓冲头部被裁到哪（最后一条被裁掉的 seq）。没裁过是 0。
  final int trimmedTo;

  /// 缓冲是否覆盖得到请求的水位（覆盖不到就只能给快照）。
  final bool covered;
}

/// 恢复判定（契约 §5.4 规则 2-3）—— **纯函数**，fixtures 可以直接调它。
///
/// 判据顺序就是契约的顺序，不要重排：
/// 1. 会话不存在 → 快照（`no-session`）；
/// 2. `since` 大于当前最新 → 快照（`revision-newer`）——手机手里的水位比我们还新；
/// 3. 窗口覆盖不到 `since` → 快照（`window-missed`）；
/// 4. 否则增量。
///
/// 返回 `null` 表示"给增量"（增量的内容由电脑侧按窗口取，本函数只做判定）。
/// 这是刻意的：判定与取数分开，前者可机械验证，后者依赖缓冲实现。
RecoveryOutcome decideRecovery({
  required int since,
  required int? latest,
  required WindowState window,
}) {
  if (latest == null) return RecoveryOutcome.snapshot;
  if (since > latest) return RecoveryOutcome.snapshot;
  if (since < window.trimmedTo) return RecoveryOutcome.snapshot;
  if (!window.covered) return RecoveryOutcome.snapshot;
  return RecoveryOutcome.delta;
}

/// [decideRecovery] 的完整版：连**原因**一起给（快照必须带原因，契约 §5.4）。
({RecoveryOutcome outcome, SnapshotReason? reason}) decideRecoveryWithReason({
  required int since,
  required int? latest,
  required WindowState window,
}) {
  if (latest == null) {
    return (outcome: RecoveryOutcome.snapshot, reason: SnapshotReason.noSession);
  }
  if (since > latest) {
    return (outcome: RecoveryOutcome.snapshot, reason: SnapshotReason.revisionNewer);
  }
  if (since < window.trimmedTo || !window.covered) {
    return (outcome: RecoveryOutcome.snapshot, reason: SnapshotReason.windowMissed);
  }
  return (outcome: RecoveryOutcome.delta, reason: null);
}
