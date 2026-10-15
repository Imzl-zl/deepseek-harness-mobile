/// 连接**终态**失败后的恢复策略 —— `ClientAction` 在 app 层的唯一消费者。
///
/// ## 为什么单独一个类
///
/// 契约 §11 故障矩阵与 `errors.dart` 规定：身份不被认（`notPaired` / `revoked`）
/// 的客户端动作是 `rePair`（清本地凭据 + 回配对页）。但这个动作**在整个 app 层
/// 没有任何执行处** —— 于是设备被停用后，手机只会在"换票被拒 → 退避 → 再换票被拒"
/// 里永远转圈（用户原话："一直显示重连，进不去页面"）。
///
/// 本类是那个缺失的执行处，且**刻意只有一处**：`错误码 → 客户端动作 → 副作用`
/// 的整条映射只在这里写一遍。UI 各处不各自 `if (code == notPaired)` ——
/// 那样迟早有一处漏改，而漏改的那处就是用户卡死的地方。
///
/// ## 为什么副作用全部从缝注入
///
/// 清凭据碰系统密钥库、回配对页碰导航 —— 两者都不能在纯 Dart 单测里跑
/// （`flutter_secure_storage` 在 VM 里抛 `MissingPluginException`）。把它们做成缝，
/// 于是"rePair 时清了凭据且回了配对页"能被**直接断言**，见
/// `test/connection_recovery_test.dart`。
///
/// ## 两条入口,一个动作
///
/// - **议题 2（自动）**：连接终态失败 → `AppModel` 呈递 → [onTerminated]。
/// - **议题 3（手动）**：用户在连接操作 sheet 点"重新配对" → [repair]。
///
/// 两者最终都清凭据 + 回配对页（同一件事），所以收敛到同一个 [repair]。
///
/// 取舍（为何不改协议、为何终态不加新 state、为何手动与自动共用一个出口）见
/// `.agents/notes/implemented/2026-10-15-connection-terminal-failure-goes-to-pairing.md`。
library;

import '../core/errors.dart';

/// 连接终态失败的恢复编排。
///
/// 由装配点（`main.dart`）用真缝构造；测试用假缝直接断言行为。
class ConnectionRecovery {
  ConnectionRecovery({
    required this.clearCredentials,
    required this.openPairing,
    required this.report,
  });

  /// 手动"重新配对（换一台电脑）"后的提示。
  ///
  /// 措辞与连接操作 sheet 里那行的副标题一致（"会清掉本机凭据，需要重新扫码"）——
  /// 一个操作在三处（标签/注释/代码）必须同义，否则就是缺陷。
  static const String manualMessage = '已清掉本机凭据，请重新扫码配对。';

  /// 身份被电脑拒后的提示（**人话，不是裸 401**）。
  ///
  /// 协议今天把"被停用 / 令牌失效 / 中转不认"都归成 401（relay 的
  /// `issue-token.ts` 原话：三者都是 401），手机分不出是哪一种，也**不假装知道**
  /// —— 三者的恢复动作相同（重新扫码），照实说"不再认可本机 + 请重新扫码"即可。
  static const String rejectedMessage = '这台电脑已不再认可本机（可能已停用，或凭据已失效）。请重新扫码配对。';

  /// 清掉本地配对凭据（真实现：`PairingStore.clear()`）。
  final Future<void> Function() clearCredentials;

  /// 跳到配对页并显示一句话（真实现：根 State 的 `_enterPairing`）。
  final void Function(String message) openPairing;

  /// 如实上报一个**处理不了**的终态错误（真实现：SnackBar / 日志）。
  ///
  /// **不许加静默兜底**：映射不到的动作就照实报错，绝不"试试看继续重连" ——
  /// 那正是用户卡在转圈里的成因。
  final void Function(ProtocolException error) report;

  /// 执行一次"重新配对"：清凭据 → 回配对页 → 给一句话。
  ///
  /// 幂等由调用方保证（手动入口点一次；自动入口由 `AppModel` 一个连接周期只呈递一次）。
  Future<void> repair({String message = manualMessage}) async {
    await clearCredentials();
    openPairing(message);
  }

  /// 处置一次连接终态失败（`AppModel.onConnectionTerminated` 接到这里）。
  ///
  /// 只有连接层确认"不再重连"的终态才会到这里；网络类失败由连接层自行退避，不到这里。
  Future<void> onTerminated(ProtocolException error) async {
    switch (error.clientAction) {
      case ClientAction.rePair:
        // 身份不被认（未配对 / 已停用 / 凭据失效）：清凭据 + 回配对页。
        await repair(message: rejectedMessage);
      default:
        // 连接层只会把 rePair 当终态呈递上来；真出现别的动作，照实报错，
        // 不静默兜底、不"试试看重连"。
        report(error);
    }
  }
}
