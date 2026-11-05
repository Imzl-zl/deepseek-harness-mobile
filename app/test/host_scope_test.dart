/// 存储分域（`data/host_scope.dart` + `data/scoped_store.dart`）与 v2→v3 迁移的回归。
///
/// ## 钉住的三件事
///
/// 1. **两台电脑撞名也互不可见**：同一 `sid`、同一 `itemId` 在两个作用域下各自成立
///    （`sid` 是电脑侧分配的不透明别名，撞名是常态而不是异常）；
/// 2. **清一台电脑不碰别的**：`clearScope()` 只删自己那段，`device.*` 与
///    `schema.data_version` 一律不动 —— 这是原来"换电脑清库"最贵的那笔代价
///    （主题/字号回默认、切回去整段重刷）；
/// 3. **迁移把旧行归给记着的那台**，跑完删掉记账键，且幂等。
library;

import 'package:dsh_mobile/core/outbox.dart';
import 'package:dsh_mobile/data/host_scope.dart';
import 'package:dsh_mobile/data/scoped_store.dart';
import 'package:dsh_mobile/data/store.dart';
import 'package:dsh_mobile/platform/sqflite_item_store.dart';
import 'package:flutter_test/flutter_test.dart';

StoredItem _item(String itemId, String sid, int seq) => StoredItem(
  itemId: itemId,
  sid: sid,
  seq: seq,
  kind: 'user/message',
  payloadJson: '{"n":$seq}',
  updatedAt: seq,
);

OutboxEntry _outbox(String requestId) => OutboxEntry(
  requestId: requestId,
  method: 'session.prompt',
  params: const <String, Object?>{'sid': 's1'},
);

