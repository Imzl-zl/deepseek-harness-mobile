/// **按电脑池化 `AppModel`**：每台一份，切走**不拆**。
///
/// ## 为什么池化
///
/// "切换电脑"原来 = 换凭据槽 + 重新装配 + `dispose` 旧的。于是切回 A 时 A 从零开始：
/// 重新拨号、重新握手、重新订阅、信息流重刷 —— 而 A 一直是好的，用户只是看了一眼 B。
/// 一台手机配多台电脑是正常用法（`docs/subsystems/app-channel-client.md` §6.4 的 N:M），
/// 所以"同时在线"必须成立：切换只是**换可见指针**。
///
/// ## 什么时候真的 dispose
///
/// 只在**移除这台**：解绑 / 吊销 / 凭据被换掉（重新配对）/ app 退出。
/// 移除只影响那一台 —— 别的台的通知、前台服务与 socket 都不动
/// （通知 id 带电脑前缀、前台服务按"还有没有人在要"起停，见
/// `data/app_services.dart`）。
///
/// **不设上限、不设闲置回收**：宿主没有这种边界（"同时连几台是用户的事"，
/// `docs/subsystems/app-channel-client.md` §6.4），加上去就是新增边界。
/// 代价是内存随台数涨（每台一份会话缓存），那是用户自己配了几台的直接后果。
///
/// ## 它不做什么
///
/// 不装配：装配只有 `main.dart` 一处知道用哪个实现，所以 [acquire] / [replace]
/// 要调用方把"怎么造一个"传进来。它也不读凭据、不认识 `PairingStore`。
///
/// 取舍见 `.agents/notes/implemented/2026-11-06-s4-host-sessions.md`。
library;

import 'app_model.dart';

class HostSessions {
  final Map<String, AppModel> _live = <String, AppModel>{};

  /// 池子里活着的那些（生命周期广播要给每一台）。
  Iterable<AppModel> get live => _live.values;

  /// 池子里有哪几台（`hostId` = 那台电脑的 Ed25519 公钥）。
  Iterable<String> get hostIds => _live.keys;

  /// 这台的那一份（没有就是 `null`）。
  AppModel? of(String hostId) => _live[hostId];

  bool has(String hostId) => _live.containsKey(hostId);

  /// 拿到这台的模型：**已经在线就原样返回**（不重启、不重读、不 dispose）。
  ///
  /// 返回的 `created` 表示这是新装配的 —— 调用方据此决定要不要
  /// `loadUiState()`（首帧前读回本地 UI 状态，只该在第一次装配时做）与 `start()`。
  Future<({AppModel app, bool created})> acquire(
    String hostId, {
    required Future<AppModel> Function() build,
  }) async {
    final existing = _live[hostId];
    if (existing != null) return (app: existing, created: false);
    final app = await build();
    _live[hostId] = app;
    return (app: app, created: true);
  }

  /// 换掉这一台：装配好的新模型顶替旧的，旧的 **dispose**。
  ///
  /// 重新配对走这条：旧模型手里是**旧 token**，复用它等于拿作废的凭据去连，
  /// 而症状是"配上了、一直连不上"。装配失败时旧的原样留着（异常往上抛）。
  Future<AppModel> replace(
    String hostId, {
    required Future<AppModel> Function() build,
  }) async {
    final app = await build();
    _live.remove(hostId)?.dispose();
    _live[hostId] = app;
    return app;
  }

  /// 移除这一台（解绑 / 吊销 / 删除）：**只 dispose 它**。
  ///
  /// 不在池子里就是空操作（重复移除不会抛）。
  void forget(String hostId) => _live.remove(hostId)?.dispose();

  /// app 走了：全部收掉。
  void disposeAll() {
    for (final app in _live.values.toList()) {
      app.dispose();
    }
    _live.clear();
  }
}
