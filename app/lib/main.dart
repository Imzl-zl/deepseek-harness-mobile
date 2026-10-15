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

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import 'core/box.dart';
import 'core/crypto.dart';
import 'core/endpoint.dart';
import 'core/endpoint_transport.dart';
import 'core/errors.dart';
import 'core/frame.dart';
import 'core/handshake_driver.dart';
import 'core/outbox.dart';
import 'core/pairing_client.dart';
import 'core/recovery.dart';
import 'core/sync_client.dart' hide AppState;
import 'core/sync_client_impl.dart';
import 'core/transport.dart';
import 'data/app_model.dart';
import 'data/connection_recovery.dart';
import 'data/store.dart';
import 'model/chat_item.dart';
import 'platform/app_state_reporter.dart';
import 'platform/http_sender.dart';
import 'platform/pairing_store.dart';
import 'platform/sqflite_item_store.dart';
import 'platform/ticketed_transport.dart';
import 'platform/transport_factory.dart';
import 'platform/websocket_transport.dart';
import 'theme/dsh_theme.dart';
import 'ui/chat_page.dart';
import 'ui/connection_actions_sheet.dart';
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
  /// 聊天页的 key —— 用来从外面开抽屉（[ChatPageState.openDrawer]）。
  ///
  /// 抽屉要盖住整个 `Scaffold`（含顶栏），所以它必须是聊天页 `Scaffold`
  /// 的 `drawer`；而"谁来开它"是外层的事（顶栏的 `☰`、空态的按钮）。
  ///
  /// **类型必须是 `ChatPageState`，不能是 `ScaffoldState`**（踩过）：
  /// 挂着 `GlobalKey<ScaffoldState>` 的 `ChatPage` 拿不到 `ScaffoldState`，
  /// 于是 `currentState` **恒为 `null`**，而调用处写的是
  /// `_chatKey.currentState?.openDrawer()` —— 那个 `?.` **静默失效**：
  /// 点 `☰`、点空态里的"打开会话抽屉"都毫无反应，**且不报任何错**（真机实测）。
  ///
  /// Note: `.agents/notes/implemented/2026-10-07-three-wire-shape-mismatches.md`
  final _chatKey = GlobalKey<ChatPageState>();

  /// 配对结果（`null` = 还没配对）。
  ///
  /// **它不再是"要不要显示界面"的依据** —— 没配对也进主界面（见 `_boot`）。
  /// 它只决定"要不要去连"。
  PairedCredentials? _credentials;

  AppModel? _app;
  bool _booting = true;

  /// 是否停在配对页（用户主动进来的，不是"没配对就挡在这里"）。
  bool _pairing = false;

  /// 配对页顶部横幅的一句话（**为什么会被送到这一页**）；主动进来时为 `null`。
  String? _pairingNotice;

  /// 前后台态的上报者（契约 §2.2、§9）。
  ///
  /// 它跟着根 State 活，而客户端跟着 [_app] 活 —— 所以报的是"当前那个"
  /// （重新配对会换 `AppModel`，observer 只注册一次）。
  late final AppStateReporter _reporter = AppStateReporter(() => _app?.client);

  /// 连接终态失败的恢复编排（议题 2 的 `ClientAction` 唯一执行处）。
  ///
  /// 三个缝都指向本 State：清凭据 = `PairingStore.clear`，回配对页 =
  /// [_enterPairing]，上报 = [_reportConnectionDefect]。手动"重新配对"
  /// （议题 3，用户点）与自动"身份被拒"（议题 2，连接层呈递）都经它，
  /// 收敛到同一个动作 —— 别处不再各自判 `notPaired`。
  late final ConnectionRecovery _recovery;

  @override
  void initState() {
    super.initState();
    _recovery = ConnectionRecovery(
      clearCredentials: PairingStore.clear,
      openPairing: _enterPairing,
      report: _reportConnectionDefect,
    );
    WidgetsBinding.instance.addObserver(_reporter);
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
      final app = await _assembleWithoutCredentials(_recovery.onTerminated);
      if (!mounted) return;
      setState(() {
        _app = app;
        _booting = false;
      });
      return;
    }
    final app = await _assemble(saved, _recovery.onTerminated);
    if (!mounted) return;
    setState(() {
      _credentials = saved;
      _app = app;
      _booting = false;
    });
    await app.start();
  }

  /// 进配对页（**用户主动**：`没配对`时的入口按钮，或设置里"重新配对"）。
  ///
  /// 主动进来时**没有"为什么"**，所以把横幅清掉 —— 留着上一次的原因会让人
  /// 以为"我刚又被拒了一次"。
  void _openPairing() => setState(() {
    _pairing = true;
    _pairingNotice = null;
  });

  void _closePairing() => setState(() => _pairing = false);

  Future<void> _onPaired(PairingResult result) async {
    // 端点表的种子：配对那一刻走的那条中转。之后连接器会自报直连地址，
    // 由 `endpoint.describe` 合并进来（见 `_discoverEndpoints`）。
    final endpoints = <Endpoint>[
      Endpoint(
        kind: EndpointKind.relay,
        url: result.offer.relayUrl,
        label: '中转',
      ),
    ];
    final credentials = PairedCredentials(
      relayUrl: result.offer.relayUrl,
      endpoints: endpoints,
      pcSignPubHex: result.offer.pcSignPubHex,
      pcDhPubHex: result.offer.pcDhPubHex,
      pairingId: result.pairingId,
      masterSeedHex: result.masterSeedHex,
      devSignPubHex: result.devSignPubHex,
      devDhPubHex: result.devDhPubHex,
      // 这两个是**长期凭据**（之后每次重连换票用它；配对码已经用掉了）。
      deviceToken: result.deviceToken,
      refreshToken: result.refreshToken,
      pcId: result.pcId,
      devId: result.devId,
    );
    await PairingStore.save(credentials);
    final app = await _assemble(credentials, _recovery.onTerminated);
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
    WidgetsBinding.instance.removeObserver(_reporter);
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
      return PairingPage(
        onPaired: _onPaired,
        onCancel: _closePairing,
        // 两个缝在这里注入：UI 不认识 `package:http`，也不认识 WebSocket ——
        // 真实实现在 `platform/`，而"用哪个实现"只发生在装配点（本文件）。
        send: _httpSender,
        transportFor: _pairingTransport,
        // 本机调试（`ws://127.0.0.1`）只在 debug 构建里放行：契约 §12.1 的
        // 生产纪律是 WSS，而 release 里放行明文等于把"以为加密了"的链路走成明文。
        allowInsecureLocal: kDebugMode,
        // **为什么会被送到这一页**：常驻横幅（身份被拒 / 手动重配各一句话）。
        // 不用 SnackBar：它 4 秒就消失，而用户是被自动送到这里的。
        notice: _pairingNotice,
      );
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
        // 议题 3：连接操作 sheet 的"重新配对 / 断开并清掉凭据"。
        onRePair: _repair,
        onDisconnect: () => unawaited(_resetPairing()),
        onOpenDrawer: () => _chatKey.currentState?.openDrawer(),
        onNewSession: _newSession,
        // 主界面上的内联会话列表：与抽屉走**同一条**通路（`openSession`），
        // 免得两处各写一份"点了之后怎么办"。
        onOpenSession: (session) => unawaited(app.openSession(session.sid)),
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

  /// 抽屉连接行的详情（换设备 / 断开重配）。
  ///
  /// 它必须有：否则**配错了就出不来** —— 手机认的是配对那一刻的电脑公钥，
  /// 而重配对会换 `pairingId`（电脑侧记的是旧的那个）。没有这条出路时，
  /// 用户只能卸载重装。
  ///
  /// 复用 `ui/connection_actions_sheet.dart` 的同一形状（议题 3：三个入口
  /// 共用一个 sheet，不各画一份）。抽屉这条路保留，不影响既有用户。
  Future<void> _showConnectionSheet() async {
    unawaited(Navigator.of(context).maybePop());
    await showConnectionActionsSheet(
      context,
      onRePair: _repair,
      onOpenSide: () => _chatKey.currentState?.openSide(),
      onDisconnect: () => unawaited(_resetPairing()),
    );
  }

  /// 重新配对（换一台电脑）：清凭据 + 回配对页。
  ///
  /// 手动入口（连接操作 sheet 的"重新配对"）与自动入口（身份被拒，
  /// 经 `ConnectionRecovery.onTerminated`）都收敛到 `_recovery.repair()` ——
  /// 那是 `ClientAction.rePair` 的唯一执行处。
  void _repair() => unawaited(_recovery.repair());

  /// 身份被拒/重新配对后：换一个"没配对"的 AppModel + 进配对页 + 给一句话。
  ///
  /// `ConnectionRecovery.openPairing` 缝接到这里。旧客户端已终态停摆
  /// （换票被拒 → 不重连），后台换掉它；前台立刻进配对页。
  ///
  /// 那句话走**配对页顶部的常驻横幅**（`PairingPage.notice`）而不是 SnackBar：
  /// 用户是被自动送到这一页的，SnackBar 4 秒就没了，看到时已经不解释"为什么"。
  void _enterPairing(String message) {
    unawaited(_reassembleUnpaired());
    setState(() {
      _pairingNotice = message;
      _pairing = true;
    });
  }

  /// 如实上报一个连接层处理不了的终态错误（`ConnectionRecovery.report` 缝）。
  ///
  /// **不加静默兜底**：映射不到的动作照实显示，绝不"试试看继续重连"。
  void _reportConnectionDefect(ProtocolException error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('连接失败：${error.code.wire}：${error.message}')),
    );
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
        title: s.displayTitle,
        // **待处理数进副标题**：多会话并行时，用户靠它知道该切去哪个会话
        // （DSH 的待处理是 per-session 的，切过去才看得见）。
        preview: [
          if (s.pendingCount > 0) '${s.pendingCount} 个待处理',
          if (s.itemCount > 0) '${s.itemCount} 条',
          if (s.pendingCount == 0 && s.itemCount == 0) s.sid,
        ].join(' · '),
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
    await _reassembleUnpaired();
  }

  /// 换一个"没配对"的 AppModel（**不清凭据** —— 清不清由调用方决定）。
  ///
  /// 分离出来：`ConnectionRecovery` 已经自己清过凭据，回配对页时只要"换客户端"，
  /// 不要再清一次。旧客户端已终态停摆（换票被拒 → 不重连），换掉即可。
  Future<void> _reassembleUnpaired() async {
    if (!mounted) return;
    final app = await _assembleWithoutCredentials(_recovery.onTerminated);
    if (!mounted) return;
    setState(() {
      _credentials = null;
      _app = app;
    });
  }
}