void main() {
  late InMemoryItemStore inner;
  late ScopedItemStore a;
  late ScopedItemStore b;

  setUp(() async {
    inner = InMemoryItemStore();
    await inner.open();
    a = ScopedItemStore(inner, const HostScope('hostA'));
    b = ScopedItemStore(inner, const HostScope('hostB'));
  });

  group('作用域', () {
    test('同一个 sid 在两台电脑下互不可见（撞名是常态）', () async {
      await a.commit('sid_1', [_item('m:1', 'sid_1', 1)], 1);
      await b.commit('sid_1', [_item('m:2', 'sid_1', 1)], 1);

      expect((await a.itemsOf('sid_1')).map((i) => i.itemId), ['m:1']);
      expect((await b.itemsOf('sid_1')).map((i) => i.itemId), ['m:2']);
      expect(await a.cursorOf('sid_1'), 1);
      expect(await b.cursorOf('sid_1'), 1);
    });

    test('盘上的键带前缀（条目 id 也带）：内层实现不认识 host，分域只发生在装饰器', () async {
      await a.commit('sid_1', [_item('m:1', 'sid_1', 1)], 1);
      final row = (await inner.itemsOf('hostA/sid_1')).single;
      expect(row.itemId, 'hostA/m:1');
      expect(row.sid, 'hostA/sid_1');
    });

    test('allCursors 只回自己那段，并去掉前缀', () async {
      await a.commit('sid_1', [_item('m:1', 'sid_1', 1)], 5);
      await b.commit('sid_2', [_item('m:2', 'sid_2', 1)], 7);
      expect(await a.allCursors(), {'sid_1': 5});
      expect(await b.allCursors(), {'sid_2': 7});
    });

    test('clearScope 只清自己这段：别的电脑那段与 device.* / schema.* 都不动', () async {
      await a.commit('sid_1', [_item('m:1', 'sid_1', 1)], 1);
      await b.commit('sid_1', [_item('m:2', 'sid_1', 1)], 1);
      await inner.writeMeta('device.theme_mode', 'dark');
      await inner.writeMeta(kStoreDataVersionKey, '$storeSchemaVersion');
      await inner.writeMeta('host.hostB.last_session', 'sid_1');

      await a.clearScope();

      expect(await a.itemsOf('sid_1'), isEmpty, reason: '清的就是这台');
      expect((await b.itemsOf('sid_1')).map((i) => i.itemId), ['m:2'], reason: '另一台原样');
      expect(await inner.readMeta('device.theme_mode'), 'dark');
      expect(await inner.readMeta(kStoreDataVersionKey), '$storeSchemaVersion');
      expect(await inner.readMeta('host.hostB.last_session'), 'sid_1');
    });

    test('clear() 在分域库里等于 clearScope()（爆炸半径由作用域决定）', () async {
      await a.commit('sid_1', [_item('m:1', 'sid_1', 1)], 1);
      await b.commit('sid_1', [_item('m:2', 'sid_1', 1)], 1);
      await a.clear();
      expect(await a.itemsOf('sid_1'), isEmpty);
      expect(await b.itemsOf('sid_1'), isNotEmpty);
    });

    test('meta 不吃前缀：键自己就带归属（device.* / host.<id>.* 是两种主人）', () async {
      await a.writeMeta('host.hostA.last_session', 'sid_9');
      expect(await inner.readMeta('host.hostA.last_session'), 'sid_9');
      expect(await b.readMeta('host.hostA.last_session'), 'sid_9');
    });
  });

  group('待发队列', () {
    test('同一个 requestId 在两台电脑下互不覆盖，remove 只删自己那条', () async {
      final store = InMemoryOutboxStore();
      final oa = ScopedOutboxStore(store, const HostScope('hostA'));
      final ob = ScopedOutboxStore(store, const HostScope('hostB'));

      await oa.append(_outbox('req-1'));
      await ob.append(_outbox('req-1'));
      expect(store.load().then((rows) => rows.length), completion(2));

      await oa.remove('req-1');
      expect(rowsOf(await oa.load()), isEmpty);
      expect(rowsOf(await ob.load()), ['req-1'], reason: '另一台那条还在');
    });

    test('clear 只清自己那段', () async {
      final store = InMemoryOutboxStore();
      final oa = ScopedOutboxStore(store, const HostScope('hostA'));
      final ob = ScopedOutboxStore(store, const HostScope('hostB'));
      await oa.append(_outbox('req-1'));
      await ob.append(_outbox('req-2'));
      await oa.clear();
      expect(rowsOf(await oa.load()), isEmpty);
      expect(rowsOf(await ob.load()), ['req-2']);
    });
  });

  group('v2 → v3 迁移', () {
    test('把旧行归给 local_items.host 记着的那台，并删掉记账键', () async {
      // v2 的库：键没有前缀，meta 里记着"上次是谁的"。
      await inner.commit('s1', [_item('a', 's1', 2)], 2);
      await inner.writeMeta(kLegacyItemsHostKey, 'hostA');

      await storeDataMigrations[2](inner);

      expect(await inner.readMeta(kLegacyItemsHostKey), isNull, reason: '只为迁移存在的键');
      expect(await inner.cursorOf('hostA/s1'), 2);
      // 迁移之后经作用域读得到，不需要第二个读路径。
      expect((await a.itemsOf('s1')).map((i) => i.itemId), ['a']);
    });

    test('没有 local_items.host 就什么都不做（新装 / 从没装配过凭据）', () async {
      await inner.commit('s1', [_item('a', 's1', 2)], 2);
      await storeDataMigrations[2](inner);
      expect(await inner.cursorOf('s1'), 2, reason: '没有归属可判，不许瞎归');
      expect(await inner.allCursors(), {'s1': 2});
    });

    test('幂等：连跑两遍不会变成 hostA/hostA/s1', () async {
      await inner.commit('s1', [_item('a', 's1', 2)], 2);
      await inner.writeMeta(kLegacyItemsHostKey, 'hostA');
      await storeDataMigrations[2](inner);
      await inner.writeMeta(kLegacyItemsHostKey, 'hostA'); // 模拟半途崩后重跑
      await storeDataMigrations[2](inner);
      expect(await inner.allCursors(), {'hostA/s1': 2});
    });
  });
}

/// 取一批待发项的 `requestId`（断言里只关心这个）。
List<String> rowsOf(List<OutboxEntry> rows) => [for (final row in rows) row.requestId];
