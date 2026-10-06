/// 应用入口与**唯一的装配点**（`app-platform-boundaries.md` §1 的 `platform/`）。
///
/// ## 这一层做什么
///
/// 把"接口"与"实现"接起来：`core/` 定义了 `ChannelTransport` 等缝，
/// 而**只有这里**知道用哪个实现。业务代码（`core/` / `data/` / `ui/`）
/// 一律不认识具体实现 —— 于是换实现（真 socket ↔ 测试桩）不改业务。
///
/// ## 配对之前不建连
///
/// 配对是"把可信的电脑身份从带外搬进来"的那一步（契约 §12.1）。
/// 在做完之前，手机**没有任何可信的公钥**，建连只会拿到一个必然失败的连接，
/// 而用户看到的是"连不上"——他会去查网络，真因却是"还没配对"。
///
/// 所以启动流程是：[PairingPage] → 得到凭据 → [SessionListPage]。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'core/box.dart';
import 'core/crypto.dart';
import 'core/frame.dart';
import 'core/handshake_driver.dart';
import 'core/outbox.dart';
import 'core/recovery.dart';
import 'core/sync_client.dart' hide AppState;
import 'core/sync_client_impl.dart';
import 'data/app_model.dart';
import 'data/store.dart';
import 'platform/pairing_store.dart';
import 'platform/sqflite_item_store.dart';
import 'platform/websocket_transport.dart';
import 'theme/dsh_theme.dart';
import 'ui/pairing_page.dart';
import 'ui/session_list_page.dart';

void main() {
  runApp(const DshMobileApp());
}

/// 应用根。
class DshMobileApp extends StatefulWidget {
  const DshMobileApp({super.key});

  @override
  State<DshMobileApp> createState() => _DshMobileAppState();
}

class _DshMobileAppState extends State<DshMobileApp> {
  /// 配对结果（`null` = 还没配对）。它是"要不要显示配对页"的唯一依据。
  PairedCredentials? _credentials;

  AppModel? _app;
  bool _booting = true;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    final saved = await PairingStore.load();
    if (!mounted) return;
    // **已配对就直接进列表**：重新配对会换 `pairingId`，
    // 而电脑侧记的是旧的那个 —— 表现为"这台设备不见了"。
    if (saved != null) {
      final app = await _assemble(saved);
      if (!mounted) return;
      setState(() {
        _credentials = saved;
        _app = app;
        _booting = false;
      });
      await app.start();
      return;
    }
    setState(() => _booting = false);
  }

  Future<void> _onPaired(PairingResult result) async {
    final credentials = PairedCredentials(
      relayUrl: result.offer.relayUrl,
      pcSignPubHex: result.offer.pcSignPubHex,
      pcDhPubHex: result.offer.pcDhPubHex,
      pairingId: result.pairingId,
      masterSeedHex: result.masterSeedHex,
      devSignPubHex: result.devSignPubHex,
      devDhPubHex: result.devDhPubHex,
    );
    await PairingStore.save(credentials);
    final app = await _assemble(credentials);
    if (!mounted) return;
    setState(() {
      _credentials = credentials;
      _app = app;
    });
    await app.start();
  }

  @override
  void dispose() {
    _app?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DSH Mobile',
      debugShowCheckedModeBanner: false,
      theme: DshTheme.dark(),
      home: _body(),
    );
  }

  Widget _body() {
    if (_booting) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final app = _app;
    if (app == null || _credentials == null) {
      return PairingPage(onPaired: _onPaired);
    }
    return SessionListPage(app: app);
  }
}

/// **装配**：把 `core/` 的零件接到一起，产出可用的 `AppModel`。
///
/// 这是全项目唯一一处"知道用哪个实现"的地方（见文件头）。
Future<AppModel> _assemble(PairedCredentials credentials) async {
  // 本地库：**先开库再装配**。条目与水位都落在这里（契约 §8.3 的 schema
  // 定义在 `data/store.dart`，驱动是 sqflite —— 三端同源、只有驱动分叉）。
  final store = SqfliteItemStore();
  await store.open();

  // 身份：从主种子派生两把长期密钥（契约 §4.1）。
  // 只存一个 secret —— 三端安全存储才统一得起来（`app-platform-boundaries.md` §5）。
  final identity = await deriveIdentity(credentials.masterSeedHex);
  final staticKeys = await x25519FromSeed(identity.dhSeedHex);
  // `devId` 由本机推导（与电脑侧 `deviceIdOf` 同一算式）—— `hello` 里要带它，
  // 而那时还没收到任何回执（见 `pairing_store.dart` 的 `deriveDeviceId`）。
  final deviceId = await credentials.deviceId();

  final transport = WebSocketTransport(
    WebSocketTransportOptions(url: credentials.relayUrl),
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
          // **公钥只来自二维码**（契约 §12.1 的硬规则）：
          // 不接受任何网络下发的电脑公钥。它们经 `PairingStore` 从配对那一刻存下来。
          pcSignPubHex: credentials.pcSignPubHex,
          pcDhPubHex: credentials.pcDhPubHex,
          pcId: credentials.pcId,
          pairingId: credentials.pairingId,
        ),
        // 临时密钥与 nonce **每次建连都新生成**（契约 §4.1）。
        newEphemeralSeedHex: () => toHex(randomBytes(32)),
        newNonceHex: () => toHex(randomBytes(32)),
        newFrameIdHex: () => newFrameId(randomBytes(frameIdBytes)),
      ),
      box: (keys) => BoxCodec(keys: keys, role: HandshakeRole.initiator),
      // 发件箱与本地库**都落到真正的库上**。
      //
      // 出帧口不在这里传 —— 只有 `SyncClient` 知道"帧怎么发"（要过流控、
      // 走 `_write`、带 `fc`），所以它在自己构造完之后装上（见
      // `Outbox.attachSender` 的说明：装配点传假实现会让队列**永远发不出去**
      // 而没有任何报错）。
      outbox: Outbox(store: SqfliteOutboxStore(store)),
      session: DeviceSession(),
      persistence: StoreItemPersister(store),
    ),
  );

  return AppModel(client: client);
}
