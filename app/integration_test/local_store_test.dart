/// 真机上的本地库：建表、落盘、重启后还在。
///
/// ## 为什么必须在设备上跑
///
/// `sqflite` 是**平台插件**（真机走原生 SQLite，单测走 ffi 的 sqlite3.dll）——
/// 两条路径的实现不同。而"库到底有没有真的建在设备上、schema 对不对、
/// 重启后数据还在不在"只有设备能回答。
///
/// `test/store_contract_test.dart` 用的是 ffi 实现（同一条 SQL 路径，但不是同一个驱动），
/// 这一条补的是"**在真设备上**驱动也能跑"。
///
/// 跑法（模拟器已在跑）：
/// ```
/// flutter test integration_test/local_store_test.dart -d emulator-5554
/// ```
library;

import 'package:dsh_mobile/data/store.dart';
import 'package:dsh_mobile/platform/sqflite_item_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真机上建库、落盘、读回（走设备原生 SQLite）', (tester) async {
    final store = SqfliteItemStore(fileName: 'itest.db');
    await store.open();
    try {
      await store.clear();

      await store.commit('s1', [
        const StoredItem(
          itemId: 'm1',
          sid: 's1',
          seq: 1,
          kind: 'user/message',
          payloadJson: '{"text":"你好"}',
          updatedAt: 1,
        ),
        const StoredItem(
          itemId: 'm2',
          sid: 's1',
          seq: 2,
          kind: 'assistant/message',
          payloadJson: '{"text":"你也好"}',
          updatedAt: 2,
        ),
      ], 2);

      final items = await store.itemsOf('s1');
      expect(items.map((i) => i.itemId).toList(), ['m1', 'm2']);
      expect(await store.cursorOf('s1'), 2);

      // 条目能还原成事件（投影层读的是 `data`）——
      // 载荷含非 ASCII，顺带验了 UTF-8 在设备上没被弄坏。
      final event = items.first.toEvent();
      expect(event.type, 'user/message');
      expect((event.data! as Map)['text'], '你好');

      // upsert：同一个 itemId 再写是覆盖（重放安全）。
      await store.commit('s1', [
        const StoredItem(
          itemId: 'm1',
          sid: 's1',
          seq: 1,
          kind: 'user/message',
          payloadJson: '{"text":"改过了"}',
          updatedAt: 3,
        ),
      ], 1);
      final after = await store.itemsOf('s1');
      expect(after.length, 2, reason: '重放不该变成三条');
      expect((after.first.toEvent().data! as Map)['text'], '改过了');
      // 水位**取最大**：重放一个更小的 seq 不能把水位写回去。
      expect(await store.cursorOf('s1'), 2);
    } finally {
      await store.close();
    }
  });

  testWidgets('关掉再打开：数据还在（这才是"落盘"的意义）', (tester) async {
    // 上一条用 `finally` 关了库，所以这里重开是**真的重开**（同一文件）。
    final store = SqfliteItemStore(fileName: 'itest.db');
    await store.open();
    try {
      // 上一条测完的数据应还在（同一个文件）。
      final items = await store.itemsOf('s1');
      expect(items, isNotEmpty, reason: '关掉再打开数据该还在 —— 否则它没真的落盘');
      expect(await store.cursorOf('s1'), 2);
    } finally {
      await store.clear();
      await store.close();
    }
  });
}
