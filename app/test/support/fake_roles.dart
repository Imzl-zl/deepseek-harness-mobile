/// 测试替身：**电脑侧桥接**与**中转**（契约 §5，fixtures 的三角色回放用）。
///
/// ## 为什么它们在 `test/` 而不是 `lib/`
///
/// fixtures 是**三角色场景脚本**（手机 ⇄ 中转 ⇄ 桥接），而手机端只实现其中**一个**角色：
///
/// | 角色 | 归属 |
/// |---|---|
/// | 手机（`device`） | ✅ **产品代码** —— `lib/core/`（`DeviceSession` 等） |
/// | 中转（`relay`） | ❌ 本文件的替身（手机端不实现中转） |
/// | 桥接（`bridge`） | ❌ 本文件的替身（手机端不实现电脑侧） |
///
/// 这与 `connector/tests/fixtures.test.ts` 的做法对称：那边把**手机侧**做成替身
/// （`since` / `received` / `upsert` / `applyAnswer`），因为真实实现属于 Dart 侧。
/// 两份替身各自忠实于同一份契约，于是**同一批 fixtures 被两侧各跑一遍**。
///
/// 移植源：`connector/src/protocol/recovery.ts`（桥接）与
/// `connector/tests/support/relay.ts`（中转）。行为必须与它们一致 ——
/// 不一致的话，红的是 fixtures 而不是替身，会浪费一轮排查。
library;

import 'dart:convert';

import 'package:dsh_mobile/core/items.dart';
import 'package:dsh_mobile/core/recovery.dart';

/// 桥接侧的一帧：`t` / `sid` / `seq` 是路由头，`box` 是不透明内容。
class BridgeFrame {
  const BridgeFrame({required this.sid, required this.seq, required this.itemId, required this.text});

  final String sid;
  final int seq;
  final String itemId;
  final String text;

  /// 与电脑侧 `seal` 同一个形状（fixtures 词汇层的 `seal` 是**可逆占位**，不是加密）。
  String get box => jsonEncode(<String, Object?>{'itemId': itemId, 'text': text});
}

/// 快照分页的结果。
class SnapshotPage {
  const SnapshotPage({
    required this.asOfSeq,
    required this.hasMore,
    required this.items,
    this.cursor,
  });

  final int asOfSeq;
  final bool hasMore;
  final List<ItemRecord> items;
  final String? cursor;
}

class _Session {
  int next = 1;
  final List<LogEntry> log = <LogEntry>[];
  List<LogEntry> frames = <LogEntry>[];
  int trimmedUpto = 0;
  final Map<String, String> items = <String, String>{};
  TransientFacts transient = <String, Object?>{};
  Map<String, Object?> pending = <String, Object?>{};
  ({int asOfSeq, String cursor, SnapshotReason reason})? snapshot;
}

/// 电脑侧桥接的替身（契约 §5 的**权威侧**）。
class FakeBridge {
  FakeBridge({Map<String, Map<String, String>> initial = const {}, int snapshotPageSize = 100})
      : _pageSize = snapshotPageSize {
    for (final entry in initial.entries) {
      for (final item in entry.value.entries) {
        append(entry.key, item.key, item.value);
      }
    }
  }

  /// 快照每页的条目数。
  ///
  /// **从 fixture 的 `snapshotPageSize` 读**（默认 100）：写死会让"分页"这件事
  /// 永远只走一页，于是 `hasMore` / 续页 / 分页期间的并发增量全都测不到 ——
  /// fixture 12 就是专门测这个的（它给的是 2）。
  final int _pageSize;
  final Map<String, _Session> _sessions = <String, _Session>{};
  final Set<String> _dedupe = <String>{};

  _Session _ensure(String sid) => _sessions.putIfAbsent(sid, () => _Session());

  BridgeFrame _record(_Session session, String sid, String itemId, String text) {
    final seq = session.next;
    session.next += 1;
    final entry = LogEntry(seq: seq, itemId: itemId, text: text);
    session.log.add(entry);
    session.frames.add(entry);
    session.items[itemId] = text; // upsert-only
    return BridgeFrame(sid: sid, seq: seq, itemId: itemId, text: text);
  }

  /// 追加一条事件（分配新的修订号）。
  BridgeFrame append(String sid, String itemId, String text) =>
      _record(_ensure(sid), sid, itemId, text);

