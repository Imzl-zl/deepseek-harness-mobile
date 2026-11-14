/// 这台手机**想走哪条路**（设备级，跨电脑保留）。
///
/// ## 它为什么是一个单独的概念
///
/// 电脑侧回答"此刻哪条路活着"（通道注册表的 `running` / `connected`），
/// 手机侧回答"我想走哪条"—— 两者混在一起就会出现
/// "关掉中转却仍出带中转的码"这种自相矛盾。
///
/// 这个枚举**同时**决定两件事，不再有第二套偏好：
///
/// - 配对时先拨哪条（`core/pairing_flow.dart` 的 `beginPairing`）；
/// - 连上之后自动拨号的候选集合（`core/endpoint.dart` 的 `endpointsForPolicy`）。
///
/// 边界：它是**长期意图**；"点一条地址立刻用它连"是本次覆盖（`useEndpointNow`），
/// 不改这里。取舍与门槛见
/// `.agents/notes/proposed/2026-11-13-connection-route-model.md`。
library;

/// 三档。`auto` 是默认：能直连就直连，直连全不通才走中转。
enum RoutePolicy {
  /// 直连优先、失败回落中转（回落在拨号层与配对层都说出来）。
  auto('自动', 'auto'),

  /// 只用直连：中转不参与拨号。不通就明说，不偷偷改路。
  directOnly('只用直连', 'direct'),

  /// 只用中转：直连不参与拨号。
  relayOnly('只用中转', 'relay');

  const RoutePolicy(this.label, this.wire);

  /// 设置页与连接方式页显示的名字。
  final String label;

  /// 落盘值（`device.route_policy`）。`direct` / `relay` 沿用旧键
  /// `device.pairing_prefer` 的取值，迁移因此是恒等映射。
  final String wire;

  /// 认不出回 `null`（调用方保持默认，不猜）。
  static RoutePolicy? fromWire(Object? raw) {
    if (raw is! String) return null;
    for (final value in values) {
      if (value.wire == raw) return value;
    }
    return null;
  }
}
