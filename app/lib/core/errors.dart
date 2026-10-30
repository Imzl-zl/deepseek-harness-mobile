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

  /// 设置写在 revision 上过期了：重新 describe 再改（不要拿旧 patch 重发）。
  refreshSettings,

  /// 中转不可达：展示离线态。
  showOffline,

  /// 电脑已被**另一台**设备占用（`device/busy`）：**不自动重连**，
  /// 显示占用者 + 给手动重试与"切回上一台"。
  ///
  /// 与 [backoffRetry] 的差别就是"要不要自己一遍遍撞门"：占用者离开后自动连上
  /// 等于替用户决定"现在就切过来"（决策 6 / 9）。见 `proposed/2026-10-29-one-phone-many-computers.md`。
  busyWait,

  /// 电脑侧不支持这个能力：置灰（能力位模型的延伸）。
  disable,

  /// **我们自己的缺陷**：参数被宿主拒（`gateway/bad-request`）。原样显示并记录，
  /// 绝不让用户重试 —— 重试只会同样失败，而用户会以为是网络问题。
  reportDefect,

  /// 未归类：记日志并重试。
  logAndRetry,
}

/// 封闭错误码表。`wire` 是线上字符串（契约 §3.1 的原样拼写）。
///
/// ## 表里有两类码，别混
///
/// 1. **协议层**（`protocol/*`、`relay/*`、`connector/*`、`rate-limited`）—— 连接自己的事，
///    动作是连接级的（重连 / 回配对页 / 退避）。
/// 2. **宿主层**（`session/*`、`settings/*`、`credentials/*`、`gateway/*`、`workspace/*`、
///    `agent-preset/*`）—— DSH 真实返回的码，描述"这一次操作为什么没成"。
///
/// 第 2 类**必须收全**：漏一个不会"走 default"，而是被 [fromWire] 归成 [internal]
/// → `logAndRetry` → 用户对着一个永远重试也不好的操作反复点。本仓栽过一次
/// （`not-paired` 被报成 `bad-frame`，用户卡在重试上）。
/// 与电脑侧 `connector/src/protocol/errors.ts` 的 `ERROR_TABLE` **逐字一致**，
/// 由 `connector/tests/error-table-parity.test.ts` 断言两边相等。
enum ErrorCode {
  // ---- 协议层 ----
  unsupportedVersion(
    'protocol/unsupported-version',
    ClientAction.upgradeRequired,
  ),
  notPaired('protocol/not-paired', ClientAction.rePair),
  revoked('protocol/revoked', ClientAction.rePair),
  badFrame('protocol/bad-frame', ClientAction.reconnectOnce),
  replay('protocol/replay', ClientAction.reconnectOnce),

  /// 这台电脑已被另一台**有效**设备占用（独占 1:1）：不踢人，等用户动作。
  ///
  /// 关闭理由可能带占用者说明（`device/busy <占用者>`，见契约 §4.1）。
  deviceBusy('device/busy', ClientAction.busyWait),
  rateLimited('rate-limited', ClientAction.backoffRetry),
  sessionNotFound('session/not-found', ClientAction.dropFromList),
  sessionWindowMissed('session/window-missed', ClientAction.snapshot),
  sessionRevisionNewer('session/revision-newer', ClientAction.snapshot),
  interactionNotPending('interaction/not-pending', ClientAction.refreshPending),
  jobNotFound('job/not-found', ClientAction.refreshJobs),
  settingsReadOnly('settings/read-only', ClientAction.disableAndAnnotate),
  relayOffline('relay/offline', ClientAction.showOffline),
  connectorUnsupported('connector/unsupported', ClientAction.disable),

  // ---- 宿主层:DSH 在这些方法上真实返回的码(2026-10-09 逐条读源码核实) ----
  /// 电脑正忙着（`session-controller/src/commands.ts:372`）：稍后重发。
  sessionAgentBusy('session/agent-busy', ClientAction.backoffRetry),

  /// 还没选模型（`:381`）：发送前置灰并提示。
  sessionModelUnavailable(
    'session/model-unavailable',
    ClientAction.disableAndAnnotate,
  ),

  /// 附件不被当前模型接受（`:370,:421`）：去掉那个附件。
  sessionAttachmentInvalid(
    'session/attachment-invalid',
    ClientAction.disableAndAnnotate,
  ),

