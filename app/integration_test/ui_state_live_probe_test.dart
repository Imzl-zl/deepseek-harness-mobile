/// **真机探针**：UI 状态那批依赖的两条跨系统假设，在真宿主上到底成不成立。
///
/// ## 它验什么（都不花模型钱）
///
/// 1. `settings.describe` 真的能读到 `ui-conversation` 命名空间，且里面有
///    `busyEnter` —— 批 H 把发送模式交给宿主（`ui-conversation/src/submission-settings.ts`）
///    的前提。**读不到时手机不会报错**（静默退回本地键），所以只能这样验。
/// 2. `settings.update` 真的能写 `busyEnter` 并回读（写 `steer` → 回读 → 写回 `queue`）。
/// 3. `session.list` 的行里真的带 `values.subagentCatalog` —— 批 E 的
///    `runningChildrenOf` 读的就是它；没有这个键，会话页那行永远是 0。
///
/// 3 用**裸应答**判（`client.call('session.list')`）而不是 `SessionSummary.subagents`：
/// 解析器返回空表时分不清"键不在"与"没有子智能体"，而这里要回答的是"键在不在"。
/// 这是诊断探针，不是生产路径 —— 生产路径仍只经 `wire/`。
///
/// ## 跑法
///
/// ```powershell
/// # 前置：中转 + `dsh --profile dsh-mobile-test` 在跑；手机上已有一次配对
/// adb -s <序列号> shell svc power stayon true
/// cd app
/// flutter test integration_test/ui_state_live_probe_test.dart -d <序列号>
/// ```
///
/// **凭据复用设备上已有的那次配对**（不重新出码）：这条探针不建会话、不发 prompt，
/// 只读设置与列表。没有凭据就跳过（前置没起 ≠ 实现不对）。
library;

