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
/// - v2 → v3：**无 DDL**，把会话键与条目 id 加上电脑前缀（`<hostId>/…`）。
///   条目与水位从"一台电脑一份库"变成"一台电脑一段"，换电脑不再清库。
///   前缀取自 `meta.local_items.host`（上一版记下的那台电脑）。
const int storeSchemaVersion = 3;

/// 作用域分隔符：盘上的会话键是 `<hostId>/<sid>`，条目 id 是 `<hostId>/<itemId>`。
///
/// **唯一拼写处**：`data/host_scope.dart` 的 [HostScope]、迁移
/// （[storeDataMigrations] 的 v2→v3）与两个实现的 `scopeKeysTo` 都用它。
/// 会话别名（`sid_1`）与条目 id（`m:…` / `t:…` / `i:…`）都不含它，
/// 所以"键里有没有 `/`"就是"有没有分过域"的判据。
const String kScopeSep = '/';

/// 上一版记下"库里的条目属于哪台电脑"的键。**只为迁移而存在**：
/// v2→v3 用它给旧行补前缀，跑完就删（它不是用户偏好，没有第二读者）。
const String kLegacyItemsHostKey = 'local_items.host';

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

  /// 这些 `itemId` 现在盘上的载荷（`itemId → payloadJson`）；没有的行不在表里。
  ///
  /// 合并写入用它：同一个 `itemId` 会被**不同事件**更新（`tool/call` →
  /// `tool/result`、`llm/retry` → `llm/retry-started`），而后来那条事件**不带**
  /// 前一条的字段。只存最后一条的载荷，冷启动就丢了那些字段 ——
  /// 工具行显示成「工具」、重试行显示成「重试 1/0」（2026-11-04 真机）。
  Future<Map<String, String>> payloadsOf(String sid, Iterable<String> itemIds);

  /// 某会话的落盘水位（没有记录时返回 0 = 从零开始）。
  ///
  /// 它是 `subscribe(since:)` 的输入：手机重连后用它告诉电脑"我手里到哪了"。
  Future<int> cursorOf(String sid);

  /// 全部会话的水位（重连时一次取完，避免 N 次查询）。
  Future<Map<String, int>> allCursors();

  /// 清理某会话超出 `keep` 的旧条目（契约 §5.3 的淘汰）。
  Future<int> prune(String sid, {int keep = 500});

  /// 忘掉**一个会话**（条目 + 水位）。传的是库里的原始键。
  ///
  /// 它是"按桶清空"的最小动作：作用域装饰器（`data/scoped_store.dart` 的
  /// `ScopedItemStore.clearScope`）枚举出属于自己那台电脑的会话，逐个调它 ——
  /// 这样"清一台电脑的缓存"不需要 `clear()` 那种"删四张表"的粗动作。
  Future<void> clearSession(String sid);

  /// 把所有会话键与条目 id 前面加上 [prefix]（迁移用，**幂等**）。
  ///
  /// 只改**还没分域**的行（键里没有 [kScopeSep] 的那些）：`items.sid` /
  /// `items.item_id` / `cursors.sid` / `outbox.request_id`。
  ///
  /// 为什么它是接口方法而不是实现里的私货：v2→v3 的迁移函数只拿到 [ItemStore]
  /// （`storeDataMigrations` 的形状），而"给旧行补前缀"必须两个实现都做一遍 ——
  /// 否则内存实现跑通的迁移在真库上不成立。
  Future<void> scopeKeysTo(String prefix);

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
/// 盘上存的是**事件的载荷**，不是投影后的界面条目（见 [StoredItem] 的说明）。
/// 所以这里 `jsonEncode(event.data)`；反序列化在 [StoredItem.toEvent]。
/// 投影规则将来会改，而落盘的历史不该因此失效。
///
/// **但载荷要合并写**：同一个 `itemId` 会被不同事件更新，而后来那条不带前一条的
/// 字段（`tool/result` 没有工具名、`llm/retry-started` 没有失败原因）。只存最后
/// 一条，冷启动就丢字段 —— 见 [_mergedPayload]。
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
    // 先读这批 itemId 现在盘上的载荷：合并要它。
    final previous = await store.payloadsOf(sid, <String>{
      for (final event in events) event.itemId,
    });
    await store.commit(sid, <StoredItem>[
      for (final event in events)
        StoredItem(
          itemId: event.itemId,
          sid: sid,
          seq: event.seq,
          kind: event.type,
          payloadJson: _mergedPayload(previous[event.itemId], event.data),
          updatedAt: now,
        ),
    ], seq);
  }
}

/// 旧载荷 ∪ 新载荷（**新键覆盖旧键**）；空 / 坏形状退化成新载荷。
///
/// 为什么必须合并：同一个 `itemId` 会被**不同事件**更新，而后来那条**不带**
/// 前一条的字段 —— `tool/result` 没有 `name` / `arguments`（它们在 `tool/call` 上）、
/// `llm/retry-started` 没有 `maxRetries` / `failure`（在 `llm/retry` 上）。
/// 只存最后一条的载荷，冷启动就没有那些字段：工具行显示成「工具」、
/// 重试行显示成「重试 1/0」（2026-11-04 真机，库里 200 条 `tool/result`、0 条 `tool/call`）。
///
/// 方向**只加不减**：旧键保留、新键覆盖。投影只读它认识的键，多出来的键不会被误读。
///
/// Note: 取舍见 `.agents/notes/implemented/2026-11-04-merged-payload-on-write.md`。
String _mergedPayload(String? previousJson, Object? next) {
  final nextJson = next == null ? '' : jsonEncode(next);
  if (previousJson == null || previousJson.isEmpty) return nextJson;
  // 只有"对象载荷"才谈得上合并键（线上 `data` 就是对象；不是的话以新的为准）。
  if (next is! Map) return nextJson;
  try {
    final previous = jsonDecode(previousJson);
    if (previous is! Map) return nextJson;
    return jsonEncode(<String, Object?>{
      ...previous.cast<String, Object?>(),
      ...next.cast<String, Object?>(),
    });
  } on FormatException {
    // 旧载荷坏了：以新的为准，不拿一个读不出来的东西挡住这次写入。
    return nextJson;
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
  // v2 -> v3：条目与水位加电脑前缀（一台电脑一段，换电脑不再清库）。
  _scopeKeysToHost,
];

/// v2 → v3：给旧行补上电脑前缀。
///
/// 前缀来自上一版在装配时写下的 `meta.local_items.host`（那台电脑的
/// `pcSignPubHex`）。**没有这个键就什么都不做**：要么是全新安装（表里本来没行），
/// 要么是从没装配过配对凭据 —— 两种情况下都不存在"该归给谁"的旧数据。
///
/// 跑完删掉这个键：它只为迁移存在，留着就是第二个读者（也正是"三份真值"的开头）。
/// 迁移后未分域的旧行不可能再产生：新写入一律经 `ScopedItemStore` 带前缀。
Future<void> _scopeKeysToHost(ItemStore store) async {
  final hostId = await store.readMeta(kLegacyItemsHostKey);
  if (hostId == null || hostId.isEmpty) return;
  await store.scopeKeysTo('$hostId$kScopeSep');
  await store.deleteMeta(kLegacyItemsHostKey, includePrefixed: false);
}

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
  // v2 -> v3：**无 DDL**（给旧行补电脑前缀，在 `storeDataMigrations[2]`）。
  // 作用域写在键里而不是加一列：`sid` / `item_id` / `request_id` 都是 TEXT 主键，
  // 多一列就要动三张表的主键与两个实现的所有查询，换不来任何能力。
  <String>[],
];
