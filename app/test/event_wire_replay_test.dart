/// 真机事件回放的**形状闸门**：`core/event_wire.dart` 的判据来源。
///
/// ## 这一组守什么
///
/// 1. **fixture 里的每一条真机事件都能被解码层读出来**（`WireBad` 数为 0）。
///    形状一漂（宿主改了字段名 / 换个类型），这里当天就红 —— 而不是等到"某个卡不出现"
///    再回头二分传输与渲染。
/// 2. **fixture 不许缩水**：`planCall` / `questionCall` / `toolCall` / `toolResult` /
///    `assistant` / `user` 六个键缺一不可。少了它们，第 1 条会变成"空集上也全绿"。
/// 3. **两条交互事件真的开出卡**（计划与提问），且 `arguments` 是**字符串**形状 ——
///    2026-10-25 的事故正是"用对象形状写的用例"把错误实现养绿的。
///
/// ## 为什么断言值不写死成常量
///
/// 期望值全部来自 fixture 本身（真机抓到的那条事件）：`callId` 用它带的、
/// 计划正文用它带的。测试只断言"解码结果与事件里写的那个值一致"，
/// 不复述一份手抄的常量 —— 手抄的那份会在实现变化时假装通过。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/core/event_wire.dart';
import 'package:dsh_mobile/data/projection.dart';
import 'package:dsh_mobile/model/interaction.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _fixture() =>
    jsonDecode(
          File('test/fixtures/real-session-events.json').readAsStringSync(),
        )
        as Map<String, Object?>;

Map<String, Object?> _event(Map<String, Object?> fixture, String key) =>
    fixture[key]! as Map<String, Object?>;

Map<String, Object?> _data(Map<String, Object?> event) =>
    event['data']! as Map<String, Object?>;

/// 把一条事件交给解码层（与 `items.dart` / `projection.dart` 的入口同一套 decoder）。
WireReading<Object?> _decode(String type, Object? data) {
  switch (type) {
    case 'tool/call':
      return readToolCall(data);
    case 'tool/result':
      return readToolResult(data);
    case 'approval/asked':
      return readApprovalAsked(data);
    case 'approval/decided':
      return readApprovalDecided(data);
    case 'user/message':
      return readQuestionReply(data);
    case 'command/run':
      return readCommandRun(data);
    case 'command/done':
      return readCommandDone(data);
    default:
      // 其余类型不在解码层的范围内（只收我们消费的事件，见该文件不变量 3）。
      return const WireSkip<Object?>();
  }
}

void main() {
  late Map<String, Object?> fixture;
  final reported = <String>[];

  setUp(() {
    fixture = _fixture();
    reported.clear();
    WireDiagnostics.reset();
    WireDiagnostics.sink = (event, detail) => reported.add('$event: $detail');
  });

  tearDown(() {
    WireDiagnostics.sink = null;
    WireDiagnostics.reset();
  });

  test('fixture 里每条真机事件都能解码，且形状错误计数为 0', () {
    var decoded = 0;
    for (final entry in fixture.entries) {
      if (entry.key.startsWith('_source')) continue;
      final event = entry.value! as Map<String, Object?>;
      final type = event['type']! as String;
      final reading = _decode(type, event['data']);
      if (reading is WireBad) {
        fail('${entry.key}（$type）读不出来：${reading.detail}');
      }
      if (reading is WireOk) decoded += 1;
    }
    expect(reported, isEmpty, reason: '解码层不该在任何一条真机事件上出声');
    expect(WireDiagnostics.badCount, 0);
    // 六条真机事件里，tool/call×3 + tool/result + user/message 都落在解码层范围内；
    // assistant/message 落在 Skip（不是交互事件）。数字由 fixture 自己决定，
    // 这里只要求"确实解出了东西"，避免整组变成空跑。
    expect(decoded, greaterThanOrEqualTo(4));
  });

  test('fixture 不缩水：六条关键事件缺一不可', () {
    for (final key in const [
      'planCall',
      'questionCall',
      'toolCall',
      'toolResult',
      'assistant',
      'user',
    ]) {
      expect(
        fixture.containsKey(key),
        isTrue,
        reason: '缺 $key ⇒ 回放变成空集上全绿（这一组的意义就没了）',
      );
    }
  });

  test('计划审查事件：arguments 是字符串，解得开并开出 plan 卡', () {
    final event = _event(fixture, 'planCall');
    final data = _data(event);
    expect(
      data['arguments'],
      isA<String>(),
      reason: '真机的 arguments 是 JSON 字符串；对象形状从来不存在',
    );

    final call = readToolCall(data);
    expect(call, isA<WireOk<ToolCallWire>>());
    final wire = (call as WireOk<ToolCallWire>).value;
    expect(wire.name, 'exit_plan_mode');
    expect(wire.arguments, isNotNull, reason: '字符串解不开就说明形状又漂了');

    final signal = interactionSignalOf(
      type: event['type']! as String,
      seq: event['seq']! as int,
      data: data,
    );
    expect(signal, isA<InteractionOpened>());
    final item = (signal as InteractionOpened).item;
    expect(item.kind, InteractionKind.plan);
    expect(item.callId, wire.callId, reason: '卡的身份就是这次工具调用的 id');
    expect(item.itemId, 't:${wire.callId}');
    // 正文与标题都指向**事件自己带的那份计划**，不是测试里另写的一段。
    expect(item.detail, wire.arguments!['plan']);
    expect(item.detail, contains('CHANGELOG'));
    expect(item.title, isNotEmpty);
    expect(item.approveLabel, kPlanApproveMark);
  });

  test('提问事件：三个选项一条不少，multi_select 读的是 snake_case', () {
    final event = _event(fixture, 'questionCall');
    final data = _data(event);
    expect(data['arguments'], isA<String>());

    final signal = interactionSignalOf(
      type: event['type']! as String,
      seq: event['seq']! as int,
      data: data,
    );
    expect(signal, isA<InteractionOpened>());
    final item = (signal as InteractionOpened).item;
    expect(item.kind, InteractionKind.question);
    expect(item.questions, hasLength(1));
    final question = item.questions.single;
    expect(question.options, hasLength(3), reason: '真机上三条选项都在（可滚动）');
    expect(question.options.map((o) => o.label), ['蓝色', '绿色', '红色']);
    expect(question.multiSelect, isFalse);

    // 原始串里确实是 snake_case 的 `multi_select`；读成 camelCase 会永远 false。
    final raw =
        jsonDecode(data['arguments']! as String) as Map<String, Object?>;
    final first = (raw['questions']! as List).first as Map<String, Object?>;
    expect(first.containsKey('multi_select'), isTrue);
  });

  test('坏参数只回 null，不入 bad 计数（那不是形状错，是模型的坏参数）', () {
    final call = readToolCall({
      'callId': 'call-1',
      'name': 'exit_plan_mode',
      'arguments': '{ 不是 JSON',
    });
    expect(call, isA<WireOk<ToolCallWire>>());
    expect((call as WireOk<ToolCallWire>).value.arguments, isNull);
    expect(WireDiagnostics.badCount, 0);
  });

  test('身份字段缺失算形状错：出声、计数加一，不静默', () {
    final call = readToolCall(const {'name': 'read'});
    expect(call, isA<WireBad<ToolCallWire>>());
    expect(valueOrReport(call, 'tool/call'), isNull);
    expect(WireDiagnostics.badCount, 1);
    expect(reported.single, contains('callId'));
  });
}
