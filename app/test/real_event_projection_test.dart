/// 真实事件形状的投影回归。
///
/// ## 为什么要有这一组
///
/// 2026-10-19 真机复现的渲染缺陷（用户原话"会话渲染只有思考，工具调用，
/// 没有输出，运行命令啥的"）根因是**我们以为的事件形状与真形状不同**：
///
/// - `tool/result` 的真实载荷**不带 `name`**（只有 `role` / `source` /
///   `toolCallId` / `content` / `isError` / `id`），而投影从结果里读名字 ——
///   于是结果一到达，卡片上的 `read` 被覆盖成"工具"、参数行被覆盖成
///   `role, source, toolCallId, conten…`（JSON 键名清单）。
/// - `assistant/message` 的 content 里 `reasoning` / `text` / `tool-call`
///   三种块并存，且**可能一个 `text` 块都没有**（纯工具回合）——
///   那时"没有正文"是事实，不是缺陷。
///
/// 手写形状的用例对这些一无所知（它们只会复述实现的假设）。
/// 所以这里的断言值全部来自**真机落盘的会话日志**
/// （`app/test/fixtures/real-session-events.json`，DSH 0.2.1 真形状），
/// 而投影逻辑的正确性判据是 DSH Web 的同一处源码：
/// `packages/client/ui-chat/src/client/conversation-nodes/tool.ts:100-118`
/// 的 `rootResult(match, previous)` —— **结果继承调用的名字与参数**。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/data/projection.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:flutter_test/flutter_test.dart';

/// 读真事件 fixture（字段一个都没改，只有两处长文本被截断并标注）。
Map<String, Object?> _fixture() {
  final raw = File('test/fixtures/real-session-events.json').readAsStringSync();
  return jsonDecode(raw) as Map<String, Object?>;
}

/// 把 fixture 里的一条事件喂给投影（[previous] 由调用方给）。
ChatItem _project(Map<String, Object?> event, {ChatItem? previous}) =>
    projectEvent(
      type: event['type'] as String,
      seq: event['seq'] as int,
      data: event['data'],
      time: event['time'] as int,
      previous: previous,
    ).item!;

void main() {
  group('真形状：tool/call → tool/result 的继承', () {
    test('结果到达后卡片仍叫 read、参数仍是调用那一句', () {
      final fixture = _fixture();
      final call =
          _project(fixture['toolCall'] as Map<String, Object?>) as ToolCallItem;
      // 调用自己带着名字与参数（这一半一直是对的）。
      expect(call.name, 'read');
      expect(call.status, ToolCallStatus.running);
      expect(call.summary, contains('memory.md'));

      // **真结果载荷里没有 name**：这是缺陷的根，先钉住这个事实。
      final resultData =
          (fixture['toolResult'] as Map<String, Object?>)['data']
              as Map<String, Object?>;
      final resultMessage = resultData['message'] as Map<String, Object?>;
      expect(
        resultMessage.containsKey('name'),
        isFalse,
        reason: '真结果不带 name —— 名字只能从 tool/call 继承（DSH rootResult）',
      );

      final result =
          _project(
                fixture['toolResult'] as Map<String, Object?>,
                previous: call,
              )
              as ToolCallItem;
      // 继承调用：名字与参数都不许被结果覆盖掉。
      expect(result.name, 'read', reason: '结果继承调用的名字');
      expect(result.summary, call.summary, reason: '参数行仍用调用那一句');
      expect(result.status, ToolCallStatus.completed);
      // 结果正文进明细（展开才看得见）。
      expect(result.detail, contains('dsh-mobile 项目状态'));
      expect(result.detail, isNot(contains('role, source')));
    });

    test('没有 previous（历史只落到结果）时不编名字，也不摊平键名', () {
      final fixture = _fixture();
      final result =
          _project(fixture['toolResult'] as Map<String, Object?>)
              as ToolCallItem;
      // DSH 同处是 `name: previous?.name ?? ''`：没有调用就没有名字。
      expect(result.name, '工具');
      // **不许把结果消息摊平成一串键名**（真机上的 `role, source, toolCallId, conten…`）。
      expect(result.summary, isEmpty);
      expect(result.detail, isNotEmpty, reason: '输出本身仍然要能看');
    });

    test('同一个 delta 里先 call 后 result：合并仍然成立', () {
      // AppModel 的 `inBatch` 路径：store.upsertAll 在整批之后才发生，
      // 所以结果要找的"前一个条目"来自本批已投影的映射。
      final fixture = _fixture();
      final call =
          _project(fixture['toolCall'] as Map<String, Object?>) as ToolCallItem;
      final result =
          _project(
                fixture['toolResult'] as Map<String, Object?>,
                previous: call,
              )
              as ToolCallItem;
      expect(result.itemId, call.itemId, reason: '结果与调用同一条目');
      expect(result.name, 'read');
    });
  });

  group('真形状：assistant/message 的三种块', () {
    test('text 块是正文、reasoning 块是思考过程、tool-call 块不是正文', () {
      final fixture = _fixture();
      final item =
          _project(fixture['assistant'] as Map<String, Object?>) as MessageItem;
      expect(item.role, MessageRole.assistant);
      // 正文只来自 `type == 'text'` 的块。
      expect(item.text, contains('Round 1 只做了调研'));
      // 思考过程单独一栏，不混进正文。
      expect(item.reasoning, isNotEmpty);
      expect(item.text, isNot(contains('The user has given me')));
      // **没有附件**：这条消息的块里没有 image/file。
      expect(item.attachmentCount, 0);
    });
  });

  group('真形状：user/message 带图片', () {
    test('图片只计数，正文照常', () {
      final fixture = _fixture();
      final item =
          _project(fixture['user'] as Map<String, Object?>) as MessageItem;
      expect(item.role, MessageRole.user);
      expect(item.attachmentCount, 1);
      expect(item.text, 'Reference attachments for the goal objective.');
      expect(item.systemLabel, isNull, reason: '用户消息没有系统行标签');
    });
  });
}
