/// `SessionStore` 两个逐会话被问的派生值：`pendingCount` / `updatedAt`。
///
/// ## 这一组守什么
///
/// 两个都是**全表扫描**，而 `AppModel` 在**每次刷新会话列表**时对**每个会话**
/// 各问一次（`app_model.dart:1473`）—— 流式输出期间每帧都刷新，
/// 于是每帧把已加载的条目全扫一遍。
///
/// 2026-10-20 给它们加了"按 `_sorted` 同一性"的缓存。缓存最容易犯的错是
/// **吃完不吐**：条目变了还返回旧值。这一组就是钉住失效。
library;

import 'package:dsh_mobile/data/session_store.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:flutter_test/flutter_test.dart';

ApprovalItem approval({
  required String id,
  required int seq,
  required int at,
  bool decided = false,
}) => ApprovalItem(
  itemId: id,
  seq: seq,
  updatedAt: at,
  title: '允许写入？',
  decided: decided,
);

MessageItem message({required String id, required int seq, required int at}) =>
    MessageItem(
      itemId: id,
      seq: seq,
      updatedAt: at,
      role: MessageRole.assistant,
      text: '好了',
    );

void main() {
  test('初值：一条未决审批 + 最新时刻', () {
    final store = SessionStore('s1')
      ..replaceAll([
        approval(id: 'a1', seq: 1, at: 10),
        message(id: 'm1', seq: 2, at: 20),
      ]);
    expect(store.pendingCount, 1);
    expect(store.updatedAt, 20);
  });

  test('**条目变了，缓存必须失效**（否则角标永远停在旧数字）', () {
    final store = SessionStore('s1')
      ..replaceAll([
        approval(id: 'a1', seq: 1, at: 10),
        message(id: 'm1', seq: 2, at: 20),
      ]);
    // 先读一次，把缓存填上。
    expect(store.pendingCount, 1);
    expect(store.updatedAt, 20);

    // 同一条审批被决定（`decided` 覆盖）→ 计数必须归零。
    store.upsertAll([approval(id: 'a1', seq: 1, at: 30, decided: true)]);
    expect(store.pendingCount, 0, reason: '缓存没失效的话这里还是 1');
    expect(store.updatedAt, 30, reason: '缓存没失效的话这里还是 20');
  });

  test('新增一条更晚的条目也算变更', () {
    final store = SessionStore('s1')
      ..replaceAll([message(id: 'm1', seq: 1, at: 20)]);
    expect(store.updatedAt, 20);
    store.upsertAll([message(id: 'm2', seq: 2, at: 99)]);
    expect(store.updatedAt, 99);
  });

  test('clear 之后两个值都归零（不是残留旧缓存）', () {
    final store = SessionStore('s1')
      ..replaceAll([approval(id: 'a1', seq: 1, at: 10)]);
    expect(store.pendingCount, 1);
    store.clear();
    expect(store.pendingCount, 0);
    expect(store.updatedAt, 0);
  });
}
