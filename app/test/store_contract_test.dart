/// 本地库的**契约测试**：同一套断言在两个实现上各跑一遍。
///
/// ## 为什么必须两个实现都跑
///
/// `data/store.dart` 的接口是"业务层认识的东西"，而它有两个实现：
/// sqflite（真设备）与内存（单测）。**两者的语义必须逐条一致** ——
/// 否则会出现最难查的一类 bug：单测全绿、真机行为不同。
///
/// 所以断言写在这里**一次**，由 [storeImplementations] 各喂一遍。
/// 加一条断言就等于同时钉住两个实现。
///
/// ## 为什么内存那份不是"兜底伪装"
///
/// 它的语义对着 sqflite 那份写（upsert、水位取最大、`itemsOf` 从末尾取、
/// `prune` 按 seq 保留）。有这组契约测试之前，"两边一致"只是我说的一句话；
/// 有了之后它是可执行的。
library;

import 'dart:io';

import 'package:dsh_mobile/data/store.dart';
import 'package:dsh_mobile/platform/sqflite_item_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 造一个**空的**实现。
///
/// sqflite 那份用 `inMemoryDatabasePath`：真 SQLite（同一条 SQL 路径）、
/// 但每次都是新库，所以测试之间互不干扰，也不需要清理文件。
/// 用 `:memory:` 而不是临时文件是刻意的 —— 临时文件在 Windows 上偶发删不掉，
/// 而那不是被测代码的问题。
typedef StoreFactory = Future<ItemStore> Function();

final List<(String, StoreFactory)> storeImplementations =
    <(String, StoreFactory)>[
      (
        'sqflite（真 SQL）',
        () async {
          // 走真 SQLite（同一条 SQL 路径），但用**临时目录里的文件**而不是
          // `inMemoryDatabasePath`：后者在 ffi 实现下要求 `singleInstance: false`，
          // 而"每个测试一个独立的真库"才是这里要的语义（测试之间互不干扰）。
          final dir = await Directory.systemTemp.createTemp('dsh_store_test');
          final store = SqfliteItemStore(
            fileName: 'test.db',
            directory: dir.path,
          );
          await store.open();
          return _TempDirStore(store, dir);
        },
      ),
      (
        '内存（单测）',
        () async {
          final store = InMemoryItemStore();
          await store.open();
          return store;
        },
      ),
    ];

/// 顺手把临时目录也收掉 —— 否则每跑一次测试就在 `%TEMP%` 里留一个库。
class _TempDirStore implements ItemStore {
  _TempDirStore(this._inner, this._dir);

  final ItemStore _inner;
  final Directory _dir;

  @override
  Future<void> open() => _inner.open();
  @override
  Future<void> commit(String sid, List<StoredItem> items, int seq) =>
      _inner.commit(sid, items, seq);
  @override
  Future<List<StoredItem>> itemsOf(String sid, {int limit = 500}) =>
      _inner.itemsOf(sid, limit: limit);
  @override
  Future<int> cursorOf(String sid) => _inner.cursorOf(sid);
  @override
  Future<Map<String, int>> allCursors() => _inner.allCursors();
  @override
  Future<int> prune(String sid, {int keep = 500}) =>
      _inner.prune(sid, keep: keep);
  @override
  Future<String?> readMeta(String key) => _inner.readMeta(key);
  @override
  Future<Map<String, String>> readMetaPrefix(String prefix) =>
      _inner.readMetaPrefix(prefix);
  @override
  Future<void> writeMeta(String key, String value) =>
      _inner.writeMeta(key, value);
  @override
  Future<void> deleteMeta(String prefix, {bool includePrefixed = true}) =>
      _inner.deleteMeta(prefix, includePrefixed: includePrefixed);
  @override
  Future<void> clear() => _inner.clear();
  @override
  Future<void> close() async {
    await _inner.close();
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
  }
}

StoredItem item(
  String itemId,
  int seq, {
  String sid = 's1',
  String kind = 'user/message',
}) => StoredItem(
  itemId: itemId,
  sid: sid,
  seq: seq,
  kind: kind,
  payloadJson: '{"n":$seq}',
  updatedAt: seq,
);

