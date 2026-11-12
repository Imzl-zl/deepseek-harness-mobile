/// `SessionStore.compact()`：**放正文、留事实**。
///
/// ## 为什么它是这个形状
///
/// `_stores` 不只是渲染缓存（见 `data/session_store.dart` 的 `compact` 文档）：
/// 抽屉的 `itemCount` / `pendingCount`、`sessionBlankOf` 的判据都从它读。
/// 整表删掉会把**事实**也删掉，症状是"抽屉全归零"与"新建会话点了没反应"复发。
///
/// 所以这里钉的是**三个事实在压缩前后完全相等**：条目数、最新时刻、"有没有可见条目"。
library;

import 'package:dsh_mobile/data/session_store.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:flutter_test/flutter_test.dart';

MessageItem _msg(int seq) => MessageItem(
  itemId: 'm$seq',
  seq: seq,
  updatedAt: seq * 10,
  role: MessageRole.user,
  text: '第 $seq 条',
);

OtherItem _other(int seq) =>
    OtherItem(itemId: 'o$seq', seq: seq, updatedAt: seq * 10, eventType: 'x');

void main() {
  test('compact 前后三个事实完全相等（条目数 / 最新时刻 / 有可见条目）', () {
    final store = SessionStore('s1')..upsertAll([_other(1), _msg(2), _msg(3)]);

    final lengthBefore = store.length;
    final updatedBefore = store.updatedAt;
    final visibleBefore = store.hasVisibleItems;

    store.compact();

    expect(store.length, lengthBefore, reason: '抽屉读 length：压缩不能把它变成 0');
    expect(store.updatedAt, updatedBefore, reason: '抽屉按它排序：压缩不能把它归零');
    expect(store.hasVisibleItems, visibleBefore, reason: 'blank 判据读它');
    expect(store.items, isEmpty, reason: '正文确实放掉了（这才是压缩的目的）');
    expect(store.isCompacted, isTrue);
  });

  test('只有 OtherItem 的会话：压缩前后都"没有可见条目"', () {
    final store = SessionStore('s1')..upsertAll([_other(1), _other(2)]);
    expect(store.hasVisibleItems, isFalse);
    store.compact();
    expect(
      store.hasVisibleItems,
      isFalse,
      reason: 'OtherItem 不算内容（与 chat_page 的 hero 判据同一条）',
    );
    expect(store.length, 2);
  });

  test('压缩之后再来的条目：length = 已放掉的 + 新的', () {
    final store = SessionStore('s1')..upsertAll([_msg(1), _msg(2)]);
    store.compact();
    store.upsertAll([_msg(3)]);
    expect(store.length, 3);
    expect(store.items, hasLength(1));
    expect(store.hasVisibleItems, isTrue);
    expect(store.pendingCount, 0);
  });

  test('compact 幂等（第二次是空操作）', () {
    final store = SessionStore('s1')..upsertAll([_msg(1)]);
    store.compact();
    store.compact();
    expect(store.length, 1);
  });

  test('replaceAll 是"整份换掉"：标量也归零（否则条目数会翻倍）', () {
    final store = SessionStore('s1')..upsertAll([_msg(1), _msg(2)]);
    store.compact();
    store.replaceAll([_msg(7)]);
    expect(store.length, 1, reason: '旧的 2 条已被"整份换掉"取代，不是叠加');
    expect(store.items.single.seq, 7);
    expect(store.hasVisibleItems, isTrue);
  });

  test('clear 也归零（语义是"这里什么都没有了"）', () {
    final store = SessionStore('s1')..upsertAll([_msg(1)]);
    store.compact();
    store.clear();
    expect(store.length, 0);
    expect(store.updatedAt, 0);
    expect(store.hasVisibleItems, isFalse);
    expect(store.isCompacted, isFalse);
  });

  test('压缩不发变更通知（只发生在没人看着的会话上）', () async {
    final store = SessionStore('s1')..upsertAll([_msg(1)]);
    final seen = <int>[];
    final sub = store.changes.listen((items) => seen.add(items.length));
    store.flush(); // 把手里的脏标记清掉，从干净状态开始观察
    await Future<void>.delayed(Duration.zero); // 广播流是异步投递的
    seen.clear();

    store.compact();
    await Future<void>.delayed(Duration.zero);

    expect(seen, isEmpty, reason: '发一次空列表只会让切换那一帧闪一下空白');
    await sub.cancel();
  });
}
