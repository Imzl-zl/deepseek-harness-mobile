/// 「读电脑侧的东西」的能力口：**端口声明在这里，实现在 `wire/`**。
///
/// ## 为什么不是 `SyncClient` 上的成员
///
/// `SyncClient` 是全仓二十多个替身 `implements` 的端口 —— 往它上面加一个抽象方法，
/// 就得逐处补空实现，而它们只测状态与投影、根本不关心"读哪台电脑的哪张目录"。
/// `core/sync_client.dart` 的 `LinkControl` 已经把这条理由写过一次，这里是同一个手法：
/// **小接口 + `is` 判定**（`AppModel` 拿 `client is HostRpc` 取它）。
///
/// ## 为什么方法上还要收一个 `SyncClient`
///
/// 端口照抄 `wire/rpc/*.dart` 里 `loadXxx(client, …)` 的形状：发请求需要它。
/// 能力本身是**跟着客户端走的**（连接层 `implements HostRpc`，工厂 `hostRpc` 收到
/// 的就是那条连接），所以生产里传进来的那个永远与能力所属的连接是同一个对象 ——
/// 这不是"两处水位"，只是形状一致。
///
/// ## 一个方法族一批
///
/// 会话族（本轮）→ 目录族 → 预览族 → 收尾，见
/// `.agents/notes/proposed/2026-11-06-p1b-host-rpc-port.md` 的「落地顺序」；
/// 会话族落地的代价与边界见
/// `.agents/notes/implemented/2026-11-06-p1b-batch1-session-family.md`。
library;

import 'session_projections.dart';
import 'snapshot_digest.dart';
import 'sync_client.dart';

/// 读电脑侧的只读快照与目录（`data/` 认识的那一面，不认识线上形状）。
///
/// 失败一律走"`null` 正文 + `WireDiagnostics` 计一次数"（诊断照旧由 `wire/` 那层报，
/// 它正是知道形状的那一处）；三态（正文 / 没变 / 读不出）由 [SnapshotReply] 表达。
abstract interface class HostRpc {
  /// 读一个会话的投影包（`session.projections`，契约 §5.7）。
  ///
  /// 返回 `notModified` 时调用方**什么都不做**（不清数据、不报错、不通知）；
  /// 正文 `null` 才是"这次读不出来" —— 两者在界面上是相反的两件事，
  /// 压成同一档会让摘要命中时被当成失败（目录进 error 态并落一条错误）。
  /// 带内容摘要：键含 `sid`，不同会话的投影包是两个包。
  Future<SnapshotReply<SessionProjections?>> projections(
    SyncClient client, {
    required String sid,
  });
}
