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
import 'core/transport.dart';
import 'data/app_model.dart';
import 'data/store.dart';
import 'model/chat_item.dart';
import 'platform/pairing_store.dart';
import 'platform/sqflite_item_store.dart';
import 'platform/websocket_transport.dart';
import 'theme/dsh_colors.dart';
import 'theme/dsh_icons.dart';
import 'theme/dsh_theme.dart';
import 'ui/chat_page.dart';
import 'ui/pairing_page.dart';
import 'ui/session_drawer.dart';

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
  /// 聊天页的 key —— 用来从外面开抽屉（`openDrawer`）。
  ///
  /// 抽屉要盖住整个 `Scaffold`（含顶栏），所以它必须是聊天页 `Scaffold`
  /// 的 `drawer`；而"谁来开它"是外层的事（顶栏的 `☰`、空态的按钮）。
  final _chatKey = GlobalKey<ScaffoldState>();

  /// 配对结果（`null` = 还没配对）。
  ///
  /// **它不再是"要不要显示界面"的依据** —— 没配对也进主界面（见 `_boot`）。
  /// 它只决定"要不要去连"。
  PairedCredentials? _credentials;

  AppModel? _app;
  bool _booting = true;

  /// 是否停在配对页（用户主动进来的，不是"没配对就挡在这里"）。
  bool _pairing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    final saved = await PairingStore.load();
    if (!mounted) return;
    if (saved == null) {
      // **没配对也进主界面**。
      //
      // 早先的写法是"没配对就显示配对页"，而那让"这一版做出来是什么样"
      // 无法回答 —— 用户打开 App 只看得到一张配对表单，看不到任何界面。
      // 界面本来就该能看：它不依赖电脑，只依赖数据。
      //
      // 所以：没有凭据时**建一个不连的客户端**（`client` 存在但不 start），
      // 界面照常渲染（会话列表会是空的，用户还能点"看示例数据"）。
      final app = await _assembleWithoutCredentials();
      if (!mounted) return;
      setState(() {
        _app = app;
        _booting = false;
      });
      return;
    }
    final app = await _assemble(saved);
    if (!mounted) return;
    setState(() {
      _credentials = saved;
      _app = app;
      _booting = false;
    });
    await app.start();
  }

  /// 进配对页（**用户主动**：`没配对`时的入口按钮，或设置里"重新配对"）。
  void _openPairing() => setState(() => _pairing = true);

  void _closePairing() => setState(() => _pairing = false);

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
      _pairing = false;
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
    if (app == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // 配对页是**用户主动进来的**（点"连电脑"），不是"没配对就挡在这里"。
    if (_pairing) {
      return PairingPage(onPaired: _onPaired, onCancel: _closePairing);
    }
    // **抽屉必须跟着 `AppModel` 重建**。
    //
    // 这一层原先直接 `_drawerSections(app)` 取一次列表就完事 —— 而
    // `AppModel` 是 `ChangeNotifier`：会话列表、连接状态、示例数据
    // 都靠 `notifyListeners()` 通知。不监听它就等于**列表永远停在首帧**：
    // 真实会话拉回来了、示例数据装上了，抽屉里却还是"还没有会话"。
    //（实测踩到：装了示例数据，`ChatPage` 里有内容，抽屉里是空的。）
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => ChatPage(
        key: _chatKey,
        app: app,
        paired: _credentials != null,
        onConnect: _openPairing,
        onOpenDrawer: () => _chatKey.currentState?.openDrawer(),
        onNewSession: _newSession,
        drawer: SessionDrawer(
          sections: _drawerSections(app),
          connection: DrawerConnection(
            name: _credentials == null ? '未配对' : '我的电脑',
            detail: _credentials == null
                ? '还没连电脑 · 点这里去配对'
                : _connectionDetail(app.connection),
            platform: _credentials == null ? '' : 'DSH',
            online: app.connection == ConnectionStateView.serving,
          ),
          footItems: [
            DrawerFootItem(
              icon: 'folderClose',
              label: '文件',
              onTap: () => _notYet('文件页'),
            ),
            DrawerFootItem(
              icon: 'archive',
              label: '归档',
              onTap: () => _notYet('归档列表'),
            ),
            DrawerFootItem(
              icon: 'sparkle',
              label: '示例',
              onTap: app.loadPreview,
            ),
            DrawerFootItem(
              icon: 'clock',
              label: '自动化',
              onTap: () => _notYet('自动化任务'),
            ),
            DrawerFootItem(
              icon: 'settings',
              label: '设置',
              onTap: () => _notYet('设置'),
            ),
          ],
          onNewSession: _newSession,
          onOpenSession: (session) {
            unawaited(Navigator.of(context).maybePop());
            unawaited(app.openSession(session.sid));
          },
          // 点连接状态行 → 已配对时给"重新配对 / 断开"的选择，没配对上配对页。
          onClose: () {
            if (_credentials == null) {
              unawaited(Navigator.of(context).maybePop());
              _openPairing();
              return;
            }
            unawaited(_showConnectionSheet());
          },
        ),
      ),
    );
  }

  /// 连接状态行的详情（换设备 / 断开重配）。
  ///
  /// 它必须有：否则**配错了就出不来** —— 手机认的是配对那一刻的电脑公钥，
  /// 而重配对会换 `pairingId`（电脑侧记的是旧的那个）。没有这条出路时，
  /// 用户只能卸载重装。
  Future<void> _showConnectionSheet() async {
    unawaited(Navigator.of(context).maybePop());
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: DshColors.layer1,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const DshIcon(
                'refresh',
                size: 18,
                color: DshColors.labelSecondary,
              ),
              title: const Text('重新配对（换一台电脑）'),
              subtitle: const Text('会清掉本机凭据，需要重新扫码'),
              onTap: () => Navigator.of(context).pop('repair'),
            ),
            ListTile(
              leading: const DshIcon('trash', size: 18, color: DshColors.error),
              title: const Text('断开并清掉凭据'),
              onTap: () => Navigator.of(context).pop('clear'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    await _resetPairing();
    if (!mounted) return;
    if (action == 'repair') _openPairing();
  }

  /// 新建会话：DSH 里会话由电脑侧建，所以这里走 `session.create`。
  ///
  /// **没配对时不做假动作**：直接提示去配对 —— 而不是造一个本地空会话
  ///（那会在抽屉里留下一个永远发不出消息的条目）。
  void _newSession() {
    unawaited(Navigator.of(context).maybePop());
    if (_credentials == null) {
      _openPairing();
      return;
    }
    unawaited(
      _app!.createSession().catchError(
        (Object error) => _notYet('新建会话（$error）'),
      ),
    );
  }

  void _notYet(String what) {
    unawaited(Navigator.of(context).maybePop());
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$what 还没做')));
  }

  static String _connectionDetail(ConnectionStateView state) => switch (state) {
    ConnectionStateView.serving => '中转已连接 · 空闲',
    ConnectionStateView.backoff => '重连中…',
    ConnectionStateView.connecting => '连接中…',
    ConnectionStateView.handshaking => '握手中…',
    _ => '未连接',
  };

  /// 会话按"今天 / 昨天 / 更早"分组（原型 `.dsec`）。
  List<DrawerSection> _drawerSections(AppModel app) {
    final now = DateTime.now();
    final today = <DrawerSession>[];
    final yesterday = <DrawerSession>[];
    final earlier = <DrawerSession>[];
    for (final s in app.sessions) {
      final at = DateTime.fromMillisecondsSinceEpoch(s.updatedAt);
      final days = DateTime(
        now.year,
        now.month,
        now.day,
      ).difference(DateTime(at.year, at.month, at.day)).inDays;
      final row = DrawerSession(
        sid: s.sid,
        title: s.title.isEmpty ? '（未命名会话）' : s.title,
        preview: s.itemCount == 0 ? s.sid : '${s.itemCount} 条',
        timeLabel: _relativeTime(days, at),
        isActive: s.sid == app.currentSid,
      );
      if (days <= 0) {
        today.add(row);
      } else if (days == 1) {
        yesterday.add(row);
      } else {
        earlier.add(row);
      }
    }
    return [
      if (today.isNotEmpty) DrawerSection(label: '今天', sessions: today),
      if (yesterday.isNotEmpty) DrawerSection(label: '昨天', sessions: yesterday),
      if (earlier.isNotEmpty) DrawerSection(label: '更早', sessions: earlier),
    ];
  }

  static String _relativeTime(int days, DateTime at) {
    if (days <= 0) {
      final h = at.hour.toString().padLeft(2, '0');
      final m = at.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }
    if (days == 1) return '昨天';
    if (days < 7) return '$days 天前';
    return '${at.month}/${at.day}';
  }

  /// 清掉配对（换设备 / 连不上时重来）。
  Future<void> _resetPairing() async {
    await PairingStore.clear();
    if (!mounted) return;
    final app = await _assembleWithoutCredentials();
    if (!mounted) return;
    setState(() {
      _credentials = null;
      _app = app;
    });
  }
}