  /// 发送：同一幂等键只接纳一次（对应 DSH 的 `requestId` 语义）。被拒时返回 `null`。
  BridgeFrame? send(String sid, String requestId, String text) {
    if (_dedupe.contains(requestId)) return null;
    final frame = append(sid, 'req:$requestId', text);
    _dedupe.add(requestId);
    return frame;
  }

  /// 审批 / 提问的 ask：进日志，同时进「当前待处理」。
  BridgeFrame ask(String sid, String callId, [Object? payload]) {
    final frame = append(sid, 'i:$callId', jsonEncode(<String, Object?>{'kind': 'ask', 'payload': payload ?? <String, Object?>{}}));
    _ensure(sid).pending[callId] = payload;
    return frame;
  }

  /// outcome：同 itemId 覆盖 ask，并从待处理集合移除。
  BridgeFrame answer(String sid, String callId, Object? decision) {
    final frame = append(sid, 'i:$callId', jsonEncode(<String, Object?>{'kind': 'outcome', 'decision': decision}));
    _ensure(sid).pending.remove(callId);
    return frame;
  }

  Map<String, Object?> pendingOf(String sid) =>
      Map<String, Object?>.from(_ensure(sid).pending);

  /// 模拟桥接进程重启：内存派生态清空，再按 `keepDedupe` 决定去重表是否幸存。
  void restart({bool keepDedupe = true}) {
    for (final session in _sessions.values) {
      session.frames = <LogEntry>[];
      session.trimmedUpto = 0;
      session.pending = <String, Object?>{};
      session.snapshot = null;
      session.transient = <String, Object?>{};
    }
    if (!keepDedupe) _dedupe.clear();
  }

  /// 从持久日志重建待审批集合（「有 ask、无 outcome」即悬空）。
  void rebuildPending() {
    for (final session in _sessions.values) {
      final open = <String>{};
      final payloadOf = <String, Object?>{};
      for (final entry in session.log) {
        if (!entry.itemId.startsWith('i:')) continue;
        final callId = entry.itemId.substring(2);
        final body = jsonDecode(entry.text) as Map<String, Object?>;
        if (body['kind'] == 'ask') {
          open.add(callId);
          payloadOf[callId] = body['payload'];
        } else {
          open.remove(callId);
        }
      }
      session.pending = <String, Object?>{
        for (final callId in open) callId: payloadOf[callId],
      };
    }
  }

  int? latestSeq(String sid) {
    final session = _sessions[sid];
    return session == null ? null : session.next - 1;
  }

  BridgeFrame frameAt(String sid, int seq) {
    final session = _sessions[sid];
    final entry = session?.frames.where((f) => f.seq == seq).firstOrNull ??
        session?.log.where((f) => f.seq == seq).firstOrNull;
    if (entry == null) throw StateError('没有 seq=$seq 的帧（sid=$sid）');
    return BridgeFrame(sid: sid, seq: entry.seq, itemId: entry.itemId, text: entry.text);
  }

  Map<String, String> itemsOf(String sid) =>
      Map<String, String>.from(_sessions[sid]?.items ?? const <String, String>{});

  TransientFacts transientOf(String sid) =>
      Map<String, Object?>.from(_sessions[sid]?.transient ?? const <String, Object?>{});

  void setTransient(String sid, TransientFacts patch) {
    final session = _ensure(sid);
    session.transient = <String, Object?>{...session.transient, ...patch};
  }

  /// 模拟缓冲上界：丢掉 `upto` 及之前的帧，之后的补课只能走基线快照。
  void trim(String sid, int upto) {
    final session = _ensure(sid);
    if (upto > session.trimmedUpto) session.trimmedUpto = upto;
    session.frames = session.frames.where((f) => f.seq > session.trimmedUpto).toList();
  }

  SnapshotPage _pageOf(List<ItemRecord> all, int asOfSeq) {
    final cut = all.length > _pageSize ? all.length - _pageSize : 0;
    final rest = all.sublist(0, cut);
    final page = all.sublist(cut);
    final tail = rest.isNotEmpty ? rest.last : null;
    return SnapshotPage(
      asOfSeq: asOfSeq,
      hasMore: rest.isNotEmpty,
      cursor: (rest.isNotEmpty && tail != null) ? 'b:${tail.seq}' : null,
      items: page,
    );
  }

