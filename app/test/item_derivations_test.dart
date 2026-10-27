/// 条目派生表的行为钉子（批 G3-2 重构前/后都跑）。
///
/// 这一组是**变异校验发现缺口后补的**：把 `_buildChangedFiles` 的去重删掉，
/// 当时整份测试套件没有一条红 —— 说明"同一路径只留一行、取最后一次统计"
/// 这条规则从来没被断言过，只被注释描述过。
///
/// 规则出处：`ui-deliverables/src/client/turn-deliverables.ts:61-77`（改动用
/// `mutationPath` 认出来）与 `:132-160`（词表是**这一轮**的产出）。
///
/// Note: 收窄计划见 `.agents/notes/proposed/2026-10-27-appmodel-narrowing.md`。
library;

import 'package:dsh_mobile/data/item_derivations.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:flutter_test/flutter_test.dart';

ToolCallItem _write(
  int seq,
  String path, {
  ({int added, int removed})? stat,
  int? turn,
  ToolCallStatus status = ToolCallStatus.completed,
}) => ToolCallItem(
  itemId: 't:$seq',
  seq: seq,
  updatedAt: 0,
  turn: turn,
  name: 'Edit',
  status: status,
  changedPath: path,
  diffStat: stat,
);

MessageItem _assistant(String id, {required int turn, required String text}) =>
    MessageItem(
      itemId: id,
      seq: 100,
      updatedAt: 0,
      turn: turn,
      role: MessageRole.assistant,
      text: text,
    );

TurnProcessItem _process(int turn) =>
    TurnProcessItem(itemId: 'p:$turn', seq: turn, updatedAt: 0, turn: turn);

void main() {
  group('changedFiles', () {
    test('同一路径只留一行，统计取**最后一次**', () {
      final d = ItemDerivations(
        () => [
          _write(1, 'a.ts', stat: (added: 1, removed: 0)),
          _write(2, 'b.ts', stat: (added: 2, removed: 1)),
          _write(3, 'a.ts', stat: (added: 5, removed: 3)),
        ],
      );

      final rows = d.changedFiles;
      expect(rows, hasLength(2), reason: '重复路径不新增行');
      // 顺序：按"最后一次改动"从新到旧 —— a.ts 最后被改（seq 3），排最前。
      expect(rows.first.path, 'a.ts');
      expect(rows.first.stat, (added: 5, removed: 3), reason: '取最后一次统计');
      expect(rows.last.path, 'b.ts');
    });

    test('后一次没带统计 ⇒ 保留前一次的统计（别把已有的抹成 null）', () {
      final d = ItemDerivations(
        () => [
          _write(1, 'a.ts', stat: (added: 4, removed: 2)),
          _write(2, 'a.ts'),
        ],
      );

      expect(d.changedFiles.single.stat, (added: 4, removed: 2));
    });

    test('没改文件的工具调用不进表', () {
      final d = ItemDerivations(
        () => [
          const ToolCallItem(
            itemId: 't:9',
            seq: 9,
            updatedAt: 0,
            name: 'Read',
            status: ToolCallStatus.completed,
          ),
        ],
      );

      expect(d.changedFiles, isEmpty);
    });
  });

  group('producedPathsOf', () {
    test('只有**成功**的变更调用算产出；失败的与没改文件的不算', () {
      final d = ItemDerivations(
        () => [
          _write(1, 'ok.ts', turn: 1),
          _write(2, 'failed.ts', turn: 1, status: ToolCallStatus.failed),
          const ToolCallItem(
            itemId: 't:3',
            seq: 3,
            updatedAt: 0,
            turn: 1,
            name: 'Read',
            status: ToolCallStatus.completed,
          ),
        ],
      );

      expect(d.producedPathsOf(1), ['ok.ts']);
      expect(d.producedPathsOf(2), isEmpty);
      expect(d.producedPathsOf(null), isEmpty);
    });
  });

  group('fileMentionsOf', () {
    test('只对**收口那一轮**的最后一条助手正文给提及表', () {
      // 提及只认**这一轮产出过**的路径（`knownPaths: producedPathsOf(turn)`），
      // 所以要先有一条成功的变更调用把 `b.ts` 产出来。
      final d = ItemDerivations(
        () => [
          _write(3, 'b.ts', turn: 1),
          _process(1),
          _assistant('m1', turn: 1, text: '改了 `a.ts`'),
          _assistant('m2', turn: 1, text: '再看 `b.ts`'),
        ],
      );

      expect(
        d.fileMentionsOf(_assistant('m1', turn: 1, text: '改了 `a.ts`')),
        isNull,
        reason: '中间步骤不是收口消息',
      );
      expect(
        d.fileMentionsOf(_assistant('m2', turn: 1, text: '再看 `b.ts`')),
        containsPair('b.ts', 'b.ts'),
        reason: '最后一条带正文的助手消息 + 这一轮产出过它',
      );
    });

    test('轮次没收口（没有过程行）⇒ 不给提及表', () {
      final d = ItemDerivations(
        () => [_assistant('m1', turn: 1, text: '改了 `a.ts`')],
      );

      expect(
        d.fileMentionsOf(_assistant('m1', turn: 1, text: '改了 `a.ts`')),
        isNull,
      );
    });
  });

  test('缓存判据是条目列表的身份：同表只算一次，换表重算', () {
    var rows = <ChatItem>[_write(1, 'a.ts', stat: (added: 1, removed: 0))];
    final d = ItemDerivations(() => rows);

    final first = d.changedFiles;
    expect(identical(d.changedFiles, first), isTrue, reason: '同一份列表复用结果');

    rows = <ChatItem>[...rows, _write(2, 'b.ts')];
    expect(identical(d.changedFiles, first), isFalse, reason: '换表要重算');
    expect(d.changedFiles, hasLength(2));
  });
}
