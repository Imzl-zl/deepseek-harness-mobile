/// 交互投影（`data/projection.dart` 的 `interactionSignalOf`）的回归。
///
/// ## 这一层为什么值得单独测
///
/// 待处理项是**会话事件的投影**（契约 §6.3），于是"手机上有没有那张卡"完全由
/// 事件形状决定。而事件的形状有几处反直觉的地方，读错一个就是静默的：
///
/// 1. `ask_user_question` 的参数是 **JSON 字符串**，且多选字段是 **snake_case 的
///    `multi_select`**（模型看到的形状），不是应答链上的 `multiSelect`；
/// 2. `approval/asked` 的 `callId` 是**可选的**，没有它手机答不了
///    （连接器的应答者会直接交还桌面）；
/// 3. 提问的收束有**两条路**：`tool/result`（调用有了结果）与迟到的
///    `user-question-reply` 用户消息（DSH 把迟到的答复 steer 成消息）。
library;

import 'package:dsh_mobile/data/projection.dart';
import 'package:dsh_mobile/model/interaction.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一条 `approval/asked` 事件的 data。
///
/// **缺字段就整个键不写**（不是写 `null`）：`callId` 在 DSH 侧是可选的
/// （`user-approval/src/index.ts:228`），而"键不存在"与"键的值是 null"在
/// `core/items.dart` 的字段读取里是两回事。
Map<String, Object?> askedData({
  String id = 'ap-1',
  String toolName = 'bash',
  String? callId = 'call-1',
  String? reason,
}) {
  final data = <String, Object?>{'id': id, 'toolName': toolName};
  if (callId != null) {
    data['callId'] = callId;
  }
  if (reason != null) {
    data['reason'] = reason;
  }
  return data;
}

void main() {
  group('approval/asked', () {
    test('开一张审批卡，标题照 reason 说', () {
      final signal = interactionSignalOf(
        type: 'approval/asked',
        seq: 3,
        data: askedData(reason: '要删工作区外的文件'),
      );
      expect(signal, isA<InteractionOpened>());
      final item = (signal as InteractionOpened).item;
      expect(item.itemId, 'i:ap-1');
      expect(item.callId, 'call-1');
      expect(item.kind, InteractionKind.approval);
      expect(item.title, '要删工作区外的文件');
      expect(item.toolName, 'bash');
    });

    test('没有 reason 就退回"工具 X 请求越权执行"', () {
      final item =
          (interactionSignalOf(
                    type: 'approval/asked',
                    seq: 3,
                    data: askedData(),
                  )
                  as InteractionOpened)
              .item;
      expect(item.title, '工具 bash 请求越权执行');
    });

    test('**没有 callId 就不开卡**（连接器会把它交还桌面）', () {
      // 没有稳定身份就没有在途 claim，手机上摆一张答不了的卡是对用户说谎。
      expect(
        interactionSignalOf(
          type: 'approval/asked',
          seq: 3,
          data: askedData(callId: null),
        ),
        isNull,
      );
    });

    test('approval/decided 收束同一个 itemId', () {
      final signal = interactionSignalOf(
        type: 'approval/decided',
        seq: 4,
        data: const {'id': 'ap-1', 'outcome': 'allowed-once'},
      );
      expect(signal, isA<InteractionSettled>());
      expect((signal as InteractionSettled).itemId, 'i:ap-1');
    });
  });

  group('ask_user_question 的 tool/call', () {
    test('参数是 JSON 字符串，多选字段是 snake_case 的 multi_select', () {
      final signal = interactionSignalOf(
        type: 'tool/call',
        seq: 7,
        data: <String, Object?>{
          'callId': 'call-q',
          'name': 'ask_user_question',
          'arguments': '''
{"questions":[
  {"id":"scope","question":"选哪个范围？","header":"范围","multi_select":true,
   "options":[{"label":"全部（推荐）","description":"一次说完"},{"label":"只读"}]},
  {"id":"note","question":"还有什么约束？","detail":"可选"}
]}''',
        },
      );
      expect(signal, isA<InteractionOpened>());
      final item = (signal as InteractionOpened).item;
      expect(item.itemId, 't:call-q');
      expect(item.callId, 'call-q');
      expect(item.kind, InteractionKind.question);
      expect(item.questions.length, 2, reason: '一次提问可以有多个问题');
      final first = item.questions.first;
      expect(first.multiSelect, isTrue, reason: 'multi_select 必须被读成多选');
      expect(first.header, '范围');
      // **"（推荐）"从标签里剥出来**单独做徽标（照原型）。
      expect(first.options.first.label, '全部（推荐）');
      expect(first.options.first.recommended, isTrue);
      expect(first.options.first.description, '一次说完');
      expect(item.questions[1].multiSelect, isFalse, reason: '没写就是单选');
    });

    test('别的工具不开卡', () {
      expect(
        interactionSignalOf(
          type: 'tool/call',
          seq: 7,
          data: const {
            'callId': 'call-x',
            'name': 'bash',
            'arguments': '{"questions":[]}',
          },
        ),
        isNull,
      );
    });

    test('参数读不懂就不开卡（模型坏参数，工具根本没被调用）', () {
      expect(
        interactionSignalOf(
          type: 'tool/call',
          seq: 7,
          data: const {
            'callId': 'call-q',
            'name': 'ask_user_question',
            'arguments': '{ 不是 JSON',
          },
        ),
        isNull,
      );
    });

    test('缺 id 或题干的问题被跳过（没法把答案配对回去）', () {
      final signal = interactionSignalOf(
        type: 'tool/call',
        seq: 7,
        data: const {
          'callId': 'call-q',
          'name': 'ask_user_question',
          'arguments':
              '{"questions":[{"question":"没有 id"},{"id":"ok","question":"有"}]}',
        },
      );
      final item = (signal as InteractionOpened).item;
      expect(item.questions.length, 1);
      expect(item.questions.single.id, 'ok');
    });
  });

  group('提问的两条收束路', () {
    test('tool/result 收束（结果与调用共用同一个 itemId）', () {
      final signal = interactionSignalOf(
        type: 'tool/result',
        seq: 9,
        data: const {
          'message': {'toolCallId': 'call-q', 'isError': false},
        },
      );
      expect(signal, isA<InteractionSettled>());
      expect((signal as InteractionSettled).itemId, 't:call-q');
    });

    test('迟到的 user-question-reply 用户消息也收束', () {
      // DSH 把迟到的答复 steer 成一条 source.kind='user-question-reply' 的消息，
      // 而那条消息同时是投影里"这个问题已关闭"的记录
      // （`user-questions/src/index.ts:186-191`）。
      final signal = interactionSignalOf(
        type: 'user/message',
        seq: 12,
        data: const {
          'id': 'm-1',
          'source': {'kind': 'user-question-reply', 'callId': 'call-q'},
        },
      );
      expect(signal, isA<InteractionSettled>());
      expect((signal as InteractionSettled).itemId, 't:call-q');
    });

    test('普通用户消息不是交互信号', () {
      expect(
        interactionSignalOf(
          type: 'user/message',
          seq: 12,
          data: const {
            'id': 'm-1',
            'source': {'kind': 'user'},
          },
        ),
        isNull,
      );
    });
  });

  test('与交互无关的事件一律返回 null', () {
    for (final type in const [
      'user/message',
      'assistant/message',
      'tool/call',
      'tool/result',
      'usage',
      'step',
    ]) {
      expect(
        interactionSignalOf(type: type, seq: 1, data: null),
        isNull,
        reason: type,
      );
    }
  });
}
