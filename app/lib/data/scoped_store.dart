/// 把 [ItemStore] / [OutboxStore] 按 [HostScope] 分域的**装饰器**。
///
/// ## 它解决的那件事
///
/// `sid` 是电脑侧分配的不透明别名，两台电脑可能撞名。分域之后一台电脑一段：
/// 盘上的会话键是 `<hostId>/<sid>`、条目 id 是 `<hostId>/<itemId>`、待发项的
/// `requestId` 同样带前缀。于是：
///
/// - 切到另一台电脑**不清库**（原来"换电脑清库"的代价是切回去整段重刷信息流）；
/// - 也**不会把 A 的历史喂给 B**（撞名时两段互不覆盖）；
/// - 清一台电脑的缓存只需要 `clearScope()`，不用"删四张表"（那会连 `device.*`
///   偏好与 `schema.data_version` 一起清掉 —— 切电脑后主题/字号回默认就是这个）。
///
/// ## 为什么是装饰器而不是给实现加一个 `hostId` 字段
///
/// 字段版（`SqfliteItemStore.setHostScope`）要求"任何读写之前先设一次"，是隐式时序契约；
/// 而且内存实现会漏掉同一条语义（两个实现只在"跑通的那条路径"上一致）。装饰器把作用域
/// 变成**构造参数**：`ItemStore` 的接口一个字节都不用改，两个真实实现都不认识 host，
/// 分域规则只有这一处。
///
/// ## `meta` 为什么不吃前缀
///
/// `meta` 的键**自己就带归属**：`device.*` 跨电脑保留、`schema.*` 是迁移记账、
/// `host.<hostId>.*` 才是属于某一台的状态（`docs/subsystems/ui-state.md` §2）。
/// 再给它们套一层前缀就是同一件事两处表达。
library;

import '../core/outbox.dart';
import 'host_scope.dart';
import 'store.dart';

/// 按 [HostScope] 分域的条目库。
class ScopedItemStore implements ItemStore {
  ScopedItemStore(this.inner, this.scope);

  /// 真实现（sqflite / 内存）。**它不认识 host**，也不会被单独拿出去用。
  final ItemStore inner;

  /// 这台电脑的作用域。
  final HostScope scope;

  @override
  Future<void> open() => inner.open();

  @override
  Future<void> close() => inner.close();

  @override
  Future<void> commit(String sid, List<StoredItem> items, int seq) {
    final key = scope.keyOf(sid);
    return inner.commit(key, <StoredItem>[
      for (final item in items)
        StoredItem(
          itemId: scope.keyOf(item.itemId),
          sid: key,
          seq: item.seq,
          kind: item.kind,
          payloadJson: item.payloadJson,
          updatedAt: item.updatedAt,
        ),
    ], seq);
  }

  @override
  Future<List<StoredItem>> itemsOf(String sid, {int limit = 500}) async {
    final rows = await inner.itemsOf(scope.keyOf(sid), limit: limit);
    return <StoredItem>[
      for (final row in rows)
        StoredItem(
          itemId: scope.plainOf(row.itemId),
          sid: scope.plainOf(row.sid),
          seq: row.seq,
          kind: row.kind,
          payloadJson: row.payloadJson,
          updatedAt: row.updatedAt,
        ),
    ];
  }

  @override
  Future<Map<String, String>> payloadsOf(String sid, Iterable<String> itemIds) async {
    final raw = await inner.payloadsOf(scope.keyOf(sid), itemIds.map(scope.keyOf));
    return <String, String>{
      for (final entry in raw.entries) scope.plainOf(entry.key): entry.value,
    };
  }

  @override
  Future<int> cursorOf(String sid) => inner.cursorOf(scope.keyOf(sid));

  @override
  Future<Map<String, int>> allCursors() async {
    final raw = await inner.allCursors();
    return <String, int>{
      for (final entry in raw.entries)
        if (scope.owns(entry.key)) scope.plainOf(entry.key): entry.value,
    };
  }

  @override
  Future<int> prune(String sid, {int keep = 500}) =>
      inner.prune(scope.keyOf(sid), keep: keep);

  @override
  Future<String?> readMeta(String key) => inner.readMeta(key);

  @override
  Future<Map<String, String>> readMetaPrefix(String prefix) =>
      inner.readMetaPrefix(prefix);

  @override
  Future<void> writeMeta(String key, String value) => inner.writeMeta(key, value);

  @override
  Future<void> deleteMeta(String prefix, {bool includePrefixed = true}) =>
      inner.deleteMeta(prefix, includePrefixed: includePrefixed);

  /// 忘掉一个会话（条目 + 水位）。传**本机键**，前缀在这里加。
  @override
  Future<void> clearSession(String sid) => inner.clearSession(scope.keyOf(sid));

  /// 清空**这台电脑**的条目与水位。
  ///
  /// 这是分域之后"清空"的正确含义：盘上还有别的电脑，它们不是这次的爆炸半径。
  /// 实现是枚举自己的会话逐个 `clearSession` —— 不做 `DELETE FROM items` 那种
  /// 越界删除，也不碰 `meta`（`device.*` / `schema.*` / 别的 `host.*` 一律不在这里）。
  Future<void> clearScope() async {
    final mine = await inner.allCursors();
    for (final key in mine.keys.where(scope.owns)) {
      await inner.clearSession(key);
    }
  }

  /// 接口上的 `clear()`。在分域库里它**就是** [clearScope]：
  /// "清空"的爆炸半径由作用域决定，否则一次误调就清掉了别的电脑。
  @override
  Future<void> clear() => clearScope();

  /// **只给迁移用**（迁移跑在内层库上，那时还没有作用域）。
  @override
  Future<void> scopeKeysTo(String prefix) => inner.scopeKeysTo(prefix);
}

/// 按 [HostScope] 分域的待发队列。
///
/// `requestId` 是客户端生成的幂等键，两台电脑各自生成、可能撞号；撞了之后
/// "移除一项"会删到另一台的那条。所以它和会话键走同一条规则。
class ScopedOutboxStore implements OutboxStore {
  ScopedOutboxStore(this.inner, this.scope);

  final OutboxStore inner;
  final HostScope scope;

  @override
  Future<List<OutboxEntry>> load() async {
    final rows = await inner.load();
    return <OutboxEntry>[
      for (final row in rows)
        if (scope.owns(row.requestId))
          OutboxEntry(
            requestId: scope.plainOf(row.requestId),
            method: row.method,
            params: row.params,
            sid: row.sid,
            frameId: row.frameId,
          ),
    ];
  }

  @override
  Future<void> append(OutboxEntry entry) => inner.append(OutboxEntry(
    requestId: scope.keyOf(entry.requestId),
    method: entry.method,
    params: entry.params,
    sid: entry.sid,
    frameId: entry.frameId,
  ));

  @override
  Future<void> remove(String requestId) => inner.remove(scope.keyOf(requestId));

  @override
  Future<void> clear() async {
    // 逐条 remove：`OutboxStore` 没有"按前缀删"，而队列最多是几条待发项。
    // 加一个"按前缀删"的接口方法只为省这几次往返，不值。
    final rows = await inner.load();
    for (final row in rows.where((row) => scope.owns(row.requestId))) {
      await inner.remove(row.requestId);
    }
  }
}