  /// 当前轮次已不能 steer（`:478`）：排队项作废，刷新待处理。
  sessionSteerUnavailable(
    'session/steer-unavailable',
    ClientAction.refreshPending,
  ),

  /// 排队项已不在队列（`:455,:474`）：刷新待处理。
  sessionQueueItemNotFound(
    'session/queue-item-not-found',
    ClientAction.refreshPending,
  ),

  /// 会话被别的写者占着（`:536`）：稍后。
  sessionWriterHeld('session/writer-held', ClientAction.backoffRetry),

  /// 预设等冲突（`:546`）：这次建不出来，标注原因。
  sessionConflict('session/conflict', ClientAction.disableAndAnnotate),

  /// 新建会话时 workspace 不存在（`commands.ts:114`）。
  workspaceNotFound('workspace/not-found', ClientAction.disableAndAnnotate),

  /// 归档被拒：会话还有在跑的活动（轮次 / 子智能体 / 后台任务）
  /// （`workspace-controller/src/commands.ts:172-178`）。**不是故障**：
  /// 手机据此弹「停止并归档」，带 `stopActivity` 重发。
  workspaceSessionActive(
    'workspace/session-active',
    ClientAction.disableAndAnnotate,
  ),

  /// agent 预设冲突（`commands.ts:539`）。
  agentPresetConflict('agent-preset/conflict', ClientAction.disableAndAnnotate),

  // ---- 文件预览：读得懂但打不开（**不是连接问题**）----
  //
  // 桌面按这四个码换文案与动作（`ui-sidebar-documentpreview/src/client/failure-line.ts:24-56`、
  // `locales.ts:28-31`），手机照同一套：都是"这一份文件不能这样看"，
  // 所以是置灰并说明，不是重试。

  /// 不是文本（二进制 / 编码不认识）：`该格式文件暂时无法预览`。
  workspaceFileNotText(
    'workspace-file/not-text',
    ClientAction.disableAndAnnotate,
  ),

  /// 单页超过宿主上限：`单页内容超过上限，无法读取`。
  workspaceFileTooLarge(
    'workspace-file/too-large',
    ClientAction.disableAndAnnotate,
  ),

  /// 文件不存在：只说一次，不重试。
  workspaceFileNotFound(
    'workspace-file/not-found',
    ClientAction.disableAndAnnotate,
  ),

  /// 不是普通文件（目录 / 设备 / 管道）：没有可显示的内容。
  workspaceFileNotRegularFile(
    'workspace-file/not-regular-file',
    ClientAction.disableAndAnnotate,
  ),

  /// 我们发的参数宿主不认（`commands.ts:107` 等）= **我们的缺陷**，
  /// 要响亮失败并记录，绝不是让用户重试。
  gatewayBadRequest('gateway/bad-request', ClientAction.reportDefect),

  /// 调用被中止：等价于连接层的事。
  gatewayCancelled('gateway/cancelled', ClientAction.reconnectOnce),

  /// 宿主内部错：稍后。
  gatewayInternal('gateway/internal', ClientAction.backoffRetry),

  /// 设置被拒（`settings-controller/src/index.ts:267`）。
  settingsRejected('settings/rejected', ClientAction.disableAndAnnotate),

  /// `expectedRevision` 过期（设置冲突）：重新 describe 再改。
  settingsConflict('settings/conflict', ClientAction.refreshSettings),

  /// 凭据被拒（`settings-controller/src/credentials.ts`）。
  credentialRejected('credential/rejected', ClientAction.disableAndAnnotate),

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

/// 切一条**电脑侧拒绝的关闭理由**（契约 §4.1：`协议码` 或 `协议码 说明`）。
///
/// 电脑侧在握手层拒绝时用关闭码 4003 + 这段文本送达，理由可能带一句给人看的说明
/// （例：`device/busy 我的手机`）。**码是第一个空格之前的全部字节** ——
/// 所以这里只按第一个空格切，不按空白切、也不做任何修剪：
/// 切坏了就会归成 [ErrorCode.internal]，用户看到的是"未知错误"。
({String wire, String? detail}) splitCloseReason(String reason) {
  final at = reason.indexOf(' ');
  if (at <= 0) return (wire: reason, detail: null);
  final detail = reason.substring(at + 1).trim();
  return (
    wire: reason.substring(0, at),
    detail: detail.isEmpty ? null : detail,
  );
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