  /// 快照续页：游标形如 `b:<beforeSeq>`（契约 §5.4）。reason 与首答一致。
  RecoveryAnswer snapshotPage(String sid) {
    final session = _ensure(sid);
    final snapshot = session.snapshot;
    if (snapshot == null) throw StateError('没有进行中的快照（sid=$sid）');
    final before = int.parse(snapshot.cursor.substring(2));
    final all = orderedItems(session.log, session.items).where((item) => item.seq <= before).toList();
    final page = _pageOf(all, snapshot.asOfSeq);
    final reason = snapshot.reason;
    session.snapshot = page.hasMore
        ? (asOfSeq: snapshot.asOfSeq, cursor: page.cursor ?? '', reason: reason)
        : null;
    return RecoveryAnswer(
      sid: sid,
      source: 'bridge',
      outcome: RecoveryOutcome.snapshot,
      reason: reason,
      asOfSeq: page.asOfSeq,
      hasMore: page.hasMore,
      items: page.items,
      transient: transientOf(sid),
    );
  }

  /// 恢复：只允许两种回答，瞬时事实无条件回带。
  RecoveryAnswer hello(String sid, int since) {
    final session = _sessions[sid];
    final transient = transientOf(sid);
    if (session == null) {
      return RecoveryAnswer(
        sid: sid,
        source: 'bridge',
        outcome: RecoveryOutcome.snapshot,
        reason: SnapshotReason.noSession,
        asOfSeq: since,
        hasMore: false,
        items: const <ItemRecord>[],
        to: since,
        transient: transient,
      );
    }
    final latest = session.next - 1;
    if (since > latest || since < session.trimmedUpto) {
      final reason = since > latest ? SnapshotReason.revisionNewer : SnapshotReason.windowMissed;
      final page = _pageOf(orderedItems(session.log, session.items), latest);
      session.snapshot = page.hasMore
          ? (asOfSeq: latest, cursor: page.cursor ?? '', reason: reason)
          : null;
      return RecoveryAnswer(
        sid: sid,
        source: 'bridge',
        outcome: RecoveryOutcome.snapshot,
        reason: reason,
        asOfSeq: page.asOfSeq,
        hasMore: page.hasMore,
        items: page.items,
        to: latest,
        transient: transient,
      );
    }
    final items = session.frames
        .where((f) => f.seq > since)
        .map((f) => ItemRecord(itemId: f.itemId, text: f.text, seq: f.seq))
        .toList();
    return RecoveryAnswer(
      sid: sid,
      source: 'bridge',
      outcome: RecoveryOutcome.delta,
      from: since + 1,
      to: latest,
      items: items,
      transient: transient,
    );
  }

  List<ItemRecord> snapshotItems(String sid) {
    final session = _sessions[sid];
    if (session == null) return const <ItemRecord>[];
    return orderedItems(session.log, session.items);
  }
}

/// 中转侧的一帧：路由视图 + 不透明内容。
class RelayFrame {
  const RelayFrame({required this.t, required this.sid, required this.seq, required this.box});

  final String t;
  final String sid;
  final int seq;
  final String box;
}

/// 中转的替身：有界重放窗口（契约 §2）。
///
/// 行为与 `protocol/reference/relay.mjs` 一致：按会话留存最近的若干帧、按游标给出
/// **连续**区间、区间不连续时明确说自己给不了（**绝不"少发几条"**）。
/// 它不产生修订号、不推断语义、也不解封 `box`。
class FakeRelay {
  FakeRelay([this.windowSize = 1000]);

  final int windowSize;
  final Map<String, List<RelayFrame>> _windows = <String, List<RelayFrame>>{};

  /// 中转实际建立的路由视图字段（`expect.relayRoutingKeysOnly` 用）。
  final List<List<String>> routingKeysSeen = <List<String>>[];

  void put(BridgeFrame frame) {
    final list = _windows.putIfAbsent(frame.sid, () => <RelayFrame>[]);
    // 路由视图与内容分开存：中转只读 routing，box 原样搬运。
    routingKeysSeen.add(<String>['t', 'sid', 'seq']);
    list.add(RelayFrame(t: 'ev', sid: frame.sid, seq: frame.seq, box: frame.box));
    while (list.length > windowSize) {
      list.removeAt(0);
    }
  }

  /// 从 `since` 之后起能否给出一段连续帧；给不了返回 `null`，由电脑侧回答。
  List<RelayFrame>? since(String sid, int since) {
    final list = _windows[sid] ?? const <RelayFrame>[];
    final after = list.where((entry) => entry.seq > since).toList();
    if (after.isEmpty) return null;
    var expected = since + 1;
    for (final entry in after) {
      if (entry.seq != expected) return null;
      expected += 1;
    }
    return after;
  }

  void evictAll() => _windows.clear();
}