import 'package:dsh_mobile/core/box.dart';
import 'package:dsh_mobile/core/crypto.dart';
import 'package:dsh_mobile/core/frame.dart';
import 'package:dsh_mobile/core/handshake_driver.dart';
import 'package:dsh_mobile/core/outbox.dart';
import 'package:dsh_mobile/core/pairing_client.dart';
import 'package:dsh_mobile/core/recovery.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/core/sync_client_impl.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/store.dart';
import 'package:dsh_mobile/model/chat_item.dart' show ConnectionStateView;
import 'package:dsh_mobile/model/send_mode.dart';
import 'package:dsh_mobile/platform/http_sender.dart';
import 'package:dsh_mobile/platform/pairing_store.dart';
import 'package:dsh_mobile/platform/sqflite_item_store.dart';
import 'package:dsh_mobile/platform/ticketed_transport.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 等一个真实网络条件成立（真网络 + `pump` 交替：`runAsync` 才推进 socket）。
Future<bool> _waitFor(
  WidgetTester tester,
  Future<bool> Function() condition,
) async {
  for (var i = 0; i < 200; i += 1) {
    if (await tester.runAsync(condition) ?? false) return true;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
  return false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真机：宿主有 ui-conversation.busyEnter 且可写；列表行带 subagentCatalog', (
    tester,
  ) async {
    final credentials = await pairingStore.load();
    if (credentials == null) {
      markTestSkipped('设备上没有配对凭据：先跑一次真机配对，再跑这条探针');
      return;
    }

    final store = SqfliteItemStore();
    await store.open();
    final identity = await deriveIdentity(credentials.masterSeedHex);
    final staticKeys = await x25519FromSeed(identity.dhSeedHex);
    final deviceId = await credentials.helloDeviceId();
    final pairingClient = PairingClient(
      relayUrl: credentials.relayUrl,
      send: createHttpSender(),
      allowInsecureLocal: true,
    );
    final transport = TicketedWebSocketTransport(
      endpoint: credentials.relayUrl,
      ticket: () async => (await pairingClient.ticketByDeviceToken(
        credentials.deviceToken,
      )).ticket,
    );
    final client = createSyncClient(
      SyncClientDeps(
        transport: transport,
        handshake: createHandshakeDriver(
          identity: HandshakeIdentity(
            staticKeys: staticKeys,
            signSeedHex: identity.signSeedHex,
            devId: deviceId,
          ),
          peer: PeerIdentity(
            pcSignPubHex: credentials.pcSignPubHex,
            pcDhPubHex: credentials.pcDhPubHex,
            pcId: credentials.pcId,
            pairingId: credentials.pairingId,
          ),
          newEphemeralSeedHex: () => toHex(randomBytes(32)),
          newNonceHex: () => toHex(randomBytes(32)),
          newFrameIdHex: () => newFrameId(randomBytes(frameIdBytes)),
        ),
        box: (keys) => BoxCodec(keys: keys, role: HandshakeRole.initiator),
        outbox: Outbox(store: SqfliteOutboxStore(store)),
        session: DeviceSession(),
        persistence: StoreItemPersister(store),
      ),
    );
    final app = AppModel(client: client);
    addTearDown(() async {
      app.dispose();
      await client.close();
      await store.close();
    });

    await app.start();
    final serving = await _waitFor(
      tester,
      () async => app.connection == ConnectionStateView.serving,
    );
    expect(
      serving,
      isTrue,
      reason: '建连必须通；诊断：${app.connectionDiagnosis ?? '无'}',
    );

    // ---- ① 读：宿主真的有 ui-conversation.busyEnter 吗 ----
    await app.refreshSettings();
    final section = app.settingsOf('ui-conversation');
    expect(
      section,
      isNotNull,
      reason:
          '连接器读面 allowlist 里必须有 ui-conversation（批 H）；'
          '读不到时手机静默退回本地键，界面上看不出任何异常',
    );
    final busyEnter = section!['busyEnter'];
    expect(
      busyEnter,
      isA<String>(),
      reason: '宿主 settings 里必须有 busyEnter（桌面读的也是它）',
    );
    expect(
      {'queue', 'steer'},
      contains(busyEnter),
      reason: '线上值只有 queue / steer',
    );
    // 另外三个 ns 也要在（否则是"整个设置面都没通"，不是只有它缺）。
    for (final ns in [
      'permission',
      'agent-preset-registry',
      'session-log-deepseek',
    ]) {
      expect(app.settingsOf(ns), isNotNull, reason: '$ns 也应当在');
    }

    // ---- ② 写：busyEnter 真的写得进去、回读得到 ----
    final original = app.sendMode;
    final target = original == SendMode.steer ? SendMode.queue : SendMode.steer;
    await app.setSendMode(target);
    final written = await _waitFor(
      tester,
      () async =>
          app.settingsValue('ui-conversation', 'busyEnter') == target.wire,
    );
    expect(
      written,
      isTrue,
      reason: '写宿主设置后回读必须是新值；lastError=${app.lastError?.code}',
    );
    // 还原（这条探针不许改用户的设置）。
    await app.setSendMode(original);
    final restored = await _waitFor(
      tester,
      () async =>
          app.settingsValue('ui-conversation', 'busyEnter') == original.wire,
    );
    expect(restored, isTrue, reason: '探针必须把设置写回原值');

    // ---- ③ 列表行里到底有没有 subagentCatalog ----
    final raw = await client.call<Object?>('session.list', const {});
    final rows = switch (raw) {
      {'sessions': final List<Object?> list} => list,
      _ => const <Object?>[],
    };
    expect(rows, isNotEmpty, reason: '这台 profile 上有会话');

    var withKey = 0;
    var withChildren = 0;
    for (final row in rows) {
      final projections = row is Map ? row['projections'] : null;
      final values = projections is Map ? projections['values'] : null;
      if (values is! Map) continue;
      final catalog = values['subagentCatalog'];
      if (catalog is! List) continue;
      withKey += 1;
      if (catalog.isNotEmpty) withChildren += 1;
    }
    // 打印分布，便于下一次跑时对照（有子智能体的会话不一定此刻存在）。
    debugPrint(
      'session.list 行数=${rows.length}，带 subagentCatalog 键=$withKey，'
      '带子级=$withChildren',
    );
    expect(
      withKey,
      greaterThan(0),
      reason:
          'subagentCatalog 是 summary 键（默认携带）：至少有一行要带它，'
          '否则批 E 的 runningChildrenOf 永远读到空表',
    );
  });
}