void main() {
  // sqflite 在桌面/单测环境要走 ffi（真机走原生实现，不需要这一步）。
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  for (final (label, factory) in storeImplementations) {
    group(label, () {
      late ItemStore store;

      setUp(() async {
        store = await factory();
      });

      tearDown(() async {
        await store.close();
      });

      test('没 open 就用 → 抛错（不隐式打开）', () async {
        // 隐式打开会让"忘了 open"变成只在并发下暴露的问题
        //（第一帧没数据、第二帧突然有了）。
        final fresh = InMemoryItemStore();
        await expectLater(fresh.cursorOf('s1'), throwsA(isA<StateError>()));
      });

      test('commit 之后能读回来，且水位跟着走', () async {
        await store.commit('s1', [item('a', 1), item('b', 2)], 2);
        final items = await store.itemsOf('s1');
        expect(items.map((i) => i.itemId), ['a', 'b']);
        expect(await store.cursorOf('s1'), 2);
      });

      test('upsert：同一个 item_id 再写是覆盖，不是追加（重放安全）', () async {
        await store.commit('s1', [item('a', 1)], 1);
        // 崩溃后重放一个批次是**预期行为**（契约 §5.3）。
        await store.commit('s1', [
          const StoredItem(
            itemId: 'a',
            sid: 's1',
            seq: 1,
            kind: 'assistant/message',
            payloadJson: '{"n":99}',
            updatedAt: 1,
          ),
        ], 1);
        final items = await store.itemsOf('s1');
        expect(items.length, 1, reason: '重放不该变成两条');
        expect(items.single.kind, 'assistant/message', reason: '应是覆盖后的内容');
      });

      test('水位**取最大**：乱序（重放）不能把水位写回去', () async {
        await store.commit('s1', [item('a', 1)], 5);
        await store.commit('s1', [item('b', 2)], 2); // 更小的 seq
        expect(
          await store.cursorOf('s1'),
          5,
          reason: '水位退步会让电脑重发已收段，而手机自己也会以为退步了',
        );
      });

      test('itemsOf 从**末尾**取（要最近 N 条，不是最旧 N 条）', () async {
        await store.commit('s1', [
          for (var i = 1; i <= 10; i += 1) item('i$i', i),
        ], 10);
        final items = await store.itemsOf('s1', limit: 3);
        expect(
          items.map((i) => i.itemId),
          ['i8', 'i9', 'i10'],
          reason: 'ORDER BY seq ASC LIMIT n 会取到最旧的 n 条 —— 那正是这个断言要防的',
        );
      });

      test('条目按 seq 升序返回（与插入顺序无关）', () async {
        await store.commit('s1', [item('c', 3)], 3);
        await store.commit('s1', [item('a', 1)], 3);
        await store.commit('s1', [item('b', 2)], 3);
        expect((await store.itemsOf('s1')).map((i) => i.itemId), [
          'a',
          'b',
          'c',
        ]);
      });

      test('会话之间互不干扰', () async {
        await store.commit('s1', [item('a', 1)], 1);
        await store.commit('s2', [item('b', 1, sid: 's2')], 7);
        expect((await store.itemsOf('s1')).map((i) => i.itemId), ['a']);
        expect((await store.itemsOf('s2')).map((i) => i.itemId), ['b']);
        expect(await store.cursorOf('s1'), 1);
        expect(await store.cursorOf('s2'), 7);
      });

      test('allCursors 一次给出全部水位', () async {
        await store.commit('s1', [item('a', 1)], 1);
        await store.commit('s2', [item('b', 1, sid: 's2')], 7);
        expect(await store.allCursors(), {'s1': 1, 's2': 7});
      });

      test('没有记录的会话：水位是 0（= 从零开始）', () async {
        expect(await store.cursorOf('never-seen'), 0);
        expect(await store.itemsOf('never-seen'), isEmpty);
      });

      test('prune 按 seq 保留最近的 N 条，并如实返回删了几条', () async {
        await store.commit('s1', [
          for (var i = 1; i <= 10; i += 1) item('i$i', i),
        ], 10);
        final removed = await store.prune('s1', keep: 4);
        expect(removed, 6);
        expect((await store.itemsOf('s1')).map((i) => i.itemId), [
          'i7',
          'i8',
          'i9',
          'i10',
        ]);
        // 淘汰**不动水位**：水位说的是"我处理到哪了"，与"我留了多少"无关。
        expect(await store.cursorOf('s1'), 10);
      });

      test('prune 在条目不够时是空操作', () async {
        await store.commit('s1', [item('a', 1)], 1);
        expect(await store.prune('s1', keep: 10), 0);
      });

      test('clear 清空一切（配对失效/换设备）', () async {
        await store.commit('s1', [item('a', 1)], 1);
        await store.clear();
        expect(await store.itemsOf('s1'), isEmpty);
        expect(await store.cursorOf('s1'), 0);
        expect(await store.allCursors(), isEmpty);
      });

      test('deleteMeta 按前缀删（换电脑清 host.* 靠它）', () async {
        await store.writeMeta('device.theme_mode', 'dark');
        await store.writeMeta('host.last_session', 'sid-1');
        await store.writeMeta('host.session_view.sid-1', 'trajectory');
        await store.deleteMeta('host.');
        expect(await store.readMeta('host.last_session'), isNull);
        expect(await store.readMeta('host.session_view.sid-1'), isNull);
        expect(
          await store.readMeta('device.theme_mode'),
          'dark',
          reason: 'device.* 与某台电脑无关，换电脑后必须还在',
        );
      });

      test('deleteMeta 也按**精确键**删（prune 一条会话时用它）', () async {
        await store.writeMeta('host.session_view.sid-1', 'trajectory');
        await store.writeMeta('host.session_view.sid-10', 'chat');
        await store.deleteMeta(
          'host.session_view.sid-1',
          includePrefixed: false,
        );
        expect(await store.readMeta('host.session_view.sid-1'), isNull);
        expect(
          await store.readMeta('host.session_view.sid-10'),
          'chat',
          reason: '精确删除不许把 sid-10 连带删掉（前缀必须是边界，不是字符串前缀）',
        );
      });

      test('readMetaPrefix 一次取一组，其它键不混进来', () async {
        await store.writeMeta('device.theme_mode', 'dark');
        await store.writeMeta('host.last_session', 'sid-1');
        await store.writeMeta('host.drawer_expansion', '{}');
        expect(await store.readMetaPrefix('host.'), {
          'host.last_session': 'sid-1',
          'host.drawer_expansion': '{}',
        });
      });

      test('数据迁移（v1→v2）把旧偏好键改名，且**幂等**', () async {
        // 迁移前：旧键（`ui-state-design.md` §2.3 的清单）。
        await store.writeMeta('theme.mode', 'light');
        await store.writeMeta('ui_scale_index', '2');
        await store.writeMeta('last_session', 'sid-9');
        await store.writeMeta('send_mode', 'steer');

        await storeDataMigrations[1](store);

        expect(await store.readMeta('device.theme_mode'), 'light');
        expect(await store.readMeta('device.ui_scale_index'), '2');
        expect(await store.readMeta('host.last_session'), 'sid-9');
        expect(await store.readMeta('theme.mode'), isNull, reason: '旧键要删掉');
        // `send_mode` 这一代**不动**：改走宿主 `ui-conversation.busyEnter` 是批 H，
        // 那一批才删它（同一批里删会让发送模式静默回到默认值）。
        expect(await store.readMeta('send_mode'), 'steer');

        // 幂等：再跑一遍不炸、不改写。
        await storeDataMigrations[1](store);
        expect(await store.readMeta('device.theme_mode'), 'light');
      });

      test('close 幂等', () async {
        await store.close();
        await store.close();
      });

      test('条目能还原成 core 的事件（落盘存事件,投影在读取时做）', () async {
        await store.commit('s1', [item('a', 1, kind: 'tool/call')], 1);
        final event = (await store.itemsOf('s1')).single.toEvent();
        expect(event.itemId, 'a');
        expect(event.type, 'tool/call');
        expect(event.seq, 1);
        // 载荷要能解回对象（投影层读的是 `data`）。
        expect(event.data, isA<Map<String, Object?>>());
      });
    });
  }
}
