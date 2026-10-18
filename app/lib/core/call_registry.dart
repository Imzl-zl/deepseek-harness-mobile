/// 在途请求表（契约 §5.7 的请求/应答配对）。
///
/// ## 它守的是什么
///
/// 手机发 `req {id}`，电脑回 `res {id}` —— 两边的配对**只有 `id` 这一个依据**。
/// 这张表把"谁在等这个 `id`"记下来，应答到达时兑现。
///
/// ## 为什么它必须有"整体作废"这一手
///
/// 这是**被一个真缺口逼出来的**：最初这张表只是 `Map<String, Completer>`，
/// 既没有超时，断连时也不清 —— 于是连接在请求在途时断掉，调用方的 `await`
/// **永远不返回**。而断连是**常态**（§2.1 明写"重连是常态，不是异常路径"），
/// 所以这条路必然走到。UI 的表现是"转圈转到天荒地老"，用户只能杀掉 App。
///
/// 修法是给它一个显式的 [failAll]：**连接一离开服务态，所有在途请求立刻被拒绝**。
/// 这比"给每个请求加超时"更准确 —— 请求失败的原因是"这条连接没了"，
/// 而不是"等太久了"，两者的客户端动作不同（前者退避重连后重发，后者是超时重试）。
///
/// ## 为什么它与连接资源分开
///
/// 生命周期**不同**：`ConnectionResources` 每连接换一份（断开即作废），
/// 而这张表在**重连后仍要保留"已经拒绝过"的事实** —— 旧 `id` 绝不能被新连接的
/// 应答兑现（那是上一条连接的请求，兑现它会串台）。所以它挂在 `_SyncClient` 上，
/// 由连接状态的迁移驱动，而不是跟着资源束一起换。
library;

import 'dart:async';

import 'errors.dart';

/// 在途请求的登记与兑现。
class CallRegistry {
  final Map<String, _Waiting> _pending = {};

  /// 当前在途请求数（诊断与测试用）。
  int get pending => _pending.length;

  /// 登记一个在途请求，返回它的完成器。
  ///
  /// [id] 是**帧头 `id`**（`res` 回显的就是它）；[requestId] 是这次写操作的
  /// 幂等键，只在带键的写操作上有。两者分开正是因为帧头 `id` 受字符集约束、
  /// 而幂等键的形状由业务定（`i:<callId>` 带冒号）—— 详见
  /// `outbox.dart` 的 [OutboxEntry.frameId]。
  Completer<Object?> register(String id, {String? requestId}) {
    final completer = Completer<Object?>();
    _pending[id] = _Waiting(completer, requestId);
    return completer;
  }

  /// 撤销登记（发送失败时调，避免留下一个永远不兑现的条目）。
  void unregister(String id) => _pending.remove(id);

  /// 这个幂等键有没有人在等。
  ///
  /// **"同键重发不建第二个等待"靠它**：幂等写（如 `interaction.respond`
  /// 用 `i:<callId>` 当键）被重点一次时，电脑侧按同一个键去重、那个 `res`
  /// 归第一次的调用方 —— 再建一个完成器只会永远挂着（断连才被 `failAll` 收）。
  ///
  /// 判据必须是**键**而不是帧号：每次重发都会换一个新帧号，按帧号判就会漏。
  /// 帧号与键为何是两个东西见
  /// `.agents/notes/implemented/2026-10-17-frame-id-not-idempotency-key.md`。
  bool isPendingRequest(String requestId) =>
      _pending.values.any((waiting) => waiting.requestId == requestId);

  /// 应答到达：兑现并移除。返回 `false` 表示"没有人在等这个 id"
  /// （迟到、重复、或属于上一条连接的应答）—— 调用方据此忽略。
  bool resolve(String id, {required Object? result, ProtocolException? error}) {
    final waiting = _pending.remove(id);
    if (waiting == null) return false;
    if (error != null) {
      waiting.completer.completeError(error);
    } else {
      waiting.completer.complete(result);
    }
    return true;
  }

  /// **整体作废**：连接离开服务态时调（见文件头）。
  ///
  /// 返回被拒绝的条数（诊断用）。空表时是 0，不报错 ——
  /// 断连是常态，绝大多数断开都没有在途请求。
  int failAll(ProtocolException error) {
    final entries = List.of(_pending.entries);
    _pending.clear();
    for (final entry in entries) {
      if (!entry.value.completer.isCompleted) {
        entry.value.completer.completeError(error);
      }
    }
    return entries.length;
  }
}

/// 一个在途等待：完成器 + 它属于哪个幂等键（只读方法没有键）。
class _Waiting {
  const _Waiting(this.completer, this.requestId);

  final Completer<Object?> completer;
  final String? requestId;
}
