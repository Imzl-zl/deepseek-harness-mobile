/// 输入栏"能不能发"的**唯一入口**：一个纯函数，返回"能发 / 该停 / 静默禁用 / 缺什么该说什么"。
///
/// ## 为什么要有这个文件
///
/// 2026-10-27 之前，手机侧的可用性散在三处：`chat_page` 的 `enabled: _hasData && sid != null`、
/// `_send()` 里的两行早退、`DshComposer` 内部的 `canSend` / `stops`。于是"空白会话能直接发、
/// 发出去才失败"这类问题每加一个动作都要再漏一次。桌面只有一处判据，本文件就是那一处的移植：
/// **UI 只消费结论，不再各自判条件**。
///
/// ## 判据逐条对桌面的行（`D:\sudy\github\deepseek-harness\packages\client\ui-conversation`）
///
/// - `skeleton/InputBar.tsx:343`
///   `primaryDisabled = primaryStops ? stopAction === undefined : empty || disabled || machineBusy || uploadsPending`
/// - `skeleton/InputBar.tsx:341`
///   `primaryStops = running && subagent === null && (empty || blocked !== undefined)`
/// - `skeleton/InputBar.tsx:154`
///   `disabled = removed || inert || !live || blocked !== undefined || parentOffline`
/// - `skeleton/ConversationContent.tsx:142`
///   `inert = sessionId === undefined || (hero && chipTitle === undefined)`
///
/// ## 手机侧**不判**的三项（每项都有理由，不是漏做）
///
/// | 桌面条件 | 为什么不判 |
/// |---|---|
/// | `machineBusy`（裁定/提交中） | 手机没有输入机状态机；`_sending` 是"请求在途"，语义不同，按静默禁用处理 |
/// | `uploadsPending` | 手机附件是本地选图，没有宿主的"上传中就绪"阶段 |
/// | `blocked`（owner 提的阻塞） | 本版 DSH 没有任何 feature 调用 `blocks.set`（全仓只有注册表与测试替身），是死分支 |
///
/// 另有一条**永远不进门槛**的：**"未选模型"**。桌面 prompt 路径不校验模型
/// （`packages/api/session-controller/src/commands.ts:305-352`，`requireModel` 只在
/// `selectModel` 里用，`:354-358`），而会话没有记录选择时**活跟随宿主默认**
/// （`src/agent.ts:464-472`）。给手机加"未选模型⇒置灰"就是新增宿主没有的边界。
///
/// ## 文案纪律
///
/// 只有 [ComposerGateBlocked] 带句子；[ComposerGateDisabled] **不带**（桌面在 `empty`
/// 时也只禁用、不弹话）。句子来源只有两个：本文件的 [ComposerGateCopy]（与既有界面同一句），
/// 或调用方传进来的既有说明（子会话只读）。**不在这里新造第二套说法。**
///
/// Note: 设计与被否方案见 `.agents/notes/proposed/2026-10-27-ui-state-design.md` §4。
library;

import '../model/workspace.dart' show kWorkspacePlaceholder;

/// 门槛的结论。
sealed class ComposerGate {
  const ComposerGate();
}

/// 主键是"发送"：能发，且正文非空（附件按"有内容"计，由调用方折进 `draftEmpty`）。
final class ComposerGateSend extends ComposerGate {
  const ComposerGateSend();
}

/// 主键是"停止"：会话在跑、正文空、且拿得到停止动作（桌面 `primaryStops`）。
final class ComposerGateStop extends ComposerGate {
  const ComposerGateStop();
}

/// 静默禁用：正文空、或请求在途。**不解释**（桌面此处不给文案）。
final class ComposerGateDisabled extends ComposerGate {
  const ComposerGateDisabled();
}

/// 禁用**且要说明缺什么**。
final class ComposerGateBlocked extends ComposerGate {
  const ComposerGateBlocked(this.reason, this.sentence);

  final ComposerGateReason reason;

  /// 该说的话：占位文案与"点了被挡"的 toast 用同一句。
  final String sentence;

  /// 这句话是否**替换输入栏的占位文案**。
  ///
  /// 只有"会话已经在、但这条会话缺前提"才替换 —— 也就是
  /// `noWorkspace` / `subagentReadOnly` / `parentOffline`。
  ///
  /// `notPaired` / `noSession` **不替换**：那两档的出路在空态与顶栏（连电脑 /
  /// 打开会话抽屉），而占位文案是**交互基线**的一部分
  /// （`mock/proto/index.html` 的 placeholder；`test/widget_test.dart` 的
  /// 「占位符必须与原型逐字相同」）。换它要先改基线文档，不属于门槛这一批。
  bool get replacesPlaceholder =>
      reason != ComposerGateReason.notPaired &&
      reason != ComposerGateReason.noSession;
}

