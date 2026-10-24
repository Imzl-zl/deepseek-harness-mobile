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
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
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
import 'model/session_dot.dart';
import 'model/theme_mode.dart';
import 'model/workspace.dart';
import 'platform/app_state_reporter.dart';
import 'platform/http_sender.dart';
import 'platform/lan_address.dart';
import 'platform/notify_factory.dart';
import 'platform/pairing_store.dart';
import 'platform/sqflite_item_store.dart';
import 'platform/ticketed_transport.dart';
import 'platform/transport_factory.dart';
import 'platform/websocket_transport.dart';
import 'theme/dsh_colors.dart';
import 'theme/dsh_theme.dart';
import 'ui/archive_sheet.dart';
import 'ui/chat_page.dart';
import 'ui/connection_actions_sheet.dart';
import 'ui/dsh_brand.dart';
import 'ui/dsh_shimmer.dart';
import 'ui/files_page.dart';
import 'ui/pairing_page.dart';
import 'ui/plugins_page.dart';
import 'ui/session_drawer.dart';
import 'ui/settings_page.dart';
import 'ui/usage_page.dart';

void main() {
  runApp(const DshMobileApp());
}

/// 应用根。
class DshMobileApp extends StatefulWidget {
  const DshMobileApp({super.key});

  @override
  State<DshMobileApp> createState() => _DshMobileAppState();
}

