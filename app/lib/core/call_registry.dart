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
  final Map<String, Completer<Object?>> _pending = {};

  /// 当前在途请求数（诊断与测试用）。
  int get pending => _pending.length;

  /// 登记一个在途请求，返回它的完成器。
  Completer<Object?> register(String id) {
    final completer = Completer<Object?>();
    _pending[id] = completer;
    return completer;
  }

  /// 撤销登记（发送失败时调，避免留下一个永远不兑现的条目）。
  void unregister(String id) => _pending.remove(id);

  /// 应答到达：兑现并移除。返回 `false` 表示"没有人在等这个 id"
  /// （迟到、重复、或属于上一条连接的应答）—— 调用方据此忽略。
  bool resolve(String id, {required Object? result, ProtocolException? error}) {
    final completer = _pending.remove(id);
    if (completer == null) return false;
    if (error != null) {
      completer.completeError(error);
    } else {
      completer.complete(result);
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
      if (!entry.value.isCompleted) entry.value.completeError(error);
    }
    return entries.length;
  }
}
