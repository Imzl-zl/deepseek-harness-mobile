/// 本地库接口（`app-platform-boundaries.md` §1 的 `data/store.dart`）。
///
/// ## 为什么它是接口
///
/// 它是 `core/` 与 `data/` 唯一需要"落盘"的地方，而落盘要碰平台
/// （sqflite / 文件系统）。所以缝留在这里、实现在 `platform/`：
/// **业务层不认识 sqflite**，而单测可以用内存实现跑（且必须与真实现同语义 —— 见下）。
///
/// ## 为什么 `persisted` 必须等它
///
/// 契约 §5.3：**水位永不超过落盘内容**。手机告诉电脑"我到 `seq` 了"之后，
/// 电脑就可能裁掉那边的增量缓冲；若手机其实没落盘，重启后那段数据**永久丢失**。
///
/// 所以 [ItemStore.commit] 的语义是"**这批已经在盘上了**"，
/// 而不是"我处理完了" —— 名字用 `commit` 而不是 `save` 就是为了让它读起来像事务边界。
///
/// ## 三端同源（`app-platform-boundaries.md` §1 的硬规则）
///
/// "同一套 schema 与同一套迁移脚本，不允许按平台分叉存储格式"。
/// schema 定义在本文件（`storeSchemaVersion` + [ItemStore.migrations]），
/// 实现只负责执行 —— 于是三端的分叉点在**驱动**，不在**格式**。
library;

import 'dart:convert';

import '../core/sync_client.dart';

/// schema 版本。**逐代递增**，每一代在 [storeMigrations] 里有一段（DDL）、
/// 在 [storeDataMigrations] 里也有一段（数据改写，可以什么都不做）。
///
/// 与电脑侧的 schema 号**互相独立**（契约 §8.1）：那边是桥接的存储，
/// 这边是手机的。混用一个号会让"哪边该迁移"变成一个要靠猜的问题。
///
/// ## 各代做了什么
///
/// - v0 → v1：建表（`items` / `cursors` / `outbox` / `meta`）。
/// - v1 → v2：**无 DDL**，只搬偏好键（`theme.mode` → `device.theme_mode` 等，
///   见 [storeDataMigrations]）。设备本地 UI 状态复用 `meta` 表，
///   因为新建一张表要动 [ItemStore] 接口 + 两个实现，换不来任何能力
///   （前缀扫描与按 sid 删行在 `meta` 上都能做）。
const int storeSchemaVersion = 2;

/// 一条落盘的会话条目。
///
/// 它是**事件的原始载荷** + 身份，而不是投影后的界面条目：
/// 投影规则（`data/projection.dart`）将来会改（比如加一种事件类型的渲染），
/// 而落盘的历史不该因此失效 —— 所以盘上存事件，投影在读取时做。
class StoredItem {
  const StoredItem({
    required this.itemId,
    required this.sid,
    required this.seq,
    required this.kind,
    required this.payloadJson,
    required this.updatedAt,
  });

  /// 稳定身份（契约 §5.2）。
  final String itemId;

  /// 会话别名。
  final String sid;

  /// 会话修订号（DSH 的 `seq`）。**顺序依据**。
  final int seq;

  /// 事件类型（`user/message` / `tool/call` / …）。契约 §8.3 的 `kind`。
  final String kind;

  /// 事件载荷的 JSON（`data` 字段部分）。
  final String payloadJson;

  /// 落盘时刻（本地时钟，用于淘汰）。
  final int updatedAt;

  /// 还原成 `core` 的事件（喂给投影）。
  SessionEvent toEvent() => SessionEvent(
    itemId: itemId,
    type: kind,
    seq: seq,
    time: seq,
    data: payloadJson.isEmpty ? null : jsonDecode(payloadJson),
  );
}

/// 本地库（`app-platform-boundaries.md` §1）。实现在 `platform/`。
///
/// ## 幂等是硬要求
///
/// 崩溃后重放一个批次是**预期行为**（契约 §5.3 明写"最多重放一个批次，
/// upsert 幂等"），所以同一 `itemId` 写两次必须等价于写一次。
abstract interface class ItemStore {
  /// 打开 / 建库 / 跑迁移。**幂等**（重复调用返回同一个实例语义）。
  Future<void> open();

  /// 一批条目的**事务提交**（契约 §5.3：每 64 条或 200 ms 一次）。
  ///
  /// **返回后即表示"在盘上了"**，调用方据此发 `persisted`。
  /// 抛错即表示没落盘 —— 那时**不能**发 `persisted`（水位不能超前于内容）。
  Future<void> commit(String sid, List<StoredItem> items, int seq);

  /// 某个会话的条目（按 `seq` 升序，最多 [limit] 条，从末尾取）。
  Future<List<StoredItem>> itemsOf(String sid, {int limit = 500});

