/// **历史页**（`session.page` / `session.refetch`）的形状解码。
///
/// 这两个方法**不走 `client.call`**：它们走 `SyncClient` 的具名方法（`page` / `refetch`），
/// 因为补取（`refetch`）要参与 `await`，纯 decoder 不能 await。所以它们不占
/// `verify-rpc-single-caller.mjs` 的预算 —— 那个数只数 `data/` 与 `ui/` 里的 `call<`。
///
/// ## 形状的出处
///
/// - 应答 `{items, hasMore, throughSeq}`（`connector/src/session-page.ts:112`）。
///   **`throughSeq` 手机不读**（`app/lib/` 里 grep 零命中）—— 写明，不当它不存在。
/// - 每个 item 是判别联合（`connector/src/session-page.ts:102-111`）：
///   `{kind:'record', record:{type:'event', event:{type, seq, time, data}}}`
///   或 `{kind:'refetch', seq, bytes}`。后者是"这条太大，改用 `session.refetch` 单独取"的标记
///   （同文件 `:103-110`）；**跳过它等于在会话里留一个静默的洞**。
/// - `session.refetch` 的应答是 `{record}`（同一个 `record` 形状，`connector/src/session-page.ts:115-139`）。
///
/// ## 失败语义
///
/// - **页级**：`items` 不是数组、或 `refetch` 项**没有 `seq`**（取不回来 ⇒ 那一页有洞）
///   ⇒ [WireBad]，由调用方折成整页失败。**这里不抛异常**：解码层只有 [WireReading]
///   一条失败通道（2026-10-26 评审：上一个版本在这里抛自定义异常，而 `page()` 只接
///   `ProtocolException`，于是整页失败变成了未处理的异步错误）。
/// - **条目级**：`kind` 不认识、或 `record` 解不出 ⇒ 跳过并计一次数
///   （对端加了新 kind 时我们不该整页失败；但"少一条"必须留声）。
///
/// Note: 布局与批次见 `.agents/notes/proposed/2026-10-25-wire-rpc-layer-layout.md`；
/// 失败只有一条通道（本文件 2026-10-26 第 1 批）见
/// `.agents/notes/proposed/2026-10-26-wire-review-fixes.md`。
library;

import '../../core/items.dart' show EventLike, itemIdOf;
import '../../core/sync_client.dart' show SessionEvent;
import '../fields.dart';
import '../reading.dart';

/// 消费方一次拿齐"三态内核 + 历史页解码"（与其余 family 文件同一约定）。
export '../reading.dart';

const String _kPage = 'session.page';
// `session.refetch` 的方法名与参数留在连接层（它走 `SyncClient.refetch` 具名方法，
// 不是 `call<`）；本文件只管那条应答的形状，所以不需要它自己的常量。

/// 一页里的一条：要么是记录（已解成事件），要么是"需要单独补取"的标记。
sealed class SessionPageItemWire {
  const SessionPageItemWire();
}

/// 一条可直接使用的记录。
final class SessionPageRecordWire extends SessionPageItemWire {
  const SessionPageRecordWire(this.event);

  final SessionEvent event;
}

/// 一条需要按 `seq` 补取的标记（补取由连接层的 `await` 循环做）。
final class SessionPageRefetchWire extends SessionPageItemWire {
  const SessionPageRefetchWire(this.seq);

  final int seq;
}

/// 一页的解码结果。
final class SessionPageWire {
  const SessionPageWire({required this.items, required this.hasMore});

  final List<SessionPageItemWire> items;

  /// 还有没有更早的历史。**每一页都带**（`connector/src/session-page.ts:109`），
  /// 缺了就是漂了 ⇒ 整页 [WireBad]。
  final bool hasMore;
}

/// 解一页。**只解形状**：补取与排序留在连接层（那里才能 `await`）。
///
/// **失败只回 [WireReading]，不抛异常**：整页读不出来是 [WireBad]，
/// 由 `page()` 折成 `SessionPage.failure`。解码层自己决定不了"界面该说什么"，
/// 也就不该抢走那条通道（2026-10-26 评审的第一条）。
WireReading<SessionPageWire> readSessionPage(Object? reply) =>
    readObject(_kPage, reply, (fields) {
      final rawItems = fields.requireList('items');
      // **每一页都带它**（`connector/src/session-page.ts:109`）：缺了就是漂了。
      final hasMore = fields.requireBool('hasMore');

      final items = <SessionPageItemWire>[];
      for (final raw in rawItems) {
        if (raw is! Map) {
          fields.report('items 里有一项不是对象：$raw');
          continue;
        }
        final kind = raw['kind'];
        if (kind == 'record') {
          final event = _eventOfRecord(raw['record']);
          if (event == null) {
            // **少一条也要留声**：静默丢弃正是 2026-10-22 之前那批事故的形态。
            fields.report('items 里的 record 解不出：$raw');
          } else {
            items.add(SessionPageRecordWire(event));
          }
          continue;
        }
        if (kind == 'refetch') {
          final seq = raw['seq'];
          if (seq is! int) {
            // 取不回来 ⇒ 这一页有洞：整页失败，由 readObject 折成 WireBad。
            throw const WireFieldError('session.page 的 refetch 项没有 seq');
          }
          items.add(SessionPageRefetchWire(seq));
          continue;
        }
        // 不认识的 kind：跳过并计数（对端加新 kind 时不该整页失败）。
        fields.report('items 里有不认识的 kind：$kind');
      }
      return SessionPageWire(items: items, hasMore: hasMore);
    });

/// `session.refetch` 的应答：`{record}` → 一条事件。认不出 ⇒ [WireBad]。
WireReading<SessionEvent> readRefetchedEvent(Object? reply) {
  if (reply is! Map) return const WireBad('应答不是 {record}（`session.refetch`）');
  final event = _eventOfRecord(reply['record']);
  if (event == null) {
    return const WireBad('record 不是 {type, seq, event}（`session.refetch`）');
  }
  return WireOk(event);
}

/// `record` → 事件（`{type:'event', event:{type, seq, time, data}}`）。
///
/// 认不出就 `null`（由调用方决定跳过还是报错）：形状知识只有这一处。
SessionEvent? _eventOfRecord(Object? record) {
  if (record is! Map) return null;
  final event = record['event'];
  if (event is! Map) return null;
  final type = event['type'];
  final seq = event['seq'];
  if (type is! String || seq is! int) return null;
  return SessionEvent(
    itemId: itemIdOf(EventLike(type: type, seq: seq, data: event['data'])),
    type: type,
    seq: seq,
    // `time` 可缺（老记录）：**退到 seq 而不是当前时钟** —— 用当前时间会让
    // "这条是什么时候的"看起来可信而其实是我们编的。
    time: event['time'] is int ? event['time'] as int : seq,
    data: event['data'],
  );
}
