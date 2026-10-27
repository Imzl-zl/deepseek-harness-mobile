/// 发送模式的**唯一真值在宿主**（批 H）。
///
/// 判据：桌面的发送模式存在宿主设置 `ui-conversation.busyEnter`
/// （`packages/client/ui-conversation/src/submission-settings.ts:1-33`），
/// 手机原来另存一份 `meta.send_mode` —— 那是第二份真值
/// （`proposed/2026-10-27-state-semantics-audit.md` §C-5）。
///
/// 读：`settings.describe` 回来就覆盖本机种子；写：`settings.update` 发那一个字段。
/// **老连接器**（没有这个设置面）才退回本地键 —— 那是退路，不是第二条主路。
///
/// Note: 设计与代价见 `.agents/notes/proposed/2026-10-27-ui-state-design.md` §9 批 H。
library;

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/store.dart';
import 'package:dsh_mobile/model/send_mode.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

class _Prefs implements PreferenceStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<Map<String, String>> readAll(String prefix) async => {
    for (final e in values.entries)
      if (e.key == prefix || e.key.startsWith(prefix)) e.key: e.value,
  };

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String prefix, {bool includePrefixed = true}) async =>
      values.removeWhere(
        (k, _) => k == prefix || (includePrefixed && k.startsWith(prefix)),
      );
}

/// 会答 `settings.describe` / `settings.update` 的假电脑。
class _SettingsClient extends FakeSyncClient {
  _SettingsClient({required this.busyEnter, this.settingsAvailable = true});

  String busyEnter;
  final bool settingsAvailable;
  final List<Map<String, Object?>> updates = <Map<String, Object?>>[];

  @override
  conn.ConnectionState get state => conn.ConnectionState.serving;
  @override
  Stream<conn.ConnectionState> get connection => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> reconnect() async {}
  @override
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> close() async {}
  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();
  @override
  Future<void> unsubscribe(String sid) async {}

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    switch (method) {
      case 'settings.describe':
        if (!settingsAvailable) return {'sections': const []} as T;
        return {
              'sections': [
                {
                  'ns': 'ui-conversation',
                  'revision': 'rev-1',
                  'values': {'busyEnter': busyEnter},
                  'secrets': const [],
                },
              ],
            }
            as T;
      case 'settings.update':
        updates.add(params);
        final value = params['value'];
        if (value is String) busyEnter = value;
        return {
              'section': {
                'ns': params['ns'],
                'revision': 'rev-2',
                'values': {'busyEnter': busyEnter},
                'secrets': const [],
              },
            }
            as T;
      default:
        throw const ProtocolException(ErrorCode.relayOffline, '测试不连');
    }
  }
}

void main() {
  test('读：宿主说 steer ⇒ 手机就是 steer（不看本地那份）', () async {
    final prefs = _Prefs()..values[AppModel.kSendModeKey] = 'queue';
    final app = AppModel(
      client: _SettingsClient(busyEnter: 'steer'),
      prefs: prefs,
    );
    addTearDown(app.dispose);

    await app.refreshSettings();

    expect(app.sendMode, SendMode.steer, reason: '宿主是唯一真值');
  });

  test('写：切模式发 `ui-conversation.busyEnter`，**不写**本地键', () async {
    final prefs = _Prefs();
    final client = _SettingsClient(busyEnter: 'queue');
    final app = AppModel(client: client, prefs: prefs);
    addTearDown(app.dispose);
    await app.refreshSettings();

    await app.setSendMode(SendMode.steer);

    expect(client.updates, hasLength(1));
    expect(client.updates.single['ns'], 'ui-conversation');
    expect(client.updates.single['path'], ['busyEnter']);
    expect(client.updates.single['value'], 'steer');
    expect(
      prefs.values.containsKey(AppModel.kSendModeKey),
      isFalse,
      reason: '有两份真值就会"手机插话、电脑排队"',
    );
  });

  test('老连接器（没有设置面）⇒ 退回本地键（退路，不是主路）', () async {
    final prefs = _Prefs();
    final app = AppModel(
      client: _SettingsClient(busyEnter: 'queue', settingsAvailable: false),
      prefs: prefs,
    );
    addTearDown(app.dispose);
    await app.refreshSettings();

    await app.setSendMode(SendMode.steer);

    expect(prefs.values[AppModel.kSendModeKey], 'steer');
  });

  test('宿主值认不出（怪字符串）⇒ 保持现状，不猜', () async {
    final app = AppModel(
      client: _SettingsClient(busyEnter: 'Steer'),
      prefs: _Prefs(),
    );
    addTearDown(app.dispose);

    await app.refreshSettings();

    expect(app.sendMode, SendMode.queue, reason: '认不出就保持默认');
  });
}