  /// 某会话的落盘水位（没有记录时返回 0 = 从零开始）。
  ///
  /// 它是 `subscribe(since:)` 的输入：手机重连后用它告诉电脑"我手里到哪了"。
  Future<int> cursorOf(String sid);

  /// 全部会话的水位（重连时一次取完，避免 N 次查询）。
  Future<Map<String, int>> allCursors();

  /// 清理某会话超出 `keep` 的旧条目（契约 §5.3 的淘汰）。
  Future<int> prune(String sid, {int keep = 500});

  /// 读一个 `meta` 值（`meta` 表的 k/v）。没有这个键时返回 `null`。
  ///
  /// 它给"UI 偏好"用：有些偏好**穿过协议**（决定调哪个方法、带什么参数），
  /// 所以必须落盘。只存内存的话，重启就回默认值，而用户看不出自己的选择
  /// 为什么莫名其妙没了。
  Future<String?> readMeta(String key);

  /// 读**一组** `meta` 值（键以 [prefix] 开头）。没有命中就是空表。
  ///
  /// 启动恢复用它：`device.*` + `host.last_session` + `host.drawer_expansion`
  /// 不该变成七八次单键往返（同一个库连接，一次范围查就够）。
  Future<Map<String, String>> readMetaPrefix(String prefix);

  /// 写一个 `meta` 值（upsert）。
  Future<void> writeMeta(String key, String value);

  /// 删 `meta` 值：`k = prefix`，[includePrefixed] 为真时**连同以它开头的键**。
  ///
  /// 两种用法都必须存在，因为"按前缀"和"删这一个键"不是一回事：
  /// - 换电脑清 `host.*` ⇒ `deleteMeta('host.')`（默认按前缀）；
  /// - prune 一个会话的页签 ⇒ `deleteMeta('host.session_view.sid-1', includePrefixed: false)`，
  ///   否则会把 `host.session_view.sid-10` 一起删掉（`sid-1` 是 `sid-10` 的字符串前缀）。
  Future<void> deleteMeta(String prefix, {bool includePrefixed = true});

  /// 清空（配对失效 / 换设备时用）。
  Future<void> clear();

  /// 关闭（**幂等**）。
  Future<void> close();
}

/// 偏好缝（窄）：一个字符串偏好的读写。
///
/// 为什么不是直接用 [ItemStore]：`AppModel` 不该认识整张库 —— 它只要
/// "记住一个选择"。装配点把 [ItemStore] 的 `meta` 表包成这个缝传进来
/// （见 [MetaPreferences]），于是 `AppModel` 的测试给一个内存假实现即可。
abstract interface class PreferenceStore {
  /// 读一个偏好。没有这个键时返回 `null`（= 用默认值）。
  Future<String?> read(String key);

  /// 读**一组**偏好（键以 [prefix] 开头）。启动恢复用一次范围查代替 N 次单键读。
  Future<Map<String, String>> readAll(String prefix);

  /// 写一个偏好（upsert）。
  Future<void> write(String key, String value);

  /// 删一个键；[includePrefixed] 为真时**连同以它开头的键**（语义见 [ItemStore.deleteMeta]）。
  Future<void> delete(String prefix, {bool includePrefixed = true});
}

/// 把 [ItemStore] 的 `meta` 表包成 [PreferenceStore]。
class MetaPreferences implements PreferenceStore {
  MetaPreferences(this._store);

  final ItemStore _store;

  @override
  Future<String?> read(String key) => _store.readMeta(key);

  @override
  Future<Map<String, String>> readAll(String prefix) =>
      _store.readMetaPrefix(prefix);

  @override
  Future<void> write(String key, String value) => _store.writeMeta(key, value);

  @override
  Future<void> delete(String prefix, {bool includePrefixed = true}) =>
      _store.deleteMeta(prefix, includePrefixed: includePrefixed);
}

/// 把 `core/` 的落盘缝接到本地库上。
///
/// ## 为什么这个适配器在 `data/` 而不是 `core/` 或 `platform/`
///
/// 它做的事是**翻译**：把 `core` 的 `SessionEvent` 变成 `data` 的 `StoredItem`。
/// - 放 `core/`：那里就不该认识 `ItemStore`（那会让纯 Dart 层依赖落盘实现的概念）；
/// - 放 `platform/`：那一层是"驱动选择"，不该有业务翻译。
///
/// `data/` 正好是"接口与投影"的家 —— 而这个适配器就是一种投影
/// （协议事件 → 盘上的行）。
///
/// ## 它为什么要序列化 `data`
///
/// 盘上存的是**事件的原始载荷**，不是投影后的界面条目（见 [StoredItem] 的说明）。
/// 所以这里 `jsonEncode(event.data)`；反序列化在 [StoredItem.toEvent]。
/// 投影规则将来会改，而落盘的历史不该因此失效。
class StoreItemPersister implements ItemPersister {
  StoreItemPersister(this.store);

