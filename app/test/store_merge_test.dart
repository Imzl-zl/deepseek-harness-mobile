/// **合并写入**：同一个 itemId 被两条事件更新时，冷启动仍能还原完整条目。
///
/// 2026-11-04 真机：重启后工具行全显示「工具」、重试行显示「重试 1/0」（连失败原因
/// 都没有）。根因不是投影，是**落盘**：库里每个 `itemId` 只存最后一条事件的载荷，
/// 而工具名在 `tool/call` 上、重试上限与失败原因在 `llm/retry` 上 —— 后来那条
/// 事件把它们覆盖掉了。修法见 `data/store.dart` 的 `_mergedPayload`。
///
/// 这两条用例走的是**真链路**：`StoreItemPersister` → `ItemStore` → `StoredItem.toEvent`
/// → `projectEvent`，中间不塞任何替身 —— 判据是"冷启动后投影出来的条目还完整"。
library;

import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/store.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/platform/sqflite_item_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'projection_fixture.dart';

SessionEvent _event(
  String type,
  String itemId,
  int seq,
  Map<String, Object?> data,
) => SessionEvent(itemId: itemId, type: type, seq: seq, time: seq, data: data);

/// 把库里那一行按"冷启动"的方式还原成条目（没有内存里的 `previous`）。
ChatItem _restored(StoredItem stored) {
  final event = stored.toEvent();
  return projectEvent(
    type: event.type,
    seq: event.seq,
    time: event.time,
    data: event.data,
  ).item!;
}

void main() {
  late InMemoryItemStore store;
  late StoreItemPersister persister;

  setUp(() async {
    store = InMemoryItemStore();
    await store.open();
    persister = StoreItemPersister(store);
  });

  test('tool/call + tool/result：冷启动后结果行仍有工具名与参数', () async {
    const id = 't:c1';
    await persister.persist(
      sid: 's1',
      events: [
        _event('tool/call', id, 10, {
          'turn': 1,
          'step': 1,
          'callId': 'c1',
          'name': 'bash',
          'arguments': '{"command":"ls -la"}',
        }),
      ],
      seq: 10,
    );
    await persister.persist(
      sid: 's1',
      events: [
        _event('tool/result', id, 11, {
          'turn': 1,
          'step': 1,
          'message': {
            'id': 'm1',
            'role': 'tool',
            'toolCallId': 'c1',
            'isError': false,
            'content': [
              {'type': 'text', 'text': 'a.txt'},
            ],
          },
        }),
      ],
      seq: 11,
    );

    final restored = _restored((await store.itemsOf('s1')).single);
    expect(restored, isA<ToolCallItem>());
    final card = restored as ToolCallItem;
    expect(card.name, 'bash', reason: '名字只在 tool/call 上，必须从合并载荷读回来');
    expect(card.summary, contains('ls -la'), reason: '参数摘要同理');
    expect(card.status, ToolCallStatus.completed);
  });

  test('llm/retry + llm/retry-started：冷启动后仍有上限与失败原因', () async {
    const id = 'r:r1:1';
    await persister.persist(
      sid: 's1',
      events: [
        _event('llm/retry', id, 20, {
          'retryId': 'r1',
          'turn': 1,
          'step': 1,
          'retry': 1,
          'maxRetries': 10,
          'delayMs': 1500.0,
          'failure': {'message': 'Request timed out.', 'code': 'TIMEOUT'},
        }),
      ],
      seq: 20,
    );
    await persister.persist(
      sid: 's1',
      events: [
        _event('llm/retry-started', id, 21, {
          'retryId': 'r1',
          'turn': 1,
          'step': 1,
          'retry': 1,
        }),
      ],
      seq: 21,
    );

    final restored = _restored((await store.itemsOf('s1')).single);
    expect(restored, isA<ModelRetryItem>());
    final retry = restored as ModelRetryItem;
    expect(retry.started, isTrue);
    expect(retry.maxRetries, 10, reason: '上限只在 llm/retry 上');
    expect(retry.message, 'Request timed out.', reason: '失败原因同上');
    expect(retry.code, 'TIMEOUT');
    expect(retry.delayMs, 1500);
  });

  test('合并方向：新键覆盖旧键（同一行的 seq 与 turn 跟着最后一条走）', () async {
    const id = 't:c2';
    await persister.persist(
      sid: 's1',
      events: [
        _event('tool/call', id, 30, {
          'turn': 1,
          'step': 1,
          'callId': 'c2',
          'name': 'read',
          'arguments': '{"path":"a.dart"}',
        }),
      ],
      seq: 30,
    );
    await persister.persist(
      sid: 's1',
      events: [
        _event('tool/result', id, 31, {
          'turn': 2,
          'step': 3,
          'message': {
            'id': 'm2',
            'role': 'tool',
            'toolCallId': 'c2',
            'isError': false,
            'content': const [],
          },
        }),
      ],
      seq: 31,
    );

    final stored = (await store.itemsOf('s1')).single;
    expect(stored.seq, 31, reason: '行身份跟着最后一条事件');
    final card = _restored(stored) as ToolCallItem;
    expect(card.name, 'read', reason: '名字用旧的（调用那条）');
    expect(card.status, ToolCallStatus.completed, reason: '状态用新的（结果那条）');
  });
}
