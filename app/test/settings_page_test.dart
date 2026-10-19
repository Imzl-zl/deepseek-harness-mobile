/// 设置页「连接方式」（端点选择器）的 widget 回归。
///
/// ## 这一组守什么
///
/// 1. **顺序即偏好**：行序 = 端点表序，第一条带「首选」；点一条 = 置顶
///    （`AppModel.preferEndpoint`，只改序不删条目）并落盘；
/// 2. **状态全部来自真实拨号记录**：`当前连接` / `拨不通：原因` / `拨通过` /
///    `还没试过` 四档，没有记录就说"还没试过"—— 不猜；
/// 3. **「当前连接」只在服务态标**：拨通记录跨连接保留，重连中把上一条的
///    赢家标成"当前"会与顶栏/连接 sheet 的说法打架；
/// 4. 空端点表（没配对）给空态，**不摆假行**。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/endpoint.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_colors.dart';
import 'package:dsh_mobile/theme/dsh_icons.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/settings_page.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

class _FakeClient extends FakeSyncClient {
  _FakeClient({ConnectionState state = ConnectionState.serving})
    : _state = state;

  final ConnectionState _state;
  final _states = StreamController<ConnectionState>.broadcast();

  @override
  ConnectionState get state => _state;

  @override
  Stream<ConnectionState> get connection => _states.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> reconnect() => start();

  @override
  Future<void> setAppState(AppState state) async {}

  @override
  Future<void> close() async {}

  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();

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
    // **`usage.summary` 是设置页唯一会主动发的方法**（用量组进页面就拉一次）。
    // 其余方法一律视为越界 —— 设置页只读端点与偏好，不该碰会话。
    if (method == 'usage.summary') {
      if (throwOnUsage) {
        throw const ProtocolException(ErrorCode.internal, '电脑侧炸了');
      }
      return usageReply as T;
    }
    throw UnimplementedError('设置页不该发方法: $method');
  }

  /// `usage.summary` 的答复载荷。默认是**一个正常汇总**（两会话、一上榜）。
  Object? usageReply = <String, Object?>{
    'sessions': 2,
    'grandTotalTokens': 249000000,
    'bySession': <Object?>[
      <String, Object?>{
        'sid': 'sid-1',
        'title': '插件UI与交互体验优化',
        'tokens': 200000000,
      },
      <String, Object?>{'sid': 'sid-2', 'title': '', 'tokens': 49000000},
    ],
  };

  /// 为真时 `usage.summary` 抛协议错（测"拉不到"那条路）。
  bool throwOnUsage = false;
}

const _direct = Endpoint(
  kind: EndpointKind.direct,
  url: 'ws://192.168.2.43:8790',
  label: 'Wi-Fi',
);
const _relay = Endpoint(
  kind: EndpointKind.relay,
  url: 'ws://192.168.2.43:8787',
  label: '中转',
);

Widget _host(AppModel app) => MaterialApp(
  theme: DshTheme.dark(),
  home: SettingsPage(
    app: app,
    // 主题两参：测试里用默认（跟随系统）+ 空实现。
    // 它们不影响这一组断言的其它行（端点 / 模型 / 偏好）。
    themeMode: DshThemeMode.system,
    onThemeMode: (_) async {},
  ),
);

/// 滚到某个 widget 可见（ListView 懒加载 + 设置页有多组，端点卡在下面）。
///
/// **必须指定 `scrollable`**：端点卡现在自己也是 `ReorderableListView`
/// （`shrinkWrap` + 禁滚），页面上于是有不止一个 `Scrollable`；
/// 不指定时会抛 `Bad state: Too many elements`。外层那个才是真正要滚的。
Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

/// 某一行行尾的「⋯」（次要动作入口）。
///
/// 整行可点是**设为首选**；"现在用这条连"与"删除"走这个按钮。
/// 按行内文字先找到那一行，再取它里面的 IconButton，而不是 `.first`
/// （`.first` 永远命中第一条，而用例要的是"中转"那一行）。
Finder _moreOf(String rowText) => find
    .descendant(
      of: find.ancestor(of: find.text(rowText), matching: find.byType(Row)),
      matching: find.byTooltip('更多'),
    )
    .first;

