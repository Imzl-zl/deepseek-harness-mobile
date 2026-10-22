/// 「一轮一个助手头」的投影面：中间步骤不产生助手消息。
///
/// ## 这一组守什么
///
/// 一个 turn 会落**每个 step 一条** `assistant/message`（真机日志
/// `session-4f50055e…`：第 1 步 `reasoning + tool-call`、第 2 步
/// `reasoning + text`）。以前每条都投影成 `MessageItem`，于是屏幕上
/// **一个 turn 里冒出好几个「助手」头像**（用户 2026-10-22 当场指出：
/// 「它一个在输出干嘛分这么多段」）。
///
/// 现在的规则（与 DSH 同形，`assistant-content.ts:9-15` 的
/// `hasAssistantReplyContent`）：
///
/// | 这一步的 content | 投影成 |
/// |---|---|
/// | 有正文（text 非空） | `MessageItem`（助手头 + 正文，思考行内联） |
/// | 只有思考，没有正文 | `ReasoningItem`（**过程行**，没有头像） |
/// | 思考与正文都空（只有 `tool-call`） | `skip`（不占条目） |
library;

import 'package:dsh_mobile/data/projection.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:flutter_test/flutter_test.dart';

Object? _assistant(List<Object?> content) => <String, Object?>{
  'turn': 1,
  'step': 1,
  'message': <String, Object?>{
    'id': 'a1',
    'role': 'assistant',
    'content': content,
  },
};

void main() {
  test('有正文 ⇒ 助手消息，思考一起带在它身上（内联）', () {
    final projection = projectEvent(
      type: 'assistant/message',
      seq: 2,
      data: _assistant(const [
        {'type': 'reasoning', 'text': '想一想'},
        {'type': 'text', 'text': '答案是 42'},
      ]),
      turn: 1,
    );
    final item = projection.item;
    expect(item, isA<MessageItem>());
    final message = item! as MessageItem;
    expect(message.text, '答案是 42');
    expect(message.reasoning, '想一想');
    expect(message.turn, 1);
  });

  test('只有思考、没有正文 ⇒ 过程行（ReasoningItem），不再是助手消息', () {
    final projection = projectEvent(
      type: 'assistant/message',
      seq: 3,
      data: _assistant(const [
        {'type': 'reasoning', 'text': '先看看文件'},
        {'type': 'tool-call', 'name': 'read'},
      ]),
      turn: 1,
    );
    final item = projection.item;
    expect(
      item,
      isA<ReasoningItem>(),
      reason: '有思考没正文的那一步不能画成「一条助手消息」——那是多个助手头的来源',
    );
    expect((item! as ReasoningItem).text, '先看看文件');
  });

  test('思考与正文都空（只有 tool-call） ⇒ 不占条目', () {
    final projection = projectEvent(
      type: 'assistant/message',
      seq: 4,
      data: _assistant(const [
        {'type': 'tool-call', 'name': 'read'},
      ]),
      turn: 1,
    );
    expect(projection.items, isEmpty, reason: '没有可显示内容就不落条目');
  });
}
