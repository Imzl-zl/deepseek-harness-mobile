/// 提问草稿（批 F）：答一半离开 / 重启回来还在。
///
/// ## 判据出处
///
/// 桌面按**每会话**持久化提问进度（`ui-user-questions/src/client/draft-store.ts:28-60`）：
/// `{progressByRequest: {<requestKey>: {index, drafts: [{selected[], custom, skipped}], wait?}}}`
/// 并带 `clear` / `prune(keep)`；注释原话是"离开会话或重启不擦掉没答完的答案"（`:38-42`）。
///
/// 手机原来的四样全在内存（`ui/takeover.dart` 的 `_questionIndex` / `_selected` /
/// `_custom` / `_skipped`），关一次接管卡或重启就丢"我答到第几题、勾了哪些"。
///
/// Note: 形状与取舍见 `.agents/notes/proposed/2026-10-27-ui-state-design.md` §D-4。
library;

import 'dart:convert';

import 'package:dsh_mobile/ui/takeover.dart';
import 'package:flutter_test/flutter_test.dart';

InteractionItem _ask({
  String key = 't:call-1',
  String sid = 's1',
  int questions = 2,
}) => InteractionItem(
  itemId: key,
  sid: sid,
  callId: 'call-1',
  kind: InteractionKind.question,
  title: '选一个',
  questions: [
    for (var i = 0; i < questions; i += 1)
      InteractionQuestion(
        id: 'q$i',
        question: '第 $i 题',
        options: const [
          InteractionOption(label: 'A'),
          InteractionOption(label: 'B'),
        ],
        multiSelect: i == 1,
      ),
  ],
);

/// 假的持久化端口：一张 `sid → JSON` 的表（与 `UiStateStore` 的草稿口同形）。
class _DraftDisk {
  final Map<String, String?> bySid = <String, String?>{};

  Future<String?> read(String sid) async => bySid[sid];

  void write(String sid, String? json) {
    if (json == null) {
      bySid.remove(sid);
      return;
    }
    bySid[sid] = json;
  }
}

TakeoverController _controller(_DraftDisk disk) => TakeoverController()
  ..readDraft = disk.read
  ..writeDraft = disk.write;

void main() {
  test('答到第 2 题、勾了多选、写了自定义 → 新实例读回同一进度', () async {
    final disk = _DraftDisk();
    final first = _controller(disk)..setCurrentSid('s1');
    first.enqueue(_ask());
    await Future<void>.delayed(Duration.zero);

    first.goToQuestion(1);
    first.toggleOption('A');
    first.toggleOption('B');
    first.setCustom('再补一句');
    await Future<void>.delayed(Duration.zero);

    // "重启"：新控制器 + 同一份盘。
    final second = _controller(disk)..setCurrentSid('s1');
    second.enqueue(_ask());
    await Future<void>.delayed(Duration.zero);

    expect(second.questionIndex, 1, reason: '停在第 2 题');
    expect(second.selected, {'A', 'B'}, reason: '勾选要回来（多选）');
    expect(second.custom, '再补一句');
    expect(second.answered, isTrue);
  });

  test('显式跳过也会被记住（空答案 ≠ 没答）', () async {
    final disk = _DraftDisk();
    final first = _controller(disk)..setCurrentSid('s1');
    first.enqueue(_ask());
    await Future<void>.delayed(Duration.zero);
    first.skipQuestion();
    await Future<void>.delayed(Duration.zero);

    final second = _controller(disk)..setCurrentSid('s1');
    second.enqueue(_ask());
    await Future<void>.delayed(Duration.zero);

    expect(second.skipped, isTrue);
    expect(second.answered, isTrue, reason: '显式跳过是合法答案');
  });

  test('草稿按会话：两个会话互不串味', () async {
    final disk = _DraftDisk();
    final c = _controller(disk)..setCurrentSid('s1');
    c.enqueue(_ask(sid: 's1'));
    await Future<void>.delayed(Duration.zero);
    c.toggleOption('A');
    await Future<void>.delayed(Duration.zero);

    c.setCurrentSid('s2');
    c.enqueue(_ask(key: 't:call-2', sid: 's2'));
    await Future<void>.delayed(Duration.zero);
    expect(c.selected, isEmpty, reason: 's2 没答过');

    c.setCurrentSid('s1');
    await Future<void>.delayed(Duration.zero);
    expect(c.selected, {'A'}, reason: '切回 s1 草稿还在');
  });

  test('收束后把草稿删掉（别在盘上留死数据）', () async {
    final disk = _DraftDisk();
    final c = _controller(disk)..setCurrentSid('s1');
    c.enqueue(_ask());
    await Future<void>.delayed(Duration.zero);
    c.toggleOption('A');
    await Future<void>.delayed(Duration.zero);
    expect(disk.bySid.containsKey('s1'), isTrue);

    c.settle('t:call-1', sid: 's1');
    await Future<void>.delayed(Duration.zero);
    expect(disk.bySid.containsKey('s1'), isFalse, reason: '这一项已经答完，草稿没有语义');
  });

  test('盘上是坏数据 → 当没有（不抛、不把卡片弄坏）', () async {
    final disk = _DraftDisk()..bySid['s1'] = '{不是 json';
    final c = _controller(disk)..setCurrentSid('s1');
    c.enqueue(_ask());
    await Future<void>.delayed(Duration.zero);

    expect(c.selected, isEmpty);
    expect(c.questionIndex, 0);
    expect(c.answered, isFalse);
  });

  test('草稿里的 item 不是当前这项 → 不套用（迟到的旧草稿）', () async {
    final disk = _DraftDisk()
      ..bySid['s1'] = jsonEncode({
        'item': 't:other',
        'index': 1,
        'questions': {
          'q1': {
            'selected': ['B'],
            'custom': '',
            'skipped': false,
          },
        },
      });
    final c = _controller(disk)..setCurrentSid('s1');
    c.enqueue(_ask());
    await Future<void>.delayed(Duration.zero);

    expect(c.questionIndex, 0);
    expect(c.selected, isEmpty);
  });
}
