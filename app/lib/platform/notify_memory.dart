/// 内存实现：单测与桌面调试用（**不碰任何平台通道**）。
///
/// 它把每次调用**记下来**而不是"假装成功什么都不做" —— 通知这件事的判据是
/// "该贴的贴了、该撤的撤了"，只有在能数出这些动作时才算验过
/// （与 `FakeSyncClient` 同一条纪律：替身要能证明调用发生了）。
library;

import 'dart:async';

import '../core/notify.dart';

class MemoryNotify implements NotifyPort {
  MemoryNotify({this.granted = true});

  /// 通知权限。测试里改它来验"没权限就不起服务"。
  bool granted;

  /// 此刻在跑的前台服务数（起停是否成对，靠它断言）。
  int keepAliveCount = 0;

  /// 贴过的通知（按调用顺序；撤销不会从这里删 —— 那是另一份记录）。
  final List<AttentionNotice> shown = <AttentionNotice>[];

  /// 撤销过的 id（含重复撤销，便于发现"撤了两次"）。
  final List<int> cancelled = <int>[];

  int cancelAllCount = 0;

  int channelSettingsCount = 0;

  /// 贴上去的那些（`show` 之后仍在的），按 id。
  final Map<int, AttentionNotice> visible = <int, AttentionNotice>{};

  final _approvals = StreamController<NotifyApproval>.broadcast();

  @override
  Stream<NotifyApproval> get approvals => _approvals.stream;

  /// 测试驱动：模拟用户在通知上按了按钮。
  void emitApproval(String itemId, {bool allowedOnce = true}) =>
      _approvals.add(NotifyApproval(itemId: itemId, allowedOnce: allowedOnce));

  @override
  Future<NotifyStatus> status() async =>
      NotifyStatus(granted: granted, keepAlive: keepAliveCount > 0);

  @override
  Future<bool> requestPermission() async => granted;

  @override
  Future<void> startKeepAlive({
    required String title,
    required String text,
  }) async {
    keepAliveCount += 1;
  }

  @override
  Future<void> stopKeepAlive() async {
    if (keepAliveCount > 0) keepAliveCount -= 1;
  }

  @override
  Future<bool> show(AttentionNotice notice) async {
    if (!granted) return false;
    shown.add(notice);
    visible[notice.id] = notice;
    return true;
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    visible.remove(id);
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCount += 1;
    visible.clear();
  }

  @override
  Future<void> openChannelSettings() async {
    channelSettingsCount += 1;
  }

  @override
  Future<void> close() async {
    await _approvals.close();
  }
}