/// 被挡的原因。**没有"未选模型"这一档，也不许加**（见文件头）。
enum ComposerGateReason {
  /// 还没配对（手机独有：桌面没有这一档，它对应桌面的 `!live`）。
  notPaired,

  /// 没有选中会话（桌面 `inert` 的第一半）。
  noSession,

  /// blank 会话上工作区解析不出来（桌面 `inert` 的第二半）。
  noWorkspace,

  /// 一次性 / 模式未知的子会话（句子由调用方传入）。
  subagentReadOnly,

  /// continuable 子会话的父级不在线（桌面 `parentOffline`）。
  ///
  /// **手机侧是近似判据**：桌面读客户端"父会话有活 agent"，手机只能读
  /// "父会话还在 `session.list` 里"。偏差记在 `docs/`。
  parentOffline,
}

/// 唯一一处句子定义。改文案必须同改 `test/composer_gate_test.dart`。
abstract final class ComposerGateCopy {
  /// 手机独有的一档（桌面不存在"没配对"）。
  static const String notPaired = '还没连上电脑：先在设置里配对';

  /// 与 `ui/chat_page.dart` 的 `_send()` 早退同一句（2026-10-27 之前它是字面量）。
  static const String noSession = '先在列表里选一个会话，再发消息';

  /// 与 hero 上那枚工作区 chip 的占位**同一常量**（`model/workspace.dart`）。
  static const String noWorkspace = kWorkspacePlaceholder;

  /// 手机独有的一档（桌面此处只置灰、不给文案；手机按钮可点，必须说清）。
  static const String parentOffline = '父会话不在线：回到父会话后再发';
}

/// 算一次门槛。纯函数：同样的输入永远同样的结论。
ComposerGate composerGateOf({
  required bool paired,
  required String? sid,
  required bool blankSession,
  required bool workspaceResolved,
  required String? subagentReadOnlySentence,
  required bool parentOffline,
  required bool draftEmpty,
  required bool sending,
  required bool canStop,
}) {
  // ① 被挡的原因，按桌面优先级：insufficient 状态先于 owner 阻塞
  //    （`ConversationContent.tsx:144-146`："The no-workspace state wins when both hold"）。
  final blocked = _blockedOf(
    paired: paired,
    sid: sid,
    blankSession: blankSession,
    workspaceResolved: workspaceResolved,
    subagentReadOnlySentence: subagentReadOnlySentence,
    parentOffline: parentOffline,
  );
  // ② 但桌面先判 `primaryStops`：在跑 + 正文空 + 拿得到停止 ⇒ 主键就是"停止"，
  //    哪怕此刻同时被挡（`:343` 的三元表达式）。
  if (draftEmpty && canStop) return const ComposerGateStop();
  if (blocked != null) return blocked;
  // ③ 静默禁用：没有正文（`empty`）或请求在途（桌面 `machineBusy` 的对应物）。
  if (draftEmpty || sending) return const ComposerGateDisabled();
  return const ComposerGateSend();
}

ComposerGateBlocked? _blockedOf({
  required bool paired,
  required String? sid,
  required bool blankSession,
  required bool workspaceResolved,
  required String? subagentReadOnlySentence,
  required bool parentOffline,
}) {
  if (!paired) {
    return const ComposerGateBlocked(
      ComposerGateReason.notPaired,
      ComposerGateCopy.notPaired,
    );
  }
  if (sid == null || sid.isEmpty) {
    return const ComposerGateBlocked(
      ComposerGateReason.noSession,
      ComposerGateCopy.noSession,
    );
  }
  if (blankSession && !workspaceResolved) {
    return const ComposerGateBlocked(
      ComposerGateReason.noWorkspace,
      ComposerGateCopy.noWorkspace,
    );
  }
  final readOnly = subagentReadOnlySentence;
  if (readOnly != null && readOnly.isNotEmpty) {
    return ComposerGateBlocked(ComposerGateReason.subagentReadOnly, readOnly);
  }
  if (parentOffline) {
    return const ComposerGateBlocked(
      ComposerGateReason.parentOffline,
      ComposerGateCopy.parentOffline,
    );
  }
  return null;
}