/// 没配对时的**装配**：客户端存在但**不连**（没有可信的电脑身份就没法连）。
///
/// 它让界面照常可用 —— 会话列表是空的、能点"看示例数据"、能进各屏。
/// 这比"没配对就只显示一张配对表"有用得多：**界面不该被连接状态挡住**。
///
/// ## 为什么这里能复用真装配的零件
///
/// 因为那些零件**本来就不需要凭据**：本地库、发件箱、落盘缝都与电脑无关。
/// 只有"握手 ↔ 谁"需要电脑公钥，而这里给一个**不存在的对端**
/// （空串公钥、空配对标识）—— 它连不上任何真实的电脑，但**也不会被用到**：
/// 本函数不调 `start()`，而"连"只有一个触发点（配对成功后那一处）。
Future<AppModel> _assembleWithoutCredentials() async {
  final store = SqfliteItemStore();
  await store.open();
  return AppModel(
    client: createSyncClient(
      SyncClientDeps(
        // 没东西可连：一个永远建不起来的传输（它不会被用到）。
        transport: _UnpairedTransport(),
        handshake: createHandshakeDriver(
          identity: HandshakeIdentity(
            // 临时的本机身份（不落盘、不进安全存储）：**它不是设备身份**，
            // 只为了让驱动能构造出来。真身份来自配对后的主种子。
            staticKeys: await x25519FromSeed('00' * 32),
            signSeedHex: '00' * 32,
            devId: 'unpaired',
          ),
          peer: const PeerIdentity(
            pcSignPubHex: '',
            pcDhPubHex: '',
            pcId: '',
            pairingId: '',
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
    ),
  );
}

/// 没配对时的占位传输：**永远连不上**，而它不该被调用。
///
/// 它如实抛错（而不是静默成功）—— 若哪天有人误调了 `start()`，
/// 这条错误会立刻指出来，而不是留下一个"看着像连上了"的假状态。
class _UnpairedTransport implements ChannelTransport {
  @override
  Future<Stream<TransportEvent>> connect() async {
    throw const TransportException('还没配对：没有可信的电脑身份，无法建连');
  }

  @override
  bool send(String line) => false;

  @override
  Future<void> close() async {}
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
