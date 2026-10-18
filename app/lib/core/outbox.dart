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
/// 3. **帧号由调用方在入队前铸**，条目带上它（见 [OutboxEntry.frameId]）。
///    调用方必须**在 `flush()` 之前**拿到帧号才能登记在途等待：
///    `res` 只在帧写出去之后到达，登记晚于它就等于把那一帧应答当成
///    "迟到的"丢掉、调用方永远挂着。队列自己不铸 —— 它铸了也没人来得及登记。
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

import 'frame.dart';

/// 一条待发的写操作。
class OutboxEntry {
  const OutboxEntry({
    required this.requestId,
    required this.method,
    required this.params,
    this.sid,
    this.frameId = '',
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
  ///
  /// **它只进信封顶层，永不上帧头**：形状由业务定（`i:<callId>` 就带冒号），
  /// 而帧头 `id` 受契约 §3 的 ASCII 安全字符集约束。把本键写进帧头，
  /// 连接器会按 `protocol/bad-frame` 拒收并关连接 ——
  /// 表现是"点了允许一次，连接断了，队列不推进"。
  final String requestId;

  /// 帧头 `id`：这一次 `req` / `res` 的**关联令牌**，与 [requestId] 是两个标识符。
  ///
  /// 发送方铸、`res` 原样回显（契约 §I10："`id` 只关联端点请求与应答"），
  /// 所以必须满足 §3 的字符集。同一幂等键的**重发会换一个新帧号**：
  /// 电脑侧按 `requestId` 去重后回的是**缓存的结果**，而那个 `res` 的帧头
  /// 用的是本次请求的帧号（`connector/src/method-face.ts` 的 `resFrame`），
  /// 所以新帧号照样能兑现。
  ///
  /// **不落盘**：它只关联一个**活的**完成器 —— 进程没了调用方也没了，
  /// 旧帧号无人等待。从盘上恢复的旧行由 [Outbox.restore] 补铸。
  final String frameId;

  /// 方法名（契约 §5.7 的封闭集）。
  final String method;

  /// 参数（封进 `box` 的 `params`）。
  final Map<String, Object?> params;

  /// 会话别名（帧头 `sid`；不是每个方法都有）。
  final String? sid;

  /// 落盘形态（持久队列用）。
  ///
  /// **不含 `frameId`**：它只关联一个活的完成器，进程死了就没人等了
  /// （见 [frameId] 的说明）。落盘形状因此与升级前逐字节相同 ——
  /// 老行能被原样读回来，帧号在 [Outbox.restore] 补铸。
  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'method': method,
    'params': params,
    if (sid != null) 'sid': sid,
  };

  /// 换一个帧号（恢复旧行用）。
  OutboxEntry copyWithFrameId(String frameId) => OutboxEntry(
    requestId: requestId,
    method: method,
    params: params,
    sid: sid,
    frameId: frameId,
  );
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
  Outbox({
    required OutboxStore store,
    SendEntry? send,
    String Function()? newFrameId,
  }) : _store = store,
       _send = send,
       _newFrameId = newFrameId ?? _defaultFrameId;

  final OutboxStore _store;

  SendEntry? _send;

  /// 帧号来源。**只有 [restore] 用它**（旧行没有帧号，而原调用方已随进程消失）。
  final String Function() _newFrameId;

  static String _defaultFrameId() => newFrameId(randomBytes(frameIdBytes));

  /// 装上出帧口。**由 `SyncClient` 在构造自己之后调**。
  ///
  /// ## 为什么是"先建队列、后装出帧口"而不是构造时传
  ///
  /// 两者互相需要：队列要客户端才能发帧，而客户端要队列才能处理写操作 ——
  /// 构造期传就成环了。而**绕开它的常见做法（构造时传一个假实现）已经踩过**：
  /// 装配点写了 `send: (_) async => false`，于是 `flush()` 永远返回 `offline`、
  /// **队列里每一条都永远发不出去**，而症状只是"订阅了但收不到数据"——
  /// 没有任何报错（`offline` 是合法返回值）。
  ///
  /// 所以出帧口是**可缺省的**：缺省时 [flush] 如实返回 [FlushOutcome.offline]
  /// （而不是假装发成功），而装上去这个动作是显式的、只在一处发生。
  void attachSender(SendEntry send) => _send = send;

  /// 是否已装出帧口（诊断与启动自检用）。
  ///
  /// **生产装配必须让它为真**：为假意味着"能入队但永远发不出去"。
  bool get hasSender => _send != null;

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
    _pending.clear();
    for (final entry in await _store.load()) {
      // 旧行没有帧号（本字段不落盘，见 [OutboxEntry.frameId]）：
      // 补铸一个。原调用方已随上一个进程消失，旧帧号无人等待，
      // 所以这里铸新的既安全也不会漏掉任何在途等待。
      _pending.add(
        entry.frameId.isEmpty ? entry.copyWithFrameId(_newFrameId()) : entry,
      );
    }
    _loaded = true;
  }

  /// 入队并**先落盘**（契约 §5.6 的两阶段之一）。
  ///
  /// 落盘失败即抛 —— 调用方据此拒绝这次写操作，而不是"先发了再说"。
  /// 一个没落盘的写操作在崩溃后消失，而用户以为它发出去了。
  /// **顺序不能反**：先落盘、成功后才进内存镜像，否则落盘抛错时队列里
  /// 留着一条盘上没有的条目（"没落盘却不能留在队列里"就是钉这个的）。
  ///
  /// **同一幂等键重复入队 = 用新条目替换旧条目**（不是无操作）：
  /// 排着队而没人等的同一键只可能是上一次尝试的残留（那次抛了 `relay/offline`，
  /// 已经把在途登记撤了）。键不变 ⇒ 电脑侧仍然去重；帧号换新 ⇒ 这次的调用方
  /// 能被兑现。两条都换才会同时坏掉。
  Future<void> enqueue(OutboxEntry entry) async {
    // 落盘是 upsert（`request_id` 是主键，见 `SqfliteOutboxStore.append`），
    // 所以替换与追加在同一条语句里完成。
    await _store.append(entry); // 抛错即没落盘
    final index = _pending.indexWhere(
      (item) => item.requestId == entry.requestId,
    );
    if (index >= 0) {
      _pending[index] = entry;
    } else {
      _pending.add(entry);
    }
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
      final send = _send;
      // **没装出帧口就如实说"发不出去"**（而不是假装发成功）。
      // 假装成功会让调用方把队列项删掉 —— 那等于**静默丢掉一次写操作**。
      if (send == null) return FlushOutcome.offline;
      final entry = _pending.first;
      final sent = await send(entry);
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

/// 生成一个幂等键（**默认形状**）。
///
/// 16 字节 base64url。业务也可以用自己的形状（`i:<callId>`，见 §5.7）——
/// 那正是**不能把它写进帧头 `id`** 的原因，见 [OutboxEntry.frameId]。
/// [randomBytes] 注入是为了让测试确定化。
String newRequestId(List<int> randomBytes) =>
    base64Url.encode(randomBytes).replaceAll('=', '');

// 信封的编码只有一处：`sync_client_impl.dart` 的 `encodeRequestEnvelope`。
// 这里曾经还有一份 `encodeRequest(OutboxEntry)`，与它逐字重复 ——
// 同一份线上形状的两个编码器就是漂移源，已删。
