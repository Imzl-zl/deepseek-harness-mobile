/// 一次 assistant 流式尝试的内容快照 —— **与持久条目同形**。
///
/// ## 为什么必须是"两段"而不是"一段文本"
///
/// 宿主的流式帧带的是**块级事件**（`packages/llm/llm/src/assistant-stream.ts:44`）：
///
/// ```text
/// {type:'block-start', index, blockType:'text'|'reasoning'|'tool-call'}
/// {type:'text-delta', index, text}
/// {type:'reasoning-delta', index, text}
/// {type:'tool-call-delta', index, id, name, argumentsDelta}
/// {type:'block-end', index, block}
/// {type:'usage'|'finish'}
/// ```
///
/// 而持久 `assistant/message` 的 `content` 同样是块表，投影层把它折成两段
/// （[reasoningOf] / [textOfContent]，见 `data/projection.dart`）。若流式这一侧
/// 把两种 delta 都倒进同一个缓冲区，思考就会**冒充正文**流出来：
/// 生成中是一段不可折的正文，落定后又变回折叠的「思考过程」。
///
/// 所以这里按 `chunk.type` 分流，产出的形状与持久那一侧一致：
/// `reasoning` 一段、`text` 一段。**块的顺序不保留** —— 持久那一侧也不保留
/// （两个折串函数都是"全部同类块拼接"），两边同形才不会在落定的那一帧跳一下。
///
/// Note: 取舍与替代方案见
/// `.agents/notes/implemented/2026-11-07-live-message-shape.md`。
library;

import 'dart:convert';

/// 流式尝试的内容：思考一段、正文一段。
class LiveMessage {
  const LiveMessage({this.reasoning = '', this.text = ''});

  /// 思考（`reasoning-delta` 拼接）。
  final String reasoning;

  /// 正文（`text-delta` 拼接）。
  final String text;

  /// 两段都空 = 这一步开始了但还没有可显示的内容。
  bool get isEmpty => reasoning.isEmpty && text.isEmpty;

  /// 有东西可显示。
  bool get isNotEmpty => !isEmpty;

  @override
  bool operator ==(Object other) =>
      other is LiveMessage &&
      other.reasoning == reasoning &&
      other.text == text;

  @override
  int get hashCode => Object.hash(reasoning, text);

  @override
  String toString() =>
      'LiveMessage(reasoning: ${reasoning.length} 字, text: ${text.length} 字)';
}

/// 每会话的流式累加器（`app-channel-client.md` §2.2）。
///
/// 读法（**顺序即语义**）：
/// - `stream` 变大 ⇒ 换流（上一次尝试结束），重置累加器；
/// - `rev == last + 1` ⇒ 追加；
/// - `rev` 跳跃 ⇒ **丢弃该流已累积内容并停止渲染**，等持久 `assistant/message`
///   到达（自愈，**不请求重传**）。
///
/// 它**不碰任务输出**（`job` 帧）：任务输出的"修订号"是字节偏移、会跳号，
/// 而这个累加器把跳号读成"丢流" —— 两者不能共用一个累加器（契约 §3 的术语表）。
class LiveMessageAssembler {
  int? _stream;
  int? _lastRev;
  final StringBuffer _reasoning = StringBuffer();
  final StringBuffer _text = StringBuffer();

  /// 当前累积的内容（**不是**第二个来源：每次读都从缓冲区折出来）。
  LiveMessage get message =>
      LiveMessage(reasoning: _reasoning.toString(), text: _text.toString());

  /// 当前流 id。
  int? get stream => _stream;

  /// 最近一次修订号。
  int? get lastRev => _lastRev;

  /// 收一帧 `live`。
  ///
  /// @returns 内容是否变化（`false` = 跳号，或这一帧没带可显示的增量）。
  bool accept({
    required int stream,
    required int rev,
    required String payload,
  }) {
    if (_stream != stream) {
      // 换流：上一次尝试结束了。重置累加器（旧内容由持久事件负责替换）。
      _stream = stream;
      _lastRev = null;
      _reasoning.clear();
      _text.clear();
    }
    final last = _lastRev;
    _lastRev = rev;
    if (last != null && rev != last + 1) {
      // 跳跃：丢弃已累积内容并**停止渲染**，等持久事件到达。
      _reasoning.clear();
      _text.clear();
      return false;
    }

    // 载荷形状见 `session-subscriptions.ts` 的 `expand`：`{type, time?, chunk?, ...}`。
    //
    // `start`（换了一次尝试）与 `end`（这次尝试结束）都没有 `chunk`：
    // 它们只推进修订号，不产生内容。
    final chunk = _chunkOf(payload);
    final type = chunk['type'];
    final text = chunk['text'];
    if (text is! String || text.isEmpty) return false;
    // **只认这两类**：`tool-call-delta` 的参数不是正文，`block-*` 是块边界。
    // 表外的类型一律不显示 —— 不猜它"大概也是文字"。
    switch (type) {
      case 'text-delta':
        _text.write(text);
        return true;
      case 'reasoning-delta':
        _reasoning.write(text);
        return true;
      default:
        return false;
    }
  }

  /// 取载荷里的 `chunk` 对象；读不懂时返回空表（**停在当前内容**，不断连）。
  static Map<Object?, Object?> _chunkOf(String payload) {
    try {
      final parsed = jsonDecode(payload);
      if (parsed is Map) {
        final chunk = parsed['chunk'];
        if (chunk is Map) return chunk;
      }
    } catch (_) {
      // 载荷读不懂不该断连（它只是流式输出）。
    }
    return const <Object?, Object?>{};
  }
}
