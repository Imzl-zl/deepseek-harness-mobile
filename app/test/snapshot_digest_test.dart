/// 只读快照的内容摘要（契约 §5.7 的 `digest` / `notModified`）—— 手机侧。
///
/// 这一层的判据只有三条，每一条的失败形态都很安静：
///
/// 1. **摘要绑 `(方法, 参数)`**：分页后同一个方法不同参数是**两个包**，共用一个摘要
///    就是错配（第二页被当成"与第一页相同"，界面上什么都不会发生）；
/// 2. **`notModified` 什么都不做**：不清数据、不报错、不 `notifyListeners`
///    （做了任何一件，用户就会看到一次无意义的闪动或一句假错误）；
/// 3. **应用成功才记摘要**：记早了等于声称"我手里有它"，而解码失败时界面并没有
///    这份内容 —— 服务端下次答"没变"，那一段就再也回不来了。
///
/// 摘要的**口径**（`base64url(sha256(收到的字节))`）由一条固定向量钉住，
/// 与连接器 `tests/snapshot-digest.test.ts` 里同一个向量相等。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/snapshot_digest.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// **跨端固定向量**：同一段明文在两个语言里必须算出同一个摘要。
///
/// 期望值是外部真值（`sha256` 的定义），不从本仓库的实现里抄 ——
/// 连接器的 `tests/snapshot-digest.test.ts` 断言同一个常量。
const String _kVectorPlaintext = '{"ok":true,"result":{"a":1}}';
const String _kVectorDigest = 'C-IwaBxQXATEjck-6Rpr16aLFxI7Ntsn94ThxOhHbV4';

Map<String, Object?> _row(int index) => <String, Object?>{
  'sid': 'sid_$index',
  'updatedAt': 1000 - index,
  'running': false,
  'blank': false,
  'subagent': false,
};

/// 会话清单的替身：可以切成"服务端说没变"，并记下每次请求的参数。
class _ListClient extends FakeSyncClient {
  _ListClient({this.hasMore = false});

  final bool hasMore;

  /// 切到 `true` 之后，`session.list` 一律回 `{notModified: true}`
  /// （服务端在摘要命中时就是这么答的，形状见 `FakeSyncClient.callSnapshotWithDigest`）。
  bool notModified = false;

  final List<Map<String, Object?>> listParams = <Map<String, Object?>>[];

  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();
  @override
  Stream<HostStateChanged> get hostStateChanges => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> reconnect() => start();
  @override
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> unsubscribe(String sid) async {}
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method != 'session.list') return <String, Object?>{} as T;
    listParams.add(params);
    if (notModified) return <String, Object?>{'notModified': true} as T;
    final offset = (params['offset'] as int?) ?? 0;
    return <String, Object?>{
          'sessions': <Object?>[_row(offset)],
          'hasMore': hasMore,
        }
        as T;
  }
}

void main() {
  test('摘要口径：与连接器同一个向量（43 个 base64url 字符、无填充）', () async {
    final digest = await snapshotDigestOf(_kVectorPlaintext);
    expect(digest, _kVectorDigest);
    expect(digest.length, 43);
    expect(RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(digest), isTrue);
    // 同一份字节稳定；改一个字符就变。
    expect(await snapshotDigestOf(_kVectorPlaintext), digest);
    expect(await snapshotDigestOf('$_kVectorPlaintext '), isNot(digest));
  });

  test('键绑 (方法, 参数)：顺序无关，参数或方法不同就是不同的包', () {
    expect(
      snapshotKeyOf('session.list', {'limit': 50, 'offset': 50}),
      snapshotKeyOf('session.list', {'offset': 50, 'limit': 50}),
      reason: '同一个包的参数顺序不同，仍是同一个键',
    );
    expect(
      snapshotKeyOf('session.list', {'limit': 50}),
      isNot(snapshotKeyOf('session.list', {'limit': 50, 'offset': 50})),
      reason: '分页不同参数是两个包 —— 共用一个摘要就是错配',
    );
    expect(
      snapshotKeyOf('session.list', const {}),
      isNot(snapshotKeyOf('job.list', const {})),
      reason: '方法名是键的一部分',
    );
  });

  test('notModified：不清数据、不报错、不通知（同一个包不同参数各记各的摘要）', () async {
    final client = _ListClient(hasMore: true);
    final app = AppModel(client: client);
    addTearDown(app.dispose);

    var notifications = 0;
    app.addListener(() => notifications += 1);

    // ① 第一次：拿到正文并应用。
    await app.refreshSessionRows();
    expect(app.sessions, hasLength(1));
    expect(app.lastError, isNull);
    final firstKey = snapshotKeyOf('session.list', {'limit': 50});
    expect(client.appliedSnapshotDigests.keys, contains(firstKey));

    final notificationsAfterFirst = notifications;
    final rowsAfterFirst = app.sessions.map((s) => s.sid).toList();

    // ② 第二次：服务端说"没变" ⇒ 三件都不许发生。
    client.notModified = true;
    await app.refreshSessionRows();
    expect(
      app.sessions.map((s) => s.sid).toList(),
      rowsAfterFirst,
      reason: '不许清数据',
    );
    expect(app.lastError, isNull, reason: '不许报错');
    expect(
      notifications,
      notificationsAfterFirst,
      reason: '不许 notifyListeners',
    );

    // ③ 换参数（翻第二页）：那**不是同一个包**，摘要互不命中。
    client.notModified = false; // 内容重新可取（上一拍是服务端说"没变"）
    await app.loadMoreSessionRows();
    final secondKey = snapshotKeyOf('session.list', {'limit': 50, 'offset': 1});
    expect(secondKey, isNot(firstKey));
    expect(client.appliedSnapshotDigests.keys, contains(secondKey));
    expect(app.sessions, hasLength(2), reason: '第二页照常追加（它不该被摘要挡住）');
  });
}
