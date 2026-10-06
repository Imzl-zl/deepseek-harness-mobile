/// 封闭错误码表（契约 §3.1）。
///
/// **表是封闭的**：不在表内的错误一律归 [ErrorCode.internal]，不允许各端自造码 ——
/// 否则手机侧无法对错误做穷尽分支（`switch` 会漏），而漏掉的那一支通常正是要靠它
/// 决定「重试 / 回配对页 / 置灰」的那一支。
///
/// ## 比电脑侧多做的一件事：码是**枚举**而不是字符串
///
/// 电脑侧（`connector/src/protocol/errors.ts`）的构造函数收 `string` 再归一 ——
/// 那是为了"对端给的未知码不逼我们走 default"。但同一条归一化用在**我们自己**构造的
/// 码上时，会把拼错的码（`'protocol/bad-fram'`）**静默降级成 `internal`**：
/// 编译通过、测试可能也过，只是错误类别变了，而类别决定下一步动作。
///
/// 所以这里分开：
/// - **我们自己构造**时用枚举 → 拼错是**编译错误**；
/// - **对端给的**码走 [ErrorCode.fromWire] → 未知归 `internal`（封闭表的纪律）。
///
/// 这一条不是洁癖：本项目刚踩过"`not-paired` 被报成 `bad-frame`"的 bug
/// （见 `.agents/notes/implemented/2026-10-02-mobile-core-crypto-choice.md`），
/// 而两者的客户端动作是"回配对页"与"重试"——**报错类别错了用户就永远卡在重试上**。
library;

/// 客户端对该错误的处置。
///
/// 刻意是**封闭枚举**而不是自由文本：手机端据此分支，新增行为要改这张表，
/// 不会漏在某个 `switch` 的 `default` 里。
enum ClientAction {
  /// 协议版本不支持：必须升级 App。
  upgradeRequired,

  /// 设备身份不被接受（未配对 / 已吊销）：清除本地凭据，回配对页。
  rePair,

  /// 这一帧不可接受：重连一次即可（重连会换密钥与 `fc`）。
  reconnectOnce,

  /// 被限流：退避后重试（不是"永久失败"）。
  backoffRetry,

  /// 本地水位与电脑侧对不上：走一次快照。
  snapshot,

  /// 会话不存在了：从列表里摘掉。
  dropFromList,

  /// 待处理集合过期：刷新一次。
  refreshPending,

  /// 任务不存在了：刷新任务列表。
  refreshJobs,

  /// 这一项在电脑侧只读：置灰并标注原因（不要反复试）。
  disableAndAnnotate,

  /// 中转不可达：展示离线态。
  showOffline,

  /// 电脑侧不支持这个能力：置灰（能力位模型的延伸）。
  disable,

  /// 未归类：记日志并重试。
  logAndRetry,
}

/// 封闭错误码表。`wire` 是线上字符串（契约 §3.1 的原样拼写）。
enum ErrorCode {
  unsupportedVersion(
    'protocol/unsupported-version',
    ClientAction.upgradeRequired,
  ),
  notPaired('protocol/not-paired', ClientAction.rePair),
  revoked('protocol/revoked', ClientAction.rePair),
  badFrame('protocol/bad-frame', ClientAction.reconnectOnce),
  replay('protocol/replay', ClientAction.reconnectOnce),
  rateLimited('rate-limited', ClientAction.backoffRetry),
  sessionNotFound('session/not-found', ClientAction.dropFromList),
  sessionWindowMissed('session/window-missed', ClientAction.snapshot),
  sessionRevisionNewer('session/revision-newer', ClientAction.snapshot),
  interactionNotPending('interaction/not-pending', ClientAction.refreshPending),
  jobNotFound('job/not-found', ClientAction.refreshJobs),
  settingsReadOnly('settings/read-only', ClientAction.disableAndAnnotate),
  relayOffline('relay/offline', ClientAction.showOffline),
  connectorUnsupported('connector/unsupported', ClientAction.disable),

  /// 兜底：**任何不在表里的码都归这里**（封闭表的纪律）。
  internal('internal', ClientAction.logAndRetry);

  const ErrorCode(this.wire, this.clientAction);

  /// 线上字符串（对端看到的就是它）。
  final String wire;

  /// 手机端该做什么。与码一起定死，避免各端自己解释同一个码。
  final ClientAction clientAction;

  /// 从线上字符串解析。
  ///
  /// **不认识的码归 [ErrorCode.internal]** —— 表是封闭的，透传一个我们不认识的码
  /// 等于逼调用方走 `default` 分支，那正是这张表要消灭的东西。
  static ErrorCode fromWire(String wire) {
    for (final code in ErrorCode.values) {
      if (code.wire == wire) return code;
    }
    return ErrorCode.internal;
  }

  /// 这个码是不是"表里有名字的"（即不是兜底）。
  ///
  /// 用于自检与日志：`internal` 既可能是真内部错误，也可能是"对端给了个新码"。
  bool get isKnown => this != ErrorCode.internal;
}

/// 协议错误。
///
/// 与电脑侧的 `ProtocolError` 对应，但 `code` 是**枚举**（见文件头）。
/// 调用方按 `code.clientAction` 决定下一步，而不是自己解释字符串。
class ProtocolException implements Exception {
  /// [code] 用枚举 —— 拼错是编译错误，不会静默降级成 `internal`。
  const ProtocolException(this.code, this.message);

  /// 从**对端给的**线上码构造（未知归 `internal`）。
  factory ProtocolException.fromWire(String wire, String message) =>
      ProtocolException(ErrorCode.fromWire(wire), message);

  final ErrorCode code;
  final String message;

  /// 客户端该做什么（直接转发码表，避免调用方再查一次）。
  ClientAction get clientAction => code.clientAction;

  @override
  String toString() => 'ProtocolException(${code.wire}): $message';
}