class _DshMobileAppState extends State<DshMobileApp>
    with WidgetsBindingObserver {
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

  /// 主题真值（三档 + 当下亮暗）。
  ///
  /// 2026-10-19 加浅色套时引入：DSH 的 `design-platform.css` 一上来就有
  /// 两套（浅色是 `:root`、深色是覆盖块），我们原先只落了深色。
  /// 它是 `ChangeNotifier`，亮暗变化时 `build` 里读它决定 `MaterialApp.themeMode`。
  final ThemeController _theme = ThemeController.restore(
    null,
    systemBrightness: PlatformDispatcher.instance.platformBrightness,
  );

  /// 是否停在配对页（用户主动进来的，不是"没配对就挡在这里"）。
  bool _pairing = false;

  /// 配对页顶部横幅的一句话（**为什么会被送到这一页**）；主动进来时为 `null`。
  String? _pairingNotice;

  /// 进配对页时上报给电脑侧的**旧配对标识**（`pair-commit` 的 `previousPairingId`）。
  ///
  /// 两个来源：① 凭据还在（直接进配对页）—— 现算；② 凭据刚被"重新配对 /
  /// 断开重来"清掉 —— 清之前抓成快照。没有它，电脑侧认不出"这是同一台手机
  /// 在换凭证"，只会又攒一行（2026-10-17 真机：一个手机扫 5 次 = 5 行）。
  /// 取值器按二维码的 `pcId` 过滤：换一台电脑扫它是 null（那边没有旧行可替换）。
  /// 取舍与威胁模型：`.agents/notes/implemented/2026-10-17-repair-replaces-device-row.md`。
  String? Function(String pcId)? _previousPairingIdOf;

  /// 刷新旧配对标识快照。**凭据已被清掉时不清空** —— 那正是要靠清之前的
  /// 快照的时候（`_recovery.repair` 先清凭据、再开配对页）。
  void _refreshRePairHint() {
    final credentials = _credentials;
    if (credentials == null || credentials.pairingId.isEmpty) return;
    final pairingId = credentials.pairingId;
    final pcId = credentials.pcId;
    _previousPairingIdOf = (String scannedPcId) =>
        pcId.isNotEmpty && pcId == scannedPcId ? pairingId : null;
  }

  /// 前后台态的上报者（契约 §2.2、§9）。
  ///
  /// 它跟着根 State 活，而客户端跟着 [_app] 活 —— 所以报的是"当前那个"
  /// （重新配对会换 `AppModel`，observer 只注册一次）。
  late final AppStateReporter _reporter = AppStateReporter(
    () => _app?.client,
    // 同一个态变化的第二处收口：通知要它（"看着那个会话就不提醒"）与
    // 保活要它（退到后台才起前台服务）。判据仍然只有 `isForeground` 一处。
    onState: (state) => _app?.setAppForeground(isForeground(state)),
    // 报给连接层的态：保活生效时后台也照报 `foreground`（判据在
    // `AppModel.connectionForeground`，这里只转达）。
    activeFor: (state) =>
        _app?.connectionForeground(isForeground(state)) ?? isForeground(state),
  );

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
      // 清凭据**之前**先把旧配对标识抓成快照：重新配对要靠它替换电脑侧的
      // 旧行，而清完之后手机就没有"我上次配过"的记忆了。
      clearCredentials: () async {
        _refreshRePairHint();
        await PairingStore.clear();
      },
      openPairing: _enterPairing,
      report: _reportConnectionDefect,
    );
    WidgetsBinding.instance.addObserver(_reporter);
    // **主题恢复必须在 `_boot` 之后**：它要从 `AppModel` 读偏好，
    // 而 `_app` 是 `_boot()` 建的。两条 `unawaited` 并行跑的话，
    // 主题恢复会读到 null（`_readPreference` 在 `_app == null` 时返回 null）
    // —— 于是用户选过的主题每次重启都被打回"跟随系统"（2026-10-19 真机复现）。
    unawaited(_boot().then((_) => _restoreTheme()));
  }

  /// 读回主题偏好并落到控制器上。
  ///
  /// **失败不影响启动**：主题是装饰，拿不到就按默认走。这一点与
  /// "连接/配对必须如实报错"不同 —— 后者拿不到用户就用不了 App。
  Future<void> _restoreTheme() async {
    String? stored;
    try {
      stored = await _readPreference(kThemeModeKey);
    } catch (_) {
      // 偏好读不到（库还没开 / 盘坏了）：按默认走，不阻塞启动。
      return;
    }
    if (!mounted) return;
    final restored = ThemeController.restore(
      stored,
      systemBrightness: PlatformDispatcher.instance.platformBrightness,
    );
    _theme.setMode(restored.mode);
  }

  /// 读一个字符串偏好（`meta` 表）。
  ///
  /// 缝由装配点给（[AppModel] 持着库），这一层不认识 sqflite。
  Future<String?> _readPreference(String key) async {
    final app = _app;
    if (app == null) return null;
    return app.readPreference(key);
  }

  /// 换主题模式并落盘。
  ///
  /// 设置页的那一行调它。**落盘失败不撤回内存里的选择** ——
  /// 用户已经看到界面变了，撤回来只会更错；而下次启动会读回旧值，
  /// 那时它自己会再变一次。
  Future<void> setThemeMode(DshThemeMode mode) async {
    _theme.setMode(
      mode,
      systemBrightness: PlatformDispatcher.instance.platformBrightness,
    );
    try {
      await _app?.writePreference(kThemeModeKey, mode.wire);
    } catch (_) {
      // 同上：不撤回。
    }
  }

  /// 系统亮暗变了（"跟随系统"档下要跟着变；显式选了浅/深时忽略）。
  ///
  /// 挂在 [WidgetsBindingObserver] 的 `didChangePlatformBrightness` 上 ——
  /// 官方给这条路的入口（`packages/flutter/lib/src/widgets/binding.dart:346`）。
  /// **它不带参数**，所以新的亮暗要从 `PlatformDispatcher` 自己读
  /// （`binding.dart:341-345` 的注释说明了这一点）。
  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    _theme.onSystemBrightness(PlatformDispatcher.instance.platformBrightness);
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
  void _openPairing() {
    // 直接进配对页（凭据还在）：现算旧配对标识。被清掉之后进来的走快照。
    _refreshRePairHint();
    setState(() {
      _pairing = true;
      _pairingNotice = null;
    });
  }

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
      // **旧客户端必须dispose**：它持着传输层（socket）。不 dispose 就换掉，
      // 旧连接会一直挂在电脑侧（真机实测出现过两条直连 socket 同时
      // ESTABLISHED），用户看到的是"连接不稳定"。
      _app?.dispose();
      _credentials = credentials;
      _app = app;
      _pairing = false;
    });
    // 下一次重新配对要报**新**的 pairingId（旧的那一行已经被替换掉了）。
    _refreshRePairHint();
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
    // **主题变化要重建整棵树**：`MaterialApp.themeMode` 在这一层读，
    // 而控制器是 `ChangeNotifier` —— `ListenableBuilder` 是官方给的缝
    // （`packages/flutter/lib/src/widgets/framework.dart`）。
    return ListenableBuilder(
      listenable: _theme,
      builder: (context, _) => MaterialApp(
        // 任务切换器里显示的名字。与安卓 `android:label`、iOS
        // `CFBundleDisplayName` 同一处口径（用户 2026-10-23 指定）；
        // 抽屉头部、会话里助手说话者的名字读的是同一个常量。
        title: kAppName,
        debugShowCheckedModeBanner: false,
        // **主题跟着 ThemeController 换**（2026-10-19：加浅色套）。
        //
        // `theme` / `darkTheme` 两个都给，而 `themeMode` 由控制器决定：
        // Flutter 的 `MaterialApp.themeMode` 正好是三档
        // （`ThemeMode.system` / `light` / `dark`，`material/app.dart`），
        // 与 DSH 的三档一一对应，不需要自己写分派。
        //
        // **两个 theme 都必须挂色板扩展**（`DshColorTokens`）：UI 经
        // `context.dshColors` 读当下那一套，而它挂在 ThemeData 上 ——
        // 只给一个 theme 挂扩展的话，另一个亮暗下会读到 null 退深色。
        theme: DshTheme.light(),
        darkTheme: DshTheme.dark(),
        themeMode: switch (_theme.mode) {
          DshThemeMode.system => ThemeMode.system,
          DshThemeMode.light => ThemeMode.light,
          DshThemeMode.dark => ThemeMode.dark,
        },
        navigatorKey: navigatorKey,
        // **系统栏（状态栏 / 导航栏）跟主题走**（2026-10-20）。
        //
        // 用户反馈："背景是不是不是全屏的？下面有一块都没覆盖"。
        // 实测（真机 1080×2400，深色主题，`x=30` 竖向扫描）：页面是
        // `#151517` 一直到 `y=2341`，但从 **`y=2342` 到屏幕底**是 `#19191A` ——
        // 约 19dp 的一整条，颜色与页面底不同。那不是我们的组件画的：
        // 我们的 `Scaffold.backgroundColor` 就是 `c.bgBase`。
        //
        // 根因（**照 SDK 文档，不是猜**）：
        // 1. `SystemUiMode` 的枚举注释写明 —— "If your app targets Android SDK 16
        //    (API 36) or later, then the Android system will ignore this value"；
        //    本机是 API 36、`targetSdk` 也是 36（`adb shell getprop
        //    ro.build.version.sdk` = 36），所以 `SystemUiMode` 那条路已经无效。
        // 2. `SystemUiMode.edgeToEdge` 的注释写明系统栏**永久显示在应用之上**，
        //    并指到 `SystemUiOverlayStyle`："can be used to configure transparent
        //    status and navigation bars with or without a contrast scrim"。
        // ⇒ 唯一有效的杠杆是 `SystemUiOverlayStyle`：把两条栏都设成**透明**，
        //    系统就不再在那块画自己的底色，我们自己的 `#151517` 直接透出来；
        //    图标亮暗跟随主题，浅色主题下才看得见。
        //
        // 用 `AnnotatedRegion` 而不是 `SystemChrome.setSystemUIOverlayStyle`：
        // 前者是**声明式**的（随路由/主题生效），后者是命令式的全局副作用，
        // 在主题热切换时会与真实状态漂移。
        builder: (context, child) {
          final dark = Theme.of(context).brightness == Brightness.dark;
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: dark
                  ? Brightness.light
                  : Brightness.dark,
              // iOS 的状态栏亮度语义务与 Android 相反（SDK 的
              // `statusBarBrightness` 注释），所以按平台给。
              statusBarBrightness: dark ? Brightness.dark : Brightness.light,
              systemNavigationBarColor: Colors.transparent,
              systemNavigationBarDividerColor: Colors.transparent,
              systemNavigationBarIconBrightness: dark
                  ? Brightness.light
                  : Brightness.dark,
            ),
            child: _uiScaled(
              DshShimmerHost(child: child ?? const SizedBox.shrink()),
            ),
          );
        },
        home: _body(),
      ),
    );
  }

  /// 把「界面字号」乘进 `MediaQuery.textScaler`（**两层**：系统 × App）。
  ///
  /// ## 为什么是这一条路
  ///
  /// 手机上字号本来就是两层的：系统字号（Android 的字体大小 / iOS Dynamic Type，
  /// Flutter 通过 `MediaQuery.textScaler` 递进来）与 App 内档位。主流 App 都是
  /// **两层相乘**，不是二选一。`TextScaler.linear(f)` 会把**所有** `fontSize`
  /// 等比放大 —— 包括 chrome 与 caption，且**不改变任何对比关系**
  /// （11/14 还是 11/14）。这正是"全局"，也不会出现"内容与 chrome 差一倍"。
  ///
  /// 整体再 `clamp(0.85, 2.0)`：下限防止系统把字缩到看不清；上限 2.0 是实测
  /// 还能用的那条线（系统 2.0 无溢出，只是挤；见
  /// `shots-2026-10-22/font-f-2.0-home.png`）。
  ///
  /// **只重建这一层**：`child` 当 `ListenableBuilder` 的 `child` 传进去（同一个实例），
  /// `AppModel` 的每次通知不会重建整棵树；字号真的变了才重建依赖它的文字。
  Widget _uiScaled(Widget child) {
    final app = _app;
    if (app == null) return child;
    return ListenableBuilder(
      listenable: app,
      child: child,
      builder: (context, child) {
        final platform = MediaQuery.textScalerOf(context);
        final combined = TextScaler.linear(
          platform.scale(1.0) * app.uiScale,
        ).clamp(minScaleFactor: 0.85, maxScaleFactor: 2.0);
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: combined),
          child: child!,
        );
      },
    );
  }

  /// 全局导航键。
  /// **为什么必须有它**：State 自己的 `context` 在 `MaterialApp` **之上**，
  /// 它的祖先里没有 Navigator / ScaffoldMessenger（那两个都由 MaterialApp 在
  /// **内部**创建）。所以拿 State 自带的 context 去调 `Navigator.of` 在真机上
  /// 必抛 `Navigator operation requested with a context that does not include
  /// a Navigator` —— 2026-10-16 真机实测：抽屉「归档」「设置」、抽屉连接行的
  /// sheet、「文件/自动化」的 toast、新建会话失败的提示，**全部一碰就抛**，
  /// 而 widget 测试里它们照过（测试宿主在 Navigator 之下）。所有跨屏导航与
  /// 提示统一走这个键，不再用 State 自带的 context。
  final navigatorKey = GlobalKey<NavigatorState>();

  /// sheet / SnackBar / 对话框的宿主要它：**必须在 Navigator 之下**。
  ///
  /// `navigatorKey.currentContext` 是 Navigator **自己**的 context（它的祖先里
  /// 没有 Navigator），`Navigator.of` 拿到它照抛（2026-10-16 真机实测第二轮：
  /// 连接 sheet 就是这么挂的）。overlay 的 context 是 Navigator 的子节点，
  /// `Navigator.of` / `ScaffoldMessenger.of` 都找得到 —— 这是用 GlobalKey 取
  /// "路由内 context"的标准做法。
  BuildContext get _navContext => navigatorKey.currentState!.overlay!.context;

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
        // 旧配对标识（重新配对同一台电脑时电脑侧据此替换旧行）。
        previousPairingIdOf: _previousPairingIdOf,
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
                : _connectionDetail(app.connection, app.activeEndpoint),
            platform: _credentials == null ? '' : 'DSH',
            online: app.connection == ConnectionStateView.serving,
          ),
          footItems: [
            // **文件**：工作区目录浏览 + 文本预览（`file.list` / `file.read`，
            // 契约 §5.7）。只做"看"—— 二进制由宿主拒，`readBytes` / `changes` 不接。
            DrawerFootItem(
              icon: 'folderClose',
              label: '文件',
              onTap: () => _openFiles(app),
            ),
            DrawerFootItem(
              icon: 'archive',
              label: '归档',
              onTap: () => unawaited(_openArchive()),
            ),
            // **用量**（2026-10-19 用户原话：「用量在侧滑窗口菜单单独页面啊，
            // 这不是显眼，因为这个挺常用的，你藏太深了」；次日又追一条
            // 「用量应该在设置前面吧？」）。
            //
            // 所以它是抽屉底栏的一枚、**排在设置之前**：常用功能不该埋在
            // 不常改的偏好后面。点开是独立一页（`ui/usage_page.dart`：
            // 总量 + 按项目 + 按会话）。
            DrawerFootItem(
              icon: 'gauge',
              label: '用量',
              onTap: () => _openUsage(app),
            ),
            // **插件**（清单 + 行级启停，契约 §5.7）。排在设置之前：它答的是
            // "这台电脑上装了什么"，比偏好更常被点开；安装 / 卸载 / 升级不在这里
            // （改的是 profile 的依赖与锁文件，手机上做不了）。
            DrawerFootItem(
              icon: 'cordisPlugin',
              label: '插件',
              onTap: () => _openPlugins(app),
            ),
            DrawerFootItem(
              icon: 'settings',
              label: '设置',
              onTap: () => _openSettings(app),
            ),
          ],
          onNewSession: _newSession,
          onOpenSession: (session) {
            _closeDrawer();
            unawaited(app.openSession(session.sid));
          },
          // 行动作（长按菜单）。`workspace.archive` 是 2026-10-16 接上的；
          // 置顶 / 重排是 2026-10-21 接的，三个都是 Web 侧栏已有的 Host 方法。
          onArchive: (session) => unawaited(_archiveFromDrawer(session)),
          onPin: (session) => unawaited(_pinFromDrawer(app, session, true)),
          onUnpin: (session) => unawaited(_pinFromDrawer(app, session, false)),
          onMove: (session, beforeSid) =>
              unawaited(_moveFromDrawer(app, session, beforeSid)),
          onMoveWorkspace: (workspaceId, beforeWorkspaceId) => unawaited(
            _moveWorkspaceFromDrawer(app, workspaceId, beforeWorkspaceId),
          ),
          // 点连接状态行 → 已配对时给"重新配对 / 断开"的选择，没配对上配对页。
          onClose: () {
            if (_credentials == null) {
              _closeDrawer();
              _openPairing();
              return;
            }
            unawaited(_showConnectionSheet());
          },
        ),
      ),
    );
  }

  /// 收起会话抽屉（没有被打开时是空操作）。
  ///
  /// **不用 `Navigator.maybePop()`**：它是 async，`await willPop()` 回来时如果栈顶
  /// 已经变了就整条放弃（`packages/flutter/lib/src/widgets/navigator.dart:5539,5547-5551`），
  /// 而"收抽屉 + 紧接 push"正是这个形状 —— 那句 `maybePop()` 因此静默失效，
  /// 从设置页返回时抽屉还开着。机制与完整时序见 `ChatPageState.closeDrawer`。
  void _closeDrawer() => _chatKey.currentState?.closeDrawer();

  /// 从抽屉里 push 一个全屏页（收抽屉 + 收输入法都在 `ChatPageState.openFromDrawer`）。
  void _openFromDrawer(WidgetBuilder builder) {
    final chat = _chatKey.currentState;
    if (chat == null) return;
    unawaited(chat.openFromDrawer(MaterialPageRoute<void>(builder: builder)));
  }

  /// 打开设置页（抽屉底栏「设置」）。
  ///
  /// **先收抽屉再 push**：全屏页盖着开着的抽屉会留下幽灵层（见 [_closeDrawer]）。
  /// 设置页有哪些行、哪些只读，见 `docs/subsystems/settings-and-versions.md`。
  void _openSettings(AppModel app) {
    // 输入法**不许**自己弹出来：从设置页 pop 回来时框架会把焦点还给输入栏
    // （`EditableText` 一拿回焦点就开输入连接）。开与关各收一次，见 `ui/input_focus.dart`。
    _openFromDrawer(
      (_) => SettingsPage(
        app: app,
        themeMode: _theme.mode,
        onThemeMode: setThemeMode,
      ),
    );
  }

  /// 打开用量页（抽屉底栏「用量」）。
  ///
  /// **先收抽屉再 push**，与 `_openSettings` / `_openArchive` 同一条：
  /// 全屏页盖着开着的抽屉会留下幽灵层。
  ///
  /// 进页面前先拉一次：汇总是"此刻的总量"，随时在变，**不落盘不缓存**
  /// （`AppModel.refreshUsageSummary`）。
  void _openUsage(AppModel app) {
    // **不要在这里先拉再传快照**：`UsagePage` 不监听 `AppModel`，
    // 传进去的那一份永远是"拉之前"的 null（真机上就是永远的「还没有用量数据」）。
    // 拉与重画都在 `UsagePageHost` 里（它 `initState` 拉、`ListenableBuilder` 重画）。
    _openFromDrawer(
      (_) => UsagePageHost(
        app: app,
        // 用量页是**一条路由**，这里的"收"就是真的 pop 掉它 —— 与收抽屉不同，
        // 它压在上面且紧接着没有 push，`maybePop()` 在这里没有栈顶竞态。
        onOpenSession: (sid) {
          unawaited(navigatorKey.currentState?.maybePop());
          unawaited(app.openSession(sid));
        },
      ),
    );
  }

  /// 打开文件页（抽屉底栏「文件」）。
  ///
  /// **先收抽屉再 push**（与 `_openUsage` / `_openPlugins` 同一条）。
  /// 目录由 `FilesPageHost` 自己拉，且它要一个**当前会话**（scope 按 sessionId 解析）。
  void _openFiles(AppModel app) {
    _openFromDrawer((_) => FilesPageHost(app: app));
  }

  /// 打开插件页（抽屉底栏「插件」）。
  ///
  /// **先收抽屉再 push**（与 `_openUsage` / `_openSettings` 同一条：全屏页盖着
  /// 开着的抽屉会留下幽灵层）。清单由 `PluginsPageHost` 自己拉 —— 与用量页同一条
  /// 纪律：页面不接"push 之前"的快照，否则永远停在空态。
  void _openPlugins(AppModel app) {
    _openFromDrawer((_) => PluginsPageHost(app: app));
  }

  /// 打开归档列表（抽屉底栏「归档」）。
  ///
  /// 先收抽屉再弹 sheet —— 与 `_showConnectionSheet` 同一条：sheet 盖开着抽屉
  /// 会留下一个幽灵层（原型里那条 `closeLayer("sheet", true)` 的教训），
  /// 手机上则表现为"关掉 sheet 后抽屉还开着"。
  Future<void> _openArchive() async {
    final app = _app;
    if (app == null) return;
    _closeDrawer();
    await showArchiveSheet(
      _navContext,
      app: app,
      onUnarchive: (sid) => app.unarchiveSession(sid),
    );
  }

  /// 归档一个会话（抽屉行左滑的动作）。
  ///
  /// **"还在跑"不是错误**：会话有在跑的轮次 / 子智能体 / 后台任务时，
  /// 宿主回 `workspace/session-active`（`workspace-controller/src/commands.ts:172-178`）——
  /// 那是信息，不是故障。照 Web 的同一条（`ui-workspace/src/client/index.ts:190-208`）：
  /// 弹「停止并归档」确认，用户点了才带 `stopActivity` 重发。
  Future<void> _archiveFromDrawer(DrawerSession session) async {
    final app = _app;
    if (app == null) return;
    if (await app.archiveSession(session.sid)) return;
    if (!mounted) return;
    if (app.lastError?.code != ErrorCode.workspaceSessionActive) return;
    if (!await confirmStopAndArchive(_navContext, title: session.title)) return;
    if (!mounted) return;
    await app.archiveSession(session.sid, stopActivity: true);
  }

  /// 置顶 / 取消置顶（长按菜单）。失败照实说，不吞。
  Future<void> _pinFromDrawer(
    AppModel app,
    DrawerSession session,
    bool pinned,
  ) async {
    final ok = pinned
        ? await app.pinSession(session.sid)
        : await app.unpinSession(session.sid);
    if (!ok && mounted) _showActionFailure(app);
  }

  /// 组内上移 / 下移 / 拖动落点。[beforeSid] 由抽屉按**显示顺序**算好：
  /// `null` 是末尾（Host 的追加语义）。
  Future<void> _moveFromDrawer(
    AppModel app,
    DrawerSession session,
    String? beforeSid,
  ) async {
    final ok = await app.moveSession(session.sid, beforeSid: beforeSid);
    if (!ok && mounted) _showActionFailure(app);
  }

  /// 工作区排序（拖动项目头）。[beforeWorkspaceId] 为 `null` = 移到末尾。
  Future<void> _moveWorkspaceFromDrawer(
    AppModel app,
    String workspaceId,
    String? beforeWorkspaceId,
  ) async {
    final ok = await app.moveWorkspace(
      workspaceId,
      beforeWorkspaceId: beforeWorkspaceId,
    );
    if (!ok && mounted) _showActionFailure(app);
  }

  /// 行动作失败的原因（`AppModel.lastError` 的 code + message）。
  void _showActionFailure(AppModel app) {
    final error = app.lastError;
    ScaffoldMessenger.of(_navContext).showSnackBar(
      SnackBar(
        content: Text(
          error == null ? '操作失败' : '操作失败：${error.code.wire}：${error.message}',
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
    _closeDrawer();
    final app = _app;
    if (app == null) return;
    await showConnectionActionsSheet(
      _navContext,
      // 「当前连接」块（连接方式选择器第 1 步）：走的哪条 + 为什么没走首选。
      // 与设置页顶部、聊天页顶栏入口同一块同一套说法（`connectionSummary`）。
      connection: connectionSummary(
        state: app.connection,
        active: app.activeEndpoint,
        endpoints: app.endpoints,
        attemptOf: app.attemptOf,
      ),
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
    ScaffoldMessenger.of(_navContext).showSnackBar(
      SnackBar(content: Text('连接失败：${error.code.wire}：${error.message}')),
    );
  }

  /// 新建会话：**先复用现有的 blank，没有才建**（照 DSH 的 `reuseOrCreateBlank`）。
  ///
  /// `ui-sidebar/src/client/contract/slots.ts:119-121` 原话：
  /// "with a workspace, reuse-or-create its blank session and open it;
  ///  without one, inherit the current Session Workspace, then the recent
  ///  Workspace, or clear into the New Session pure view when none exist."
  ///
  /// 我们原先直接 `session.create` —— 每点一次「新建会话」就在电脑侧多一个
  /// 会话（用户反悔不發消息也留着）。2026-10-19 用户问「你这个新会话的逻辑
  /// 是啥样的？和 web 的逻辑一样吗？」才发现这条差异。
  ///
  /// **没配对时不做假动作**：直接提示去配对 —— 而不是造一个本地空会话
  ///（那会在抽屉里留下一个永远发不出消息的条目）。
  void _newSession() {
    _closeDrawer();
    if (_credentials == null) {
      _openPairing();
      return;
    }
    final app = _app;
    if (app == null) return;
    unawaited(() async {
      // 目标工作区照 DSH 的链（显式没有 → 当前会话工作区 → 最近工作区，
      // 见 `AppModel.defaultNewSessionWorkspaceId`）：
      // **不带 `workspaceId` 建的会话不会进任何工作区的账本**，于是它在抽屉里
      // 永远落在「未分组」（2026-10-22 真机反馈）。
      final workspaceId = app.defaultNewSessionWorkspaceId;
      // ① 先复用**这个工作区里**现有的 blank（**不新建**）。
      final existing = await app.findBlankSession(workspaceId: workspaceId);
      if (existing != null) {
        await app.openSession(existing);
        return;
      }
      // ② 没有才建。建失败照实说，不吞。
      try {
        await app.createSession(workspaceId: workspaceId);
      } catch (error) {
        _notYet('新建会话（$error）');
      }
    }());
  }

  void _notYet(String what) {
    _closeDrawer();
    ScaffoldMessenger.of(
      _navContext,
    ).showSnackBar(SnackBar(content: Text('$what 还没做')));
  }

  /// 抽屉连接行的详情（换设备 / 断开重配）。
  ///
  /// **"走的哪条"从 `activeEndpoint` 来，不再写死"中转"**：局域网直连落地后
  /// （2026-10-16 无线验证）日常走的就是直连，写死的那句每一条连接都是错的。
  /// 说法与连接 sheet / 设置页同源（`endpointKindLabel`）。
  static String _connectionDetail(
    ConnectionStateView state,
    Endpoint? active,
  ) => switch (state) {
    ConnectionStateView.serving =>
      active == null ? '已连接 · 空闲' : '${endpointKindLabel(active.kind)}已连接 · 空闲',
    ConnectionStateView.backoff => '重连中…',
    ConnectionStateView.connecting => '连接中…',
    ConnectionStateView.handshaking => '握手中…',
    _ => '未连接',
  };

  /// 会话按**工作区**分组（Web 的侧栏就是 工作区 → 该项目下的会话）。
  ///
  /// 顺序照电脑侧给的顺序（`workspace.list` 的行序即偏好）；不属于任何工作区的
  /// 会话进「未分组」—— 那是如实的兜底，不是错误。拿不到工作区清单时
  /// （`app.workspaces` 为空）整份退回**不分组**，而不是按 `cwd` 猜。
  ///
  /// 2026-10-15 之前这里按"今天 / 昨天 / 更早"分 —— 项目一多就得在时间里翻会话，
  /// 而 Web 的结构是"先选项目再看它的会话"。
  List<DrawerSection> _drawerSections(AppModel app) {
    final now = DateTime.now();
    // **可见性规则逐条照 DSH Web**（`model/workspace.dart` 的 `sessionVisible`）:
    // 子智能体的子会话不列、从没跑过的 blank 除当前外不列。
    // 2026-10-15 真机对比:Web 的 anatomy-test 3 条,手机 4 条 —— 多的那条
    // 就是子智能体会话,而连接器一直在发 `subagent` 标志,是手机没用。
    final visible = app.sessions
        .where(
          (s) => sessionVisible(
            subagent: s.subagent,
            blank: s.blank,
            isCurrent: s.sid == app.currentSid,
            // 已归档的默认不列（照 Web 的默认过滤档）——
            // 它们在自己的「归档」列表里，取消归档就回原位。
            archived: app.archivedSids.contains(s.sid),
          ),
        )
        .toList();
    DrawerSession rowOf(SessionSummary s) => DrawerSession(
      sid: s.sid,
      title: s.displayTitle,
      // **待处理数进副标题**：多会话并行时，用户靠它知道该切去哪个会话
      // （DSH 的待处理是 per-session 的，切过去才看得见）。
      preview: [
        if (s.pendingCount > 0) '${s.pendingCount} 个待处理',
        if (s.itemCount > 0) '${s.itemCount} 条',
        if (s.pendingCount == 0 && s.itemCount == 0) s.sid,
      ].join(' · '),
      timeLabel: _relativeTime(
        DateTime(
          now.year,
          now.month,
          now.day,
        ).difference(DateTime.fromMillisecondsSinceEpoch(s.updatedAt)).inDays,
        DateTime.fromMillisecondsSinceEpoch(s.updatedAt),
      ),
      isActive: s.sid == app.currentSid,
      isPinned: app.pinnedSids.contains(s.sid),
      // 行首那枚点表达**状态**（照 DSH 的 `Rows.tsx:344-398`），"是不是当前"
      // 由底色说。三个输入都是既有事实：待处理计数、宿主运行态、未读收口。
      // `running` 取 `app.runningOf` 而不是行上的 `s.running` —— 前者的
      // 唯一真值是 `_runningSids`（`status` 帧 + 快照覆盖），后者只是快照。
      dot: sessionDotOf(
        pendingCount: s.pendingCount,
        running: app.runningOf(s.sid),
        completionUnread: app.completionUnreadOf(s.sid),
      ),
    );

    final bySid = {for (final s in app.sessions) s.sid: s};
    // **分组规则只有一份**（模型层的纯函数 `bucketSessionsByWorkspace`）——
    // 抽屉与内联列表都用它,免得两处各写一遍"谁进哪个桶"。
    return [
      for (final bucket in bucketSessionsByWorkspace(
        visible.map((s) => s.sid).toList(),
        app.workspaces,
        // 置顶的排在**各自分组**的最前（DSH 的 `sectionMembers`），
        // 不是把置顶项抽到整张表最上面。
        pinnedSessionIds: app.pinnedSids,
      ))
        DrawerSection(
          label: bucket.label,
          // 哪一组能重排由分桶函数给（`null` = 兜底桶，菜单里上移/下移不可点）。
          workspaceId: bucket.workspaceId,
          sessions: [
            for (final sid in bucket.sessionIds)
              if (bySid[sid] case final session?) rowOf(session),
          ],
        ),
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
    // 同"重新配对"：先抓旧配对标识，再清。之后扫同一台电脑的码是**替换**
    // 旧行，不是又攒一行。
    _refreshRePairHint();
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
      // 同 `_onPaired`：旧客户端持着传输层，换掉前必须 dispose，
      // 否则旧连接一直挂在电脑侧（重配对 / 断开后的"幽灵连接"）。
      _app?.dispose();
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

  // 端点表**可换**：`endpoint.describe` 的发现结果写回 `AppModel`，
  // 而 `EndpointTransport` 每次 `connect()` 现读它。发现**不踹掉正在用的
  // 连接**（那只影响下一次建连）。
  //
  // **不能直接捕获下面那个 `endpoints` 列表**：`AppModel` 每次改动都**换一个
  // 新 list**（`_endpoints = merged`），捕获的旧引用永远不变 —— 于是
  // "发现了一条直连"要等重启 App 才生效（`tools.md` 那句"重开 App 它就会
  // 改用直连"其实就是这个别名 bug 的症状，不是设计意图）。
  // 所以这里读 `appRef`（晚绑定），并套上 `dialOrder`：
  // **记住的那条先试 → 同网段的次之 → 其余按用户排的顺序**。
  AppModel? appRef;
  final transport = EndpointTransport(
    endpointsOf: () {
      final app = appRef;
      final table = app?.endpoints ?? credentials.endpoints;
      return dialOrder(
        table,
        myIpv4: app?.myLanIpv4,
        rememberedEndpointUrl: app?.rememberedEndpointUrl,
      );
    },
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
    // 通知与后台保活：端口在 `core/`、实现按端选（`platform/notify_factory.dart`）。
    notify: createNotifyPort(),
    // 端点表交给 `AppModel` 当所有者：界面要读、设置页要改，而上面的
    // `EndpointTransport` 每次 `connect()` 经 `appRef` 现读它。
    endpoints: credentials.endpoints,
    // 路由记忆（上次连哪条 / 藏了哪些 / 哪些成功过）—— 它们决定拨号顺序。
    rememberedEndpointUrl: credentials.endpointMeta.rememberedEndpointUrl,
    hiddenEndpointIds: credentials.endpointMeta.hiddenEndpointIds,
    succeededEndpointIds: credentials.endpointMeta.succeededEndpointIds,
    // 本机 LAN 地址（拨号排序判"同网段"用）。拿不到就退化，不猜。
    myLanIpv4Of: currentLanIpv4,
    // **点名连接**的两根线（设置页"用这个连接"用）：
    // ① 告诉传输层"下一次只试这一条"；② 立刻断开重拨。
    // 分开是因为传输层不认识连接层 —— 谁拨号、谁重拨，各管一段。
    onRequestEndpoint: transport.requestEndpoint,
    onReconnect: client.reconnect,
    onEndpointsChanged: PairingStore.saveEndpoints,
    onEndpointsMetaChanged: PairingStore.saveEndpointMeta,
    // 连接终态失败（身份不被认）→ 清凭据回配对页。见 `_recovery`。
    onConnectionTerminated: onConnectionTerminated,
  );
  appRef = app;
  // 起一次：第一轮拨号就有网段可比（否则第一轮只能按用户顺序）。
  unawaited(app.refreshMyLanIpv4());
  // 拨通了就报给界面：设置页据此显示"当前走哪条"。**只报事实** ——
  // 表的所有权在 `AppModel`，传输层不写它。
  transport.onActivated = app.reportActiveEndpoint;
  // 每个端点试过的结局也报给界面：设置页的"通不通"与"为什么走了中转"
  // （连接方式选择器第 3 步）都读它。同样只报事实。
  transport.onAttempt = app.reportEndpointAttempt;
  return app;
}