/// **HTTP 缝的真实实现**（换票用）。
///
/// 它只在配对那一刻被调到（一次配对一次请求），所以不必常驻连接池 ——
/// 实现里每次调用建一个短命的 client 并关掉（见 `platform/http_sender.dart`）。
final HttpSender _httpSender = createHttpSender();

/// **配对传输的真实实现**：给一条**已经拼好票**的 URL，建一条 WS。
///
/// 配对那条连接**用完即关**（`PairingChannel.close`）：配对是一次短交互，
/// 完成后 App 会用正式传输重新连（那一次才是长期连接）。留着这条 socket
/// 只会让中转上多出一条谁也不用的连接 —— 而同一个身份只该有一条。
///
/// 缝为什么设在这里（"URL 已拼好"，而不是"整个交换"）：URL 的形状是**协议知识**
/// （唯一 owner 是 `core/endpoint.dart` 的 `deviceUpgradeUrl`），而"怎么拨号"才是
/// 平台的事。缝设在更外面，就得把换票、握手、封箱在平台层再实现一遍。
ChannelTransport _pairingTransport(String upgradeUrl) =>
    WebSocketTransport(WebSocketTransportOptions(url: upgradeUrl));

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
Future<AppModel> _assembleWithoutCredentials([
  void Function(ProtocolException)? onConnectionTerminated,
]) async {
  final store = SqfliteItemStore();
  await store.open();
  return AppModel(
    // 偏好走同一个库的 `meta` 表（`MetaPreferences` 包一层窄缝）——
    // 发送模式这类"穿过协议"的偏好必须落盘，重启后还是用户选的那个。
    prefs: MetaPreferences(store),
    onConnectionTerminated: onConnectionTerminated,
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
Future<AppModel> _assemble(
  PairedCredentials credentials, [
  void Function(ProtocolException)? onConnectionTerminated,
]) async {
  // 本地库：**先开库再装配**。条目与水位都落在这里（契约 §8.3 的 schema
  // 定义在 `data/store.dart`，驱动是 sqflite —— 三端同源、只有驱动分叉）。
  final store = SqfliteItemStore();
  await store.open();

  // 身份：从主种子派生两把长期密钥（契约 §4.1）。
  // 只存一个 secret —— 三端安全存储才统一得起来（`app-platform-boundaries.md` §5）。
  final identity = await deriveIdentity(credentials.masterSeedHex);
  final staticKeys = await x25519FromSeed(identity.dhSeedHex);
  // `devId` 优先用**电脑侧给的那个**（配对回执里的权威值），
  // 没有才本地推导（与电脑侧 `deviceIdOf` 同一算式）—— `hello` 里要带它，
  // 而两端算得不一样的话，电脑侧会把它当成一台没见过的设备（症状是"配对成功但连不上"）。
  final deviceId = await credentials.helloDeviceId();

  // 传输：**按有序端点表拨号，失败自动换下一个**。
  //
  // 中转与直连的差别只在"要不要先换一张票"：中转只接受
  // `/ws/device?ticket=…`（拿根路径去连会得到 404，而中转对 404 只
  // `log?.debug`，手机侧表现为"连不上、日志无原因"），且票是**一次性**的 ——
  // 连接层退避后会反复重连，所以换票必须发生在每一次建连里。
  // 直连没有票、没有固定路径：鉴权就是握手本身。
  //
  // 每个中转端点各持一个 `PairingClient`（按地址缓存）：换端点不该让
  // "票从哪来"这件事有第二个答案。
  final pairingClients = <String, PairingClient>{};
  TicketSource? ticketSourceFor(Endpoint endpoint) {
    if (endpoint.kind != EndpointKind.relay) return null;
    final client = pairingClients.putIfAbsent(
      endpoint.url,
      () => PairingClient(
        relayUrl: endpoint.url,
        send: _httpSender,
        // **明文联调放行必须与 PairingPage 用同一个判据**。
        //
        // 少了它，配对成功也换不到票：`PairingClient` 默认拒绝 `ws://`
        // （`core/pairing_client.dart` 的 `allowInsecureLocal` 默认 false），
        // 而症状正是"码认了、票换不了"—— 真机实测踩到（2026-10-13）。
        // 这是明文放行的**第三处**：另两处是 Android 的
        // `network_security_config.xml` 与 `PairingPage.allowInsecureLocal`。
        allowInsecureLocal: kDebugMode,
      ),
    );
    return () async =>
        (await client.ticketByDeviceToken(credentials.deviceToken)).ticket;
  }

  // 端点表**可换**：`endpoint.describe` 的发现结果写回这个列表，
  // 而 `EndpointTransport` 每次 `connect()` 现读它 —— 所以发现立刻生效，
  // 不用重启 App。发现**不踹掉正在用的连接**（那只影响下一次建连）。
  final endpoints = List<Endpoint>.of(credentials.endpoints);
  final transport = EndpointTransport(
    endpointsOf: () => endpoints,
    factory: (endpoint) =>
        transportFor(endpoint, ticket: ticketSourceFor(endpoint)),
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

  final app = AppModel(
    // 偏好走同一个库的 `meta` 表（见 `_assembleWithoutCredentials` 同一处）。
    prefs: MetaPreferences(store),
    client: client,
    // 端点表交给 `AppModel` 当所有者：界面要读、设置页要改，而上面的
    // `EndpointTransport` 每次 `connect()` 现读**同一个 list 实例** ——
    // 所以这里发现/改序会立刻反映到下一次拨号。
    endpoints: endpoints,
    onEndpointsChanged: PairingStore.saveEndpoints,
    // 连接终态失败（身份不被认）→ 清凭据回配对页。见 `_recovery`。
    onConnectionTerminated: onConnectionTerminated,
  );
  // 拨通了就报给界面：设置页据此显示"当前走哪条"。**只报事实** ——
  // 表的所有权在 `AppModel`，传输层不写它。
  transport.onActivated = app.reportActiveEndpoint;
  return app;
}