  final ItemStore store;

  @override
  Future<void> persist({
    required String sid,
    required List<SessionEvent> events,
    required int seq,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.commit(sid, <StoredItem>[
      for (final event in events)
        StoredItem(
          itemId: event.itemId,
          sid: sid,
          seq: event.seq,
          kind: event.type,
          payloadJson: event.data == null ? '' : jsonEncode(event.data),
          updatedAt: now,
        ),
    ], seq);
  }
}

/// **数据**迁移（与 [storeMigrations] **同下标**，每代一段）。
///
/// DDL 之外还要搬数据的代放这里；不需要搬的代写 [_noopDataMigration]。
/// 执行点在实现里（`platform/sqflite_item_store.dart` 的 `open()`），
/// 与 SQL 用**同一个版本号**计数，跑完把 `schema.data_version` 落盘 ⇒
/// 重跑、半途崩都能自愈（每一步都必须幂等）。
typedef StoreDataMigration = Future<void> Function(ItemStore store);

/// 数据迁移跑到第几代的记账键。
///
/// **不是 UI 偏好**：它记录的是"库里的数据改写到第几代"，与用户选择无关，
/// 所以不带 `device.` / `host.` 前缀，也**不参与**换电脑清理。
const String kStoreDataVersionKey = 'schema.data_version';

Future<void> _noopDataMigration(ItemStore store) async {}

const List<StoreDataMigration> storeDataMigrations = <StoreDataMigration>[
  // v0 -> v1：建表那一步没有要搬的数据。
  _noopDataMigration,
  // v1 -> v2：偏好键加作用域前缀（`ui-state-design.md` §2.1）。
  // 读旧键 → 写新键 → 删旧键；旧键不在就跳过（幂等）。
  // **`send_mode` 这一代不动**：改走宿主 `ui-conversation.busyEnter` 是批 H，
  // 在那一批之前删它会让发送模式静默回到默认值。
  _scopePreferenceKeys,
];

/// v1 → v2 的具体动作。键名是**契约**（改动等于作废用户的选择）。
Future<void> _scopePreferenceKeys(ItemStore store) async {
  const renames = <String, String>{
    'theme.mode': 'device.theme_mode',
    'ui_scale_index': 'device.ui_scale_index',
    'transcript_view': 'device.transcript_view',
    'performance_usage': 'device.performance_view',
    'collapse_timing': 'device.collapse_timing',
    'last_session': 'host.last_session',
  };
  for (final entry in renames.entries) {
    final value = await store.readMeta(entry.key);
    if (value == null) continue;
    await store.writeMeta(entry.value, value);
    await store.deleteMeta(entry.key, includePrefixed: false);
  }
}

/// schema 迁移脚本（三端同一套）。
///
/// `index` 是从 `from` 到 `from + 1` 的那一步（`[0]` 把 v0 变成 v1）。
/// **加字段一律走这里**，不许在实现里偷偷 `ALTER TABLE` ——
/// 那样三端会各自漂移，而症状是"某个端上某个查询报错"。
const List<List<String>> storeMigrations = <List<String>>[
  // v0 -> v1：建立契约 §8.3 的六张表。
  //
  // 只建**真正用到**的：`items` / `cursors` / `outbox` / `meta`。
  // `pending` / `jobs` 属于"待处理与后台任务"两屏，还没做 ——
  // 先建空表会让"它到底有没有被写过"无从判断，而契约没要求表必须预先存在。
  <String>[
    '''
    CREATE TABLE items (
      item_id TEXT PRIMARY KEY,
      sid TEXT NOT NULL,
      seq INTEGER NOT NULL,
      kind TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      updated_at INTEGER NOT NULL
    )
    ''',
    // 按会话取条目（升序）与按会话淘汰都走它。
    'CREATE INDEX idx_items_sid_seq ON items (sid, seq)',
    // 淘汰按"最近更新"（契约 §5.3：超出按 updated_at 淘汰）。
    'CREATE INDEX idx_items_sid_updated ON items (sid, updated_at)',
    '''
    CREATE TABLE cursors (
      sid TEXT PRIMARY KEY,
      last_seq INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
    ''',
    '''
    CREATE TABLE outbox (
      request_id TEXT PRIMARY KEY,
      method TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
    ''',
    '''
    CREATE TABLE meta (
      k TEXT PRIMARY KEY,
      v TEXT NOT NULL
    )
    ''',
  ],
  // v1 -> v2：**无 DDL**（偏好键的搬动在 `storeDataMigrations[1]`）。
  <String>[],
];
