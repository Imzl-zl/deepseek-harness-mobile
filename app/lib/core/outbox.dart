/// 写操作待发队列（契约 §5.6，不变量 I8）。
///
/// ## 两条纪律
///
/// 1. **先入队落盘，再发送**。顺序反了的话，崩溃窗口里那次写操作就消失了 ——
///    而用户看到的是"点发送没反应"。落盘失败即**拒绝**该写操作（不是"先发了再说"）：
///    一个没落盘的写操作在重发时会被当成新操作（第二次授权 / 第二条消息）。
/// 2. **幂等键在入队时生成，重发复用同一个**。这是 I8 的全部依据：
///    电脑侧按 `requestId` 去重，所以"重发"与"重复执行"是两件事。
///    **重发必须复用键** —— 每次重发换一个键等于每次都是一次新操作。
///
/// ## 为什么要有 `flush` 而不是"入队即发"
///
/// 连接可能不在服务态（离线、握手未完成、退避中）。此时**不能丢**，也不能假装发成功。
/// 队列是持久的：连接回来后 `flush()` 按入队顺序补发。
///
/// 顺序是刻意的（**FIFO**）：同一会话的写操作通常有因果（先发消息、再改设置），
/// 乱序重发会让电脑侧看到不存在的中间状态。
library;

import 'dart:async';
import 'dart:convert';

/// 一条待发的写操作。
class OutboxEntry {
  const OutboxEntry({
    required this.requestId,
    required this.method,
    required this.params,
    this.sid,
  });

  /// 从落盘形态恢复。
  ///
  /// **坏行抛错而不是跳过**：跳过等于静默丢掉一次写操作，而用户以为它发出去了。
  /// 调用方（启动时的加载路径）据此决定是"拒绝启动"还是"报给用户"。
  factory OutboxEntry.fromJson(Map<String, Object?> json) {
    final requestId = json['requestId'];
    final method = json['method'];
    if (requestId is! String || requestId.isEmpty) {
      throw const FormatException('待发队列的行缺少 requestId');
    }
    if (method is! String || method.isEmpty) {
      throw const FormatException('待发队列的行缺少 method');
    }
    final params = json['params'];
    final sid = json['sid'];
    return OutboxEntry(
      requestId: requestId,
      method: method,
      params: params is Map ? Map<String, Object?>.from(params) : const {},
      sid: sid is String ? sid : null,
    );
  }

  /// 幂等键（契约 §5.6）。**重发复用同一个** —— 换键等于换了一次新操作。
  final String requestId;

  /// 方法名（契约 §5.7 的封闭集）。
  final String method;

  /// 参数（封进 `box` 的 `params`）。
  final Map<String, Object?> params;

  /// 会话别名（帧头 `sid`；不是每个方法都有）。
  final String? sid;

  /// 落盘形态（持久队列用）。
  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'method': method,
    'params': params,
    if (sid != null) 'sid': sid,
  };
}

/// 落盘面（由 `data/` 层实现；`core/` 不认识 sqflite）。
///
/// **注入而不是直接开文件**：`core/` 是纯 Dart、零平台依赖，
/// 所以 IO 一律走这个接口（`node app/tools/verify-platform-boundary.mjs` 会拦 `dart:io`）。
abstract interface class OutboxStore {
  /// 读出全部待发项（按入队顺序）。
  Future<List<OutboxEntry>> load();

  /// 追加一项。**抛错即表示没落盘** —— 调用方据此拒绝这次写操作。
  Future<void> append(OutboxEntry entry);

  /// 移除一项（电脑侧已确认收到）。
  Future<void> remove(String requestId);

  /// 清空（配对失效 / 换设备时用）。
  Future<void> clear();
}

/// 内存实现（测试与"还没接数据库"时用）。
///
/// 它**不是**兜底伪装：`load` 返回的确实是刚 `append` 的东西，
/// 只是不跨进程存活。生产装配必须换成真正的落盘实现（`data/` 层）。
class InMemoryOutboxStore implements OutboxStore {
  final List<OutboxEntry> _entries = [];

  @override
  Future<List<OutboxEntry>> load() async => List.of(_entries);

