/// 应用入口与**唯一的装配点**（`app-platform-boundaries.md` §1 的 `platform/`）。
///
/// ## 这一层做什么
///
/// 把"接口"与"实现"接起来：`core/` 定义了 `ChannelTransport` 等缝，
/// 而**只有这里**知道用哪个实现。业务代码（`core/` / `data/` / `ui/`）
/// 一律不认识具体实现 —— 于是换实现（真 socket ↔ 测试桩）不改业务。
///
/// ## 为什么装配点只有一个
///
/// 三端差异（安全存储、推送、保活）将来都在这一层选。如果"选哪个实现"的分支
/// 散在各处，"支持第四端"就会变成改一堆文件；而收在一处时，它只是加一个 case。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'core/box.dart';
import 'core/crypto.dart';
import 'core/frame.dart';
import 'core/handshake_driver.dart';
import 'core/outbox.dart';
import 'core/recovery.dart';
import 'core/sync_client.dart';
import 'core/sync_client_impl.dart';
import 'data/app_model.dart';
import 'platform/websocket_transport.dart';
import 'theme/dsh_theme.dart';
import 'ui/session_list_page.dart';

/// 运行期配置（**目前是占位**：真机联调时由配对流程写入）。
///
/// 如实记录：这些值还没有来源 —— 配对（契约 §12.1）要做的正是"扫码拿到
/// `relay` / `pcPubEd` / `pcPubDh` / `code` 并落进安全存储"。
/// 在它落地之前，本页给的是**占位值**，所以连不上是预期的。
class BootstrapConfig {
  const BootstrapConfig({
    required this.relayUrl,
    required this.pcSignPubHex,
    required this.pcDhPubHex,
    required this.deviceId,
    required this.signSeedHex,
  });

  /// 中转地址（`wss://…`）。
  final String relayUrl;

  /// 电脑侧 Ed25519 公钥（**只来自二维码**，契约 §12.1 的硬规则）。
  final String pcSignPubHex;

  /// 电脑侧 X25519 静态公钥（同上）。
  final String pcDhPubHex;

  /// 本机设备 id。
  final String deviceId;

  /// 本机 Ed25519 身份种子。
  ///
  /// **它是设备身份**，生产里必须从系统安全存储读（三端能力包的事），
  /// 而不是写死在代码里 —— 这里写死是为了让"能跑起来"这一步先成立。
  final String signSeedHex;
}

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
  AppModel? _app;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    final app = await _assemble();
    if (!mounted) return;
    setState(() => _app = app);
    await app.start();
  }

  @override
  void dispose() {
    _app?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = _app;
    return MaterialApp(
      title: 'DSH Mobile',
      debugShowCheckedModeBanner: false,
      theme: DshTheme.dark(),
      home: app == null ? const _BootingPage() : SessionListPage(app: app),
    );
  }
}

/// 启动页（装配是异步的：要从种子派生身份）。
class _BootingPage extends StatelessWidget {
  const _BootingPage();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

/// **装配**：把 `core/` 的零件接到一起，产出可用的 `AppState`。
///
/// 这是全项目唯一一处"知道用哪个实现"的地方（见文件头）。
Future<AppModel> _assemble() async {
  const config = BootstrapConfig(
    // 占位：配对落地后由安全存储提供。
    relayUrl: 'wss://relay.invalid/ws/connector',
    pcSignPubHex: '',
    pcDhPubHex: '',
    deviceId: 'phone-dev-1',
    signSeedHex: '',
  );

  // 身份：从主种子派生两把长期密钥（契约 §4.1）。
  // 种子为空时给一个**仅用于本地跑通**的零种子 —— 它连不上任何真实的电脑，
  // 但让 App 能启动、UI 能显示。这是"先做一个出来看看"的必要妥协，
  // 写在这里而不是散在业务里。
  final seed = config.signSeedHex.isEmpty ? '00' * 32 : config.signSeedHex;
  final identity = await deriveIdentity(seed);
  final staticKeys = await x25519FromSeed(identity.dhSeedHex);

  final transport = WebSocketTransport(
    WebSocketTransportOptions(
      url: config.relayUrl,
      // 连接器令牌走升级头（契约 §2.2）—— 配对落地后从安全存储读。
      headers: const {},
    ),
  );

  final client = createSyncClient(
    SyncClientDeps(
      transport: transport,
      handshake: createHandshakeDriver(
        identity: HandshakeIdentity(
          staticKeys: staticKeys,
          signSeedHex: identity.signSeedHex,
          devId: config.deviceId,
        ),
        peer: PeerIdentity(
          pcSignPubHex: config.pcSignPubHex.isEmpty
              ? '00' * 32
              : config.pcSignPubHex,
          pcDhPubHex: config.pcDhPubHex.isEmpty ? '00' * 32 : config.pcDhPubHex,
          pcId: 'pc-1',
          pairingId: 'local-placeholder',
        ),
        // 临时密钥与 nonce **每次建连都新生成**（契约 §4.1）。
        newEphemeralSeedHex: () => toHex(randomBytes(32)),
        newNonceHex: () => toHex(randomBytes(32)),
        newFrameIdHex: () => newFrameId(randomBytes(frameIdBytes)),
      ),
      box: (keys) => BoxCodec(keys: keys, role: HandshakeRole.initiator),
      outbox: Outbox(store: InMemoryOutboxStore(), send: (_) async => false),
      session: DeviceSession(),
    ),
  );

  return AppModel(client: client);
}
