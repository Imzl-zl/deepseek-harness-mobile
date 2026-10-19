/// 轮次大纲的一条（DSH 的 `turnOutline` 投影）。
///
/// 形状逐字对应 `packages/session/session-turn-outline/src/projection.ts:61-75`
/// 的 `turnOutlineEntriesSchema`：`{turn, seq, prompt, response}`，
/// 其中 `prompt` / `response` 都是**预览**（有长度上限，超出截断加 `…`）。
///
/// ## 它给谁用
///
/// 轨迹页的账本：一轮一行。`prompt` 是用户那句、`response` 是助手回复的预览 ——
/// 于是"这一轮问了什么、答了什么"在手机上一眼能看，不必翻消息流。
///
/// ## 为什么不可变
///
/// 与 `ChatItem` 同一条理由：UI 用它做 `==` 判断要不要重建。
library;

/// 一轮的预览。
class TurnOutlineEntry {
  const TurnOutlineEntry({
    required this.turn,
    required this.seq,
    required this.prompt,
    required this.response,
  });

  /// 轮次号（从 1 开始，严格递增 —— DSH 的 schema 用 superRefine 钉住）。
  final int turn;

  /// 这一轮 `turn/start` 事件的会话修订号（用来跳转到那条消息）。
  final int seq;

  /// 用户那句的预览（可能为空串：那一轮还没有人类输入，比如续跑）。
  final String prompt;

  /// 助手回复的预览（可能为空串：那一轮还没结束，或没有文本输出）。
  final String response;

  /// 空预览用这句话，而不是留一片白。
  static const String kEmptyPreview = '（没有预览）';

  /// 展示用提示词；空串给占位。
  String get promptLabel => prompt.isEmpty ? kEmptyPreview : prompt;

  /// 展示用回复；空串给占位。
  String get responseLabel => response.isEmpty ? kEmptyPreview : response;
}