  @override
  Future<void> append(OutboxEntry entry) async {
    _entries.add(entry);
  }

  @override
  Future<void> remove(String requestId) async {
    _entries.removeWhere((entry) => entry.requestId == requestId);
  }

  @override
  Future<void> clear() async => _entries.clear();
}

/// 一条待发项被送出的结果。
enum FlushOutcome {
  /// 已送出（电脑侧还没回 `res`，那是调用方的事）。
  sent,

  /// 连接不可用（离线 / 未握手 / 退避中）—— **留在队列里**，等下次 `flush`。
  offline,
}

/// 出帧口：把一条待发项写成线上帧。由 `sync_client` 提供。
///
/// 返回 `false` 表示"连接现在发不出去"（不在服务态）—— 此时**不许移除队列项**。
typedef SendEntry = Future<bool> Function(OutboxEntry entry);

/// 写操作待发队列（契约 §5.6）。
class Outbox {
  Outbox({required OutboxStore store, required SendEntry send})
    : _store = store,
      _send = send;

  final OutboxStore _store;
  final SendEntry _send;

  /// 内存镜像（按入队顺序）。落盘是权威，它只是避免每次 `flush` 都读一遍盘。
  final List<OutboxEntry> _pending = [];
  bool _loaded = false;

  /// 当前待发项数。
  int get pending => _pending.length;

  /// 待发项的只读快照（按入队顺序）。
  List<OutboxEntry> get entries => List.unmodifiable(_pending);

  /// 从落盘恢复（启动时调一次）。
  ///
  /// **幂等**：重复调不会重复入队（`_loaded` 之后直接返回）。
  Future<void> restore() async {
    if (_loaded) return;
    _pending
      ..clear()
      ..addAll(await _store.load());
    _loaded = true;
  }

  /// 入队并**先落盘**（契约 §5.6 的两阶段之一）。
  ///
  /// 落盘失败即抛 —— 调用方据此拒绝这次写操作，而不是"先发了再说"。
  /// 一个没落盘的写操作在崩溃后消失，而用户以为它发出去了。
  Future<void> enqueue(OutboxEntry entry) async {
    // 同一个幂等键重复入队是**无操作**：重发要复用同一条（换一条等于换了一次新操作）。
    if (_pending.any((item) => item.requestId == entry.requestId)) return;
    await _store.append(entry); // 抛错即没落盘
    _pending.add(entry);
  }

  /// 按入队顺序把能发的发出去。
  ///
  /// 遇到 `offline` 就**停住**（不是跳过继续）—— FIFO 顺序是刻意的：
  /// 同一会话的写操作通常有因果，跳过一条会让电脑侧看到不存在的中间状态。
  ///
  /// 已送出的项**从队列移除**：电脑侧已收到，后续的确认由 `res` 负责；
  /// 没收到的话重连后由 `persisted`/快照收敛（那是会话层的事，不是队列的）。
  Future<FlushOutcome> flush() async {
    while (_pending.isNotEmpty) {
      final entry = _pending.first;
      final sent = await _send(entry);
      if (!sent) return FlushOutcome.offline;
      await _store.remove(entry.requestId);
      _pending.removeAt(0);
    }
    return FlushOutcome.sent;
  }

  /// 清空（配对失效 / 换设备）。
  Future<void> clear() async {
    await _store.clear();
    _pending.clear();
  }
}

/// 生成一个幂等键。
///
/// 形状照契约：16 字节 base64url（与帧 `id` 同规格，两者都是 bearer 凭据级别的随机）。
/// [randomBytes] 注入是为了让测试确定化。
String newRequestId(List<int> randomBytes) =>
    base64Url.encode(randomBytes).replaceAll('=', '');

/// 把一条待发项编成请求信封（`box` 里的 JSON）。
///
/// 与电脑侧 `protocol/methods.ts` 的 `RequestEnvelope` 对应：
/// **`requestId` 在信封顶层**，不在 `params` 里（§5.7）。
String encodeRequest(OutboxEntry entry) => jsonEncode({
  'method': entry.method,
  'params': entry.params,
  if (entry.requestId.isNotEmpty) 'requestId': entry.requestId,
});