void main() {
  // ---------------------------------------------------------------------------
  // 用量组（`usage.summary`，只读）
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // 用量不在设置页（2026-10-19 搬到侧滑抽屉底栏）
  // ---------------------------------------------------------------------------

  testWidgets('设置页不再摆用量入口（它搬到侧滑抽屉底栏了）', (tester) async {
    // 用户 2026-10-19 原话：「用量在侧滑窗口菜单单独页面啊，这不是显眼，
    // 因为这个挺常用的，你藏太深了」。所以它是**抽屉底栏的一枚**
    // （`main.dart` 的 `DrawerFootItem`），点开独立页（`ui/usage_page.dart`）；
    // 设置页只留不常改的偏好。
    //
    // 这一条守的是"别又长回来"：设置页出现「用量」就是放回深洞里了。
    final app = AppModel(
      client: _FakeClient(),
      endpoints: const [_direct, _relay],
    );
    addTearDown(app.dispose);
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    // **不滚动就断言**：用量若在，它会在「通用」组附近（设置页中部），
    // 而 ListView 懒加载 —— 滚过头反而把它回收了。先查当前位置没有。
    expect(find.text('用量'), findsNothing);
    expect(find.text('249M'), findsNothing);

    // 再滚到底，确认设置页该有的还在（端点组在最后）。
    // **只往下滚不滚回**：`scrollUntilVisible` 是单向的，往回滚要另写。
    await _scrollTo(tester, find.text('关于与连接'));
    await tester.pumpAndSettle();
    expect(find.text('关于与连接'), findsOneWidget);
  });

  AppModel buildApp({
    List<Endpoint> endpoints = const [_direct, _relay],
    void Function(List<Endpoint>)? onEndpointsChanged,
    ConnectionState state = ConnectionState.serving,
  }) {
    final app = AppModel(
      client: _FakeClient(state: state),
      endpoints: endpoints,
      onEndpointsChanged: onEndpointsChanged == null
          ? null
          : (list) async => onEndpointsChanged(list),
    );
    return app;
  }

  testWidgets('端点行按表序渲染：kind + 地址(+自报名) + 首选', (tester) async {
    final app = buildApp();
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    // 设置页比"只有连接方式"那版长了（通用/主题/模型/关于四组在它上面）——
    // 端点卡在屏外，先滚到可见（ListView 懒加载，不滚根本找不到）。
    await _scrollTo(tester, find.text('直连'));
    await tester.pumpAndSettle();

    expect(find.text('连接方式'), findsOneWidget);
    expect(find.text('直连'), findsOneWidget);
    expect(find.text('中转'), findsOneWidget);
    // 连接器自报的名字（网卡名）拼在地址后面，没有就不显示。
    expect(find.text('ws://192.168.2.43:8790 · Wi-Fi'), findsOneWidget);
    expect(find.text('ws://192.168.2.43:8787 · 中转'), findsOneWidget);
    expect(find.text('首选'), findsOneWidget, reason: '只有第一条带首选');
    addTearDown(app.dispose);
  });

  testWidgets('点非首实行 → 直接设为首选（置顶 + 落盘 + toast）', (tester) async {
    final persisted = <List<Endpoint>>[];
    final app = buildApp(onEndpointsChanged: persisted.add);
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    // 设置页比"只有连接方式"那版长了（通用/模型/关于三组在它上面）——
    // 端点卡可能出屏，先滚到可见再点（ListView 懒加载，不滚根本找不到）。
    await _scrollTo(tester, find.text('中转'));
    // **点行 = 设为首选**（不是"立刻连"，也不是开 sheet）：
    // 队列管的是顺序，立刻重连归顶部那块与顶栏状态点。
    await tester.tap(find.text('中转'));
    await tester.pumpAndSettle();

    expect(app.endpoints.map((e) => e.url).toList(), [
      _relay.url,
      _direct.url,
    ], reason: '只改顺序，两条都还在');
    expect(persisted, hasLength(1), reason: '改了要落盘，重启后还是这个偏好');
    expect(find.text('已设为首选，下次自动连接时优先'), findsOneWidget);
    addTearDown(app.dispose);
  });

  testWidgets('点首选行 → 不动 + 说清已经是首选', (tester) async {
    var persisted = 0;
    final app = buildApp(
      onEndpointsChanged: (_) {
        persisted++;
      },
    );
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('直连'));
    await tester.tap(find.text('直连'));
    await tester.pumpAndSettle();

    expect(app.endpoints.map((e) => e.url).toList(), [_direct.url, _relay.url]);
    expect(persisted, 0, reason: '没变化不落盘');
    expect(find.text('已经是首选'), findsOneWidget, reason: '说清为什么不动');
    addTearDown(app.dispose);
  });

  testWidgets('行尾「⋯」里有「现在用这条连」（立刻连，与首选分开）', (tester) async {
    final app = buildApp();
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('中转'));
    await tester.tap(_moreOf('中转'));
    await tester.pumpAndSettle();

    expect(find.text('现在用这条连'), findsOneWidget, reason: '立刻连的入口在这里');
    expect(find.text('会断开当前连接，只试这一条'), findsOneWidget, reason: '要提前说清副作用');
    expect(find.text('删除这个端点'), findsOneWidget);
    addTearDown(app.dispose);
  });

  testWidgets('拖动排序：从拖动柄把中转拖到最上，顺序真变并落盘', (tester) async {
    final persisted = <List<Endpoint>>[];
    final app = buildApp(
      endpoints: const [_direct, _relay],
      onEndpointsChanged: persisted.add,
    );
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('中转'));
    // 拖动柄是 `ReorderableDragStartListener` 包着的那个图标。
    final handle = find
        .descendant(
          of: find.byType(ReorderableDragStartListener),
          matching: find.byType(DshIcon),
        )
        .hitTestable();
    expect(handle, findsWidgets, reason: '每行左侧要有拖动柄');

    // 拖动**第二行**的柄（中转）往上越过第一行。
    final relayRow = find.ancestor(
      of: find.text('中转'),
      matching: find.byType(Padding),
    );
    expect(relayRow, findsWidgets);
    final source = tester.getCenter(handle.at(1));
    final gesture = await tester.startGesture(source);
    await tester.pump(const Duration(milliseconds: 120));
    // 分几步移动：一次跳到位的移动在 `ReorderableListView` 里可能被判成点击。
    for (var dy = 0; dy > -130; dy -= 26) {
      await gesture.moveBy(Offset(0, dy == 0 ? -26 : -26));
      await tester.pump(const Duration(milliseconds: 40));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(app.endpoints.map((e) => e.url).toList(), [
      _relay.url,
      _direct.url,
    ], reason: '拖到最上就是把那一条排到第一位（顺序即拨号优先级）');
    addTearDown(app.dispose);
  });

  testWidgets('状态四档：当前连接 / 拨不通(带原因) / 拨通过 / 还没试过', (tester) async {
    final app = buildApp(endpoints: const [_direct, _relay, _extra, _never]);
    await app.start(); // serving
    // 这一轮：直连拨不通 → 回落中转；extra 上一轮拨通过；never 从没试过。
    app.reportActiveEndpoint(_relay);
    app.reportEndpointAttempt(
      _direct,
      const EndpointAttempt(ok: false, reason: '连接超时'),
    );
    app.reportEndpointAttempt(_relay, const EndpointAttempt(ok: true));
    app.reportEndpointAttempt(_extra, const EndpointAttempt(ok: true));
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    // 端点卡在屏外（通用/主题/模型/关于四组在它上面），先滚到可见。
    await _scrollTo(tester, find.text('当前连接'));
    await tester.pumpAndSettle();

    expect(find.text('当前连接'), findsOneWidget);
    expect(find.text('拨不通：连接超时'), findsOneWidget);
    expect(find.text('拨通过'), findsOneWidget);
    expect(find.text('还没试过'), findsOneWidget);
    addTearDown(app.dispose);
  });

  testWidgets('回落时顶部块说清"为什么没走直连"', (tester) async {
    final app = buildApp();
    await app.start();
    app.reportActiveEndpoint(_relay);
    app.reportEndpointAttempt(
      _direct,
      const EndpointAttempt(ok: false, reason: '连接超时'),
    );
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    expect(find.text('当前连接：中转 · ws://192.168.2.43:8787'), findsOneWidget);
    expect(find.text('直连 ws://192.168.2.43:8790 拨不通（连接超时）'), findsOneWidget);
    addTearDown(app.dispose);
  });

  testWidgets('重连中：不把上一条的赢家标成"当前连接"', (tester) async {
    // 拨通记录跨连接保留，而连接 sheet/顶栏此时说的是"重连中…"——
    // 同一个事实只能有一套说法。
    final app = buildApp(state: ConnectionState.backoff);
    await app.start();
    app.reportActiveEndpoint(_relay);
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    expect(find.text('重连中…'), findsOneWidget);
    expect(find.text('当前连接'), findsNothing);
    addTearDown(app.dispose);
  });

  testWidgets('空端点表（没配对）：空态，不摆假行', (tester) async {
    final app = buildApp(endpoints: const []);
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    // 端点组在屏外（通用/主题/模型/关于四组在它上面），先滚到可见。
    await _scrollTo(tester, find.text('还没有端点。配对成功后，这里会列出可拨的地址。'));
    await tester.pumpAndSettle();

    expect(find.text('还没有端点。配对成功后，这里会列出可拨的地址。'), findsOneWidget);
    expect(find.text('直连'), findsNothing);
    addTearDown(app.dispose);
  });

  // ---------------------------------------------------------------------------
  // 管理：删除 / 手填 / 已隐藏
  // ---------------------------------------------------------------------------

  testWidgets('删自报端点：确认后从表里去掉并进隐藏集', (tester) async {
    final app = buildApp();
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('中转'));
    await tester.tap(_moreOf('中转'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除这个端点'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(
      app.endpoints.map((e) => e.url),
      isNot(contains(_relay.url)),
      reason: '删了就该从表里消失',
    );
    expect(
      app.hiddenEndpointIds,
      contains(_relay.url),
      reason: '自报的端点要靠隐藏集挡住，否则下次 describe 又加回来',
    );
    expect(find.text('已隐藏 1 条端点 · 点这里放回来'), findsOneWidget);
    addTearDown(app.dispose);
  });

  testWidgets('删除要确认：点"取消"不动表', (tester) async {
    final app = buildApp();
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('中转'));
    await tester.tap(_moreOf('中转'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除这个端点'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(app.endpoints.map((e) => e.url), contains(_relay.url));
    expect(app.hiddenEndpointIds, isEmpty);
    addTearDown(app.dispose);
  });

  testWidgets('手填地址：校验通过后进表并标"手填"', (tester) async {
    final app = buildApp();
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('添加端点'));
    await tester.tap(find.text('添加端点'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'ws://192.168.2.99:8790');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    final added = app.endpoints.where((e) => e.url == 'ws://192.168.2.99:8790');
    expect(added, hasLength(1));
    expect(added.single.manual, isTrue, reason: '手填的要标来源，剪枝才豁免它');
    expect(
      find.text('ws://192.168.2.99:8790 · 手填'),
      findsOneWidget,
      reason: '来源跟着地址走，不占第三列',
    );
    addTearDown(app.dispose);
  });

  testWidgets('手填校验：公网明文 ws:// 被拒且说明原因', (tester) async {
    final app = buildApp();
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('添加端点'));
    await tester.tap(find.text('添加端点'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'ws://example.com:8790');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(
      app.endpoints.where((e) => e.url.contains('example.com')),
      isEmpty,
      reason: '公网明文不许进表',
    );
    expect(find.textContaining('明文仅限'), findsOneWidget, reason: '要说出为什么');
    addTearDown(app.dispose);
  });

  testWidgets('已隐藏区：点一下放回来', (tester) async {
    final app = buildApp();
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    await app.removeEndpoint(_relay);
    await tester.pumpAndSettle();
    // 设置页是懒加载 ListView：这一行在连接方式组下面，先滚到可见。
    await _scrollTo(tester, find.text('已隐藏 1 条端点 · 点这里放回来'));
    expect(find.text('已隐藏 1 条端点 · 点这里放回来'), findsOneWidget);

    await tester.tap(find.text('已隐藏 1 条端点 · 点这里放回来'));
    await tester.pumpAndSettle();
    expect(find.text('已隐藏的端点（1）'), findsOneWidget, reason: '先确认 sheet 真的开了');
    // 点标签而不是那行很长的地址：地址被 ellipsis 截断后，
    // `tester.tap` 取其几何中心可能落在文字外（那一拍就变成点遮罩，
    // sheet 以 null 收场 → 看起来像"点了没反应"）。
    await tester.tap(find.text('点一下放回来'));
    await tester.pumpAndSettle();

    expect(app.hiddenEndpointIds, isEmpty);
    addTearDown(app.dispose);
  });
}

const _extra = Endpoint(
  kind: EndpointKind.direct,
  url: 'ws://192.168.2.44:8790',
  label: '以太网',
);

const _never = Endpoint(
  kind: EndpointKind.relay,
  url: 'wss://relay.example',
  label: '备用中转',
);
