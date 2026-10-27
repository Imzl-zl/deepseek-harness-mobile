/// sqflite 实现的本地库（`data/store.dart` 的平台侧）。
///
/// ## 为什么实现住在 `platform/`
///
/// sqflite 是平台插件（`dart:io` + 各端原生 SQLite），而 `core/` 与 `data/`
/// 必须能在纯 Dart VM 里跑（那是 `protocol/fixtures` 三角色回放的前提）。
/// 所以 schema 定义在 `data/store.dart`（三端同源），**驱动**在这一层。
///
/// ## 为什么用 sqflite 而不是 drift / realm
///
/// 已核实（2026-10-02）：CPF-Flutter 的 `flutter_sqflite` 有 **`br_3.41_dev`** 分支
/// （对应本仓锁定的 Flutter 3.41 线），而 `drift` 官方 `NativeDatabase` 的平台表
/// **不含 ohos**、`sqlite3` 在鸿蒙适配清单里是"适配中"、`sqlite3_flutter_libs` 已 EOL。
/// 代价是失去类型安全与代码生成，手写 schema/SQL/迁移 —— 见
/// `.agents/notes/proposed/2026-09-30-mobile-portability-ceilings.md`。
library;

import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/outbox.dart';
import '../data/store.dart';

/// sqflite 实现的 [ItemStore]。
class SqfliteItemStore implements ItemStore {
  SqfliteItemStore({this.fileName = 'dsh_mobile.db', String? directory})
    : _directory = directory;

  /// 库文件名。测试用 `inMemoryDatabasePath` 之外的临时名。
  final String fileName;

  /// 库所在目录；`null` = 用各端的默认数据库目录。
  final String? _directory;

  Database? _db;

  @override
  Future<void> open() async {
    if (_db != null) return;
    final path = _directory == null
        ? p.join(await getDatabasesPath(), fileName)
        : p.join(_directory, fileName);
    _db = await openDatabase(
      path,
      version: storeSchemaVersion,
      // **迁移只用 `data/store.dart` 里那一套**（三端同源）。
      // 不在这里写 `ALTER TABLE`：那样三端会各自漂移，
      // 而症状是"某个端上某个查询报错"——最难查的一类。
      onCreate: (db, version) async {
        for (var v = 0; v < storeSchemaVersion; v += 1) {
          for (final statement in storeMigrations[v]) {
            await db.execute(statement);
          }
        }
      },
      onUpgrade: (db, from, to) async {
        for (var v = from; v < to; v += 1) {
          for (final statement in storeMigrations[v]) {
            await db.execute(statement);
          }
        }
      },
    );
    // **数据迁移在库打开之后跑**（DDL 那一步在 onCreate/onUpgrade 里）。
    // 不能塞进 onCreate/onUpgrade：那时 `_db` 还没赋值，迁移函数读不了键。
    await _runDataMigrations();
  }

  /// 跑 `data/store.dart` 的 `storeDataMigrations` 里还没跑过的那几代。
  ///
  /// 计数用 `meta` 的 `schema.data_version`（与 SQL 的 version **同一个号**）：
  /// - 新库：没这个键 ⇒ 从 v0 开始，但每一代都幂等（旧键不存在就跳过），
  ///   所以"空库跑一遍"是空操作；
  /// - 老库：从记录的那一代往后接着跑，跑完落盘 ⇒ 半途崩可自愈。
  Future<void> _runDataMigrations() async {
    final stored = await readMeta(kStoreDataVersionKey);
    final applied = int.tryParse(stored ?? '') ?? 0;
    if (applied >= storeSchemaVersion) return;
    for (var v = applied; v < storeSchemaVersion; v += 1) {
      await storeDataMigrations[v](this);
    }
    await writeMeta(kStoreDataVersionKey, '$storeSchemaVersion');
  }

  Database get _requireDb {
    final db = _db;
    if (db == null) {
      // 如实报错而不是自动 open：隐式打开会让"忘了 open"变成一个
      // 只在并发下才暴露的问题（第一帧没有数据，第二帧突然有了）。
      throw StateError('ItemStore 还没 open()');
    }
    return db;
  }

  @override
  Future<void> commit(String sid, List<StoredItem> items, int seq) async {
    final db = _requireDb;
    // **一个事务**（契约 §5.3）：条目与水位要么一起在盘上，要么都不在。
    // 分开写的话，崩在中间会留下"水位说到了 10，但条目只到 7" ——
    // 而那个状态**无法自愈**（重连时手机会说"我到 10 了"，电脑就不再补 8~10）。
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final item in items) {
        // upsert：同一个 itemId 再写一次是**覆盖**（重放一个批次是预期行为）。
        batch.insert('items', <String, Object?>{
          'item_id': item.itemId,
          'sid': item.sid,
          'seq': item.seq,
          'kind': item.kind,
          'payload_json': item.payloadJson,
          'updated_at': item.updatedAt,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      // 水位**取最大值**：乱序到达（重放）时不能把水位写回去 ——
      // 写回去会让电脑重发已经收过的段，而更糟的是手机自己会以为"我退步了"。
      batch.rawInsert(
        '''
        INSERT INTO cursors (sid, last_seq, updated_at) VALUES (?, ?, ?)
        ON CONFLICT(sid) DO UPDATE SET
          last_seq = MAX(last_seq, excluded.last_seq),
          updated_at = excluded.updated_at
        ''',
        <Object?>[sid, seq, DateTime.now().millisecondsSinceEpoch],
      );
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<List<StoredItem>> itemsOf(String sid, {int limit = 500}) async {
    final db = _requireDb;
    // **从末尾取**（最近的 limit 条）再按 seq 升序返回：
    // `ORDER BY seq ASC LIMIT n` 会取到最旧的 n 条 —— 而界面要的是最近的。
    final rows = await db.rawQuery(
      '''
      SELECT * FROM (
        SELECT * FROM items WHERE sid = ? ORDER BY seq DESC LIMIT ?
      ) ORDER BY seq ASC
      ''',
      <Object?>[sid, limit],
    );
    return rows.map(_itemFromRow).toList();
  }

  @override
  Future<int> cursorOf(String sid) async {
    final db = _requireDb;
    final rows = await db.query(
      'cursors',
      columns: <String>['last_seq'],
      where: 'sid = ?',
      whereArgs: <Object?>[sid],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return (rows.first['last_seq'] as int?) ?? 0;
  }

  @override
  Future<Map<String, int>> allCursors() async {
    final db = _requireDb;
    final rows = await db.query(
      'cursors',
      columns: <String>['sid', 'last_seq'],
    );
    return <String, int>{
      for (final row in rows)
        row['sid']! as String: (row['last_seq'] as int?) ?? 0,
    };
  }

  @override
  Future<int> prune(String sid, {int keep = 500}) async {
    final db = _requireDb;
    // 按 `updated_at` 淘汰（契约 §5.3），保留**最近 seq 的 keep 条**。
    // 用 seq 而不是 updated_at 做"保留哪些"的判据：seq 是会话内的权威顺序，
    // 而 updated_at 是本地时钟（可能因重放而乱序）。
    return db.rawDelete(
      '''
      DELETE FROM items WHERE sid = ? AND item_id NOT IN (
        SELECT item_id FROM items WHERE sid = ? ORDER BY seq DESC LIMIT ?
      )
      ''',
      <Object?>[sid, sid, keep],
    );
  }

  @override
  Future<String?> readMeta(String key) async {
    final db = _requireDb;
    final rows = await db.query(
      'meta',
      columns: <String>['v'],
      where: 'k = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['v'] as String?;
  }

  @override
  Future<Map<String, String>> readMetaPrefix(String prefix) async {
    final db = _requireDb;
    final rows = await db.query(
      'meta',
      columns: <String>['k', 'v'],
      where: "k = ? OR k LIKE ? ESCAPE '\\'",
      whereArgs: <Object?>[prefix, '${_escapeLike(prefix)}%'],
    );
    return <String, String>{
      for (final row in rows) row['k']! as String: row['v']! as String,
    };
  }

  @override
  Future<void> writeMeta(String key, String value) async {
    final db = _requireDb;
    await db.insert('meta', <String, Object?>{
      'k': key,
      'v': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> deleteMeta(String prefix, {bool includePrefixed = true}) async {
    final db = _requireDb;
    await db.delete(
      'meta',
      where: includePrefixed ? "k = ? OR k LIKE ? ESCAPE '\\'" : 'k = ?',
      whereArgs: includePrefixed
          ? <Object?>[prefix, '${_escapeLike(prefix)}%']
          : <Object?>[prefix],
    );
  }

  /// 把 LIKE 的通配符转义掉，避免会话 id 里的 `_` / `%` 变成"任意字符"。
  static String _escapeLike(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  @override
  Future<void> clear() async {
    final db = _requireDb;
    await db.transaction((txn) async {
      for (final table in const ['items', 'cursors', 'outbox', 'meta']) {
        await txn.delete(table);
      }
    });
  }

  @override
  Future<void> close() async {
    final db = _db;
    _db = null;
    if (db == null) return;
    await db.close();
  }

  static StoredItem _itemFromRow(Map<String, Object?> row) => StoredItem(
    itemId: row['item_id']! as String,
    sid: row['sid']! as String,
    seq: (row['seq']! as num).toInt(),
    kind: row['kind']! as String,
    payloadJson: row['payload_json']! as String,
    updatedAt: (row['updated_at']! as num).toInt(),
  );
}

/// 出帧队列的落盘（`core/outbox.dart` 的 `OutboxStore`）走**同一个库**。
///
/// ## 为什么不做成两个库
///
/// `outbox` 表本来就在 §8.3 的 schema 里（与 `items` / `cursors` 同一张库），
/// 而分成两个库会带来一个真问题：**用同一个事务表达不了"条目与水位与待发项
/// 一起落盘"**（现在还用不到，但将来"发出去之前先记下待发项"就需要）。
/// 更要紧的是：三端同源说的是"**一套 schema**"，两个库会让它变成两套。
class SqfliteOutboxStore implements OutboxStore {
  SqfliteOutboxStore(this._items);

  final SqfliteItemStore _items;

  @override
  Future<List<OutboxEntry>> load() async {
    final rows = await _items._requireDb.query(
      'outbox',
      orderBy: 'created_at ASC',
    );
    return <OutboxEntry>[
      for (final row in rows)
        OutboxEntry(
          requestId: row['request_id']! as String,
          method: row['method']! as String,
          params:
              (jsonDecode(row['payload_json']! as String)
                      as Map<String, Object?>?)
                  ?.cast<String, Object?>() ??
              const <String, Object?>{},
        ),
    ];
  }

  @override
  Future<void> append(OutboxEntry entry) async {
    // **抛错即没落盘**（接口约定）：调用方据此拒绝这次写操作。
    await _items._requireDb.insert('outbox', <String, Object?>{
      'request_id': entry.requestId,
      'method': entry.method,
      'payload_json': jsonEncode(entry.params),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> remove(String requestId) async {
    await _items._requireDb.delete(
      'outbox',
      where: 'request_id = ?',
      whereArgs: <Object?>[requestId],
    );
  }

  @override
  Future<void> clear() async {
    await _items._requireDb.delete('outbox');
  }
}

/// 内存实现（测试与"还没建库"时用）。
///
/// **它不是兜底伪装**：它的语义与 sqflite 那份**逐条对齐**
/// （upsert、水位取最大、`itemsOf` 从末尾取、`prune` 按 seq 保留），
/// 所以用它跑通的逻辑在真库上也成立。两者语义的差异由
/// `test/store_contract_test.dart` 同一个套件各跑一遍来钉住。
class InMemoryItemStore implements ItemStore {
  final Map<String, Map<String, StoredItem>> _items = {};
  final Map<String, int> _cursors = {};
  final Map<String, String> _meta = {};
  bool _open = false;

  @override
  Future<void> open() async {
    _open = true;
    // 与 sqflite 那份同一条：数据迁移也在这个实现上跑一遍，
    // 否则"单测全绿、真机行为不同"会从迁移这一步开始分叉。
    final applied = int.tryParse(_meta[kStoreDataVersionKey] ?? '') ?? 0;
    if (applied >= storeSchemaVersion) return;
    for (var v = applied; v < storeSchemaVersion; v += 1) {
      await storeDataMigrations[v](this);
    }
    _meta[kStoreDataVersionKey] = '$storeSchemaVersion';
  }

  /// 与 sqflite 那份的 `k = prefix OR k LIKE prefix%` 同一条边界规则。
  static bool _matchesPrefix(String key, String prefix) =>
      key == prefix || key.startsWith(prefix);

  void _requireOpen() {
    if (!_open) throw StateError('ItemStore 还没 open()');
  }

  @override
  Future<void> commit(String sid, List<StoredItem> items, int seq) async {
    _requireOpen();
    final bucket = _items.putIfAbsent(sid, () => <String, StoredItem>{});
    for (final item in items) {
      bucket[item.itemId] = item;
    }
    // 水位取最大（与 sqflite 那份的 `MAX(...)` 一致）。
    final current = _cursors[sid] ?? 0;
    _cursors[sid] = seq > current ? seq : current;
  }

  @override
  Future<List<StoredItem>> itemsOf(String sid, {int limit = 500}) async {
    _requireOpen();
    final all = (_items[sid] ?? const <String, StoredItem>{}).values.toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    // 从末尾取（与 sqflite 那份一致）。
    if (all.length <= limit) return all;
    return all.sublist(all.length - limit);
  }

  @override
  Future<int> cursorOf(String sid) async {
    _requireOpen();
    return _cursors[sid] ?? 0;
  }

  @override
  Future<Map<String, int>> allCursors() async {
    _requireOpen();
    return Map<String, int>.from(_cursors);
  }

  @override
  Future<int> prune(String sid, {int keep = 500}) async {
    _requireOpen();
    final bucket = _items[sid];
    if (bucket == null) return 0;
    final sorted = bucket.values.toList()
      ..sort((a, b) => b.seq.compareTo(a.seq));
    if (sorted.length <= keep) return 0;
    final drop = sorted.sublist(keep);
    for (final item in drop) {
      bucket.remove(item.itemId);
    }
    return drop.length;
  }

  @override
  Future<String?> readMeta(String key) async {
    _requireOpen();
    return _meta[key];
  }

  @override
  Future<Map<String, String>> readMetaPrefix(String prefix) async {
    _requireOpen();
    return <String, String>{
      for (final entry in _meta.entries)
        if (_matchesPrefix(entry.key, prefix)) entry.key: entry.value,
    };
  }

  @override
  Future<void> writeMeta(String key, String value) async {
    _requireOpen();
    _meta[key] = value;
  }

  @override
  Future<void> deleteMeta(String prefix, {bool includePrefixed = true}) async {
    _requireOpen();
    _meta.removeWhere(
      (key, _) => key == prefix || (includePrefixed && key.startsWith(prefix)),
    );
  }

  @override
  Future<void> clear() async {
    _requireOpen();
    _items.clear();
    _cursors.clear();
    _meta.clear();
  }

  @override
  Future<void> close() async => _open = false;
}
