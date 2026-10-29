/// 装配点的不变量（`lib/main.dart` 的 `_assemble`）。
///
/// ## 为什么这个文件存在
///
/// 装配点是最容易"看起来对但实际不通"的地方 —— 它只把零件接起来，而接错了
/// **不会报错**：类型都对，编译也过，运行时只是某个功能静默不工作。
/// 实测踩到两次，都在这一层：
///
/// 1. `outbox` 传了 `send: (_) async => false` → 队列里每一条**永远发不出去**，
///    症状只是"订阅了但收不到数据"（`offline` 是合法返回值，所以没有异常）；
/// 2. `persistence` 不给 → `persisted` 发的是"我处理完了"而不是"它在盘上了"，
///    而电脑据此裁掉缓冲 ⇒ 重启后那段数据**永久丢失**。
///
/// 两者都是"水位/队列在说谎"，且都没有可见症状。所以这里用一条**结构断言**
/// 钉住"生产的装配必须满足什么"。
///
/// ## 为什么不能直接调 `_assemble`
///
/// 它是私有的、且要起真 sqflite 与真 socket。所以这里断言的是**它的形状**：
/// 从 `main.dart` 的源码里确认那几个关键参数没有退回假实现。
/// 这是静态检查，但它守的正是"装配点接错"这一类。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 取出 `source` 里第一次 `marker` 那次调用的**完整文本**（含配对括号内的内容）。
///
/// 用配对括号而不是正则：装配点的调用跨多行，而正则里的 `.` 不匹配换行 ——
/// 第一版就是因为这一点而空转（变异校验时才发现）。
String? _callTextOf(String source, String marker) {
  final start = source.indexOf(marker);
  if (start < 0) return null;
  // 从 marker 的 `(` 开始数括号深度（跳过字符串里的括号，够用且简单）。
  var depth = 0;
  var inString = false;
  String? quote;
  for (var i = start + marker.length - 1; i < source.length; i += 1) {
    final ch = source[i];
    if (inString) {
      if (ch == r'\') {
        i += 1; // 跳过转义
      } else if (ch == quote) {
        inString = false;
        quote = null;
      }
      continue;
    }
    if (ch == "'" || ch == '"') {
      inString = true;
      quote = ch;
      continue;
    }
    if (ch == '(') depth += 1;
    if (ch == ')') {
      depth -= 1;
      if (depth == 0) return source.substring(start, i + 1);
    }
  }
  return null;
}

void main() {
  late String source;

  setUpAll(() {
    source = File('lib/main.dart').readAsStringSync();
  });

  test('outbox 不传假出帧口（构造时传假的 = 队列永远发不出去）', () {
    // `Outbox(store: …, send: (_) async => false)` 是踩过的写法。
    //
    // **这条第一版是空转的**：写成 `RegExp(r'Outbox\(\s*store:[^)]*send:')`
    // 而 `.` 不匹配换行（装配点那个调用跨了三行），于是变异校验时它照样通过。
    // 而这一处正是本文件存在的理由（装配点接错不报错），所以它必须真的有效。
    // 现在按**配对括号**取出那次调用、再看里面有没有 `send:`。
    final call = _callTextOf(source, 'Outbox(');
    expect(call, isNotNull, reason: '装配点应有 Outbox(...) 调用');
    expect(
      call!.contains('send:'),
      isFalse,
      reason:
          '出帧口必须由 SyncClient 自己装（Outbox.attachSender），'
          '在装配点传一个假的会让队列永远发不出去且没有报错',
    );
  });

  test('用真 sqflite 库，不是内存实现', () {
    // 内存实现会让 `persisted` 变成谎话（水位超前于内容 = 数据永久丢失）。
    expect(source.contains('SqfliteItemStore'), isTrue);
    expect(
      RegExp(r'persistence:\s*InMemory').hasMatch(source),
      isFalse,
      reason: '生产装配必须是真落盘',
    );
    expect(
      source.contains('InMemoryItemStore'),
      isFalse,
      reason: '内存实现只该出现在测试里',
    );
    expect(
      source.contains('InMemoryOutboxStore'),
      isFalse,
      reason: '发件箱也要真落盘（否则重启丢写操作）',
    );
  });

  test('persistence 装上了（不给 = persisted 是谎话）', () {
    expect(
      source.contains('persistence:'),
      isTrue,
      reason: '不装落盘缝时 persisted 发的是"我处理完了"，而契约要的是"它在盘上了"',
    );
    expect(source.contains('StoreItemPersister'), isTrue);
  });

  test('开库发生在装配 client 之前（否则第一帧事件无处可落）', () {
    // 顺序反了的话，`persistence` 拿到的 store 还没 open，
    // 而 `commit` 会抛 `StateError`（如实报错，但那时第一条事件已经丢了）。
    final openIndex = source.indexOf('await store.open()');
    final clientIndex = source.indexOf('createSyncClient');
    expect(openIndex, greaterThan(-1), reason: '要开库');
    expect(clientIndex, greaterThan(-1), reason: '要建客户端');
    expect(
      openIndex,
      lessThan(clientIndex),
      reason: '开库必须在建客户端之前 —— 否则第一条事件落不下去',
    );
  });

  test('落盘缝与发件箱用**同一个库**（三端同源的 schema 只有一套）', () {
    expect(source.contains('SqfliteOutboxStore(store)'), isTrue);
    expect(source.contains('StoreItemPersister(store)'), isTrue);
  });

  test('PairingClient 与 PairingPage 用同一个明文放行判据（两档）', () {
    // **这条守的是一个真 bug**（2026-10-13 真机实测）：`PairingPage` 放了明文，
    // 于是配对成功；而装配里的 `PairingClient` 没放，于是**换不到票** ——
    // 症状正是文档里那句"码认了、票换不了"，而两端日志都看不出原因。
    //
    // 2026-10-29 起明文分两档（`core/endpoint.dart`）：
    // ① 非公网（局域网/回环/组网）**常开**；② 公网**只认用户确认**。
    final client = _callTextOf(source, 'PairingClient(');
    expect(client, isNotNull, reason: '装配点应有 PairingClient(...) 调用');
    expect(
      client!.contains('allowInsecureLocal: true'),
      isTrue,
      reason: '非公网明文换票也要放行；只放 PairingPage 会出现"配对成功但永远换不到票"',
    );
    expect(
      client.contains('allowInsecurePublic: allowPlaintextPublicOf()'),
      isTrue,
      reason: '公网明文必须按用户确认（`net.allow_plaintext_public`），不是常量',
    );
    // 反向钉两条：明文不再由构建类型决定（release 也要能局域网直连），
    // 也不能把公网那一档写成无条件 true。
    expect(client.contains('kDebugMode'), isFalse, reason: '明文放行不再跟着构建类型走');
    expect(
      client.contains('allowInsecurePublic: true'),
      isFalse,
      reason: '公网明文不能无条件放行',
    );

    // 配对页与换票同源：两档都接上（配对页的确认卡就是公网那一档的同意书）。
    final page = _callTextOf(source, 'PairingPage(');
    expect(page, isNotNull, reason: '装配点应有 PairingPage(...) 调用');
    expect(page!.contains('allowInsecureLocal: true'), isTrue);
    expect(
      page.contains('allowInsecurePublic: true'),
      isTrue,
      reason: '配对页把"明文、元数据可见"摆在确认卡上，点确认即同意',
    );
  });

  test('端点拨号结果与当前端点都接上了（漏接 = 设置页状态永远"还没试过"）', () {
    // 连接方式选择器的两条线，漏接**都不报错**：
    // - `onAttempt`：传输层每试一个端点报一次结局。漏了它，
    //   `AppModel.attemptOf` 恒为 null，设置页四档状态永远停在"还没试过"，
    //   而真实拨号每一轮都在发生（症状是"直连明明拨不通却不显示"）。
    // - `onActivated`：当前走哪条。漏了它，连接 sheet 与设置页顶部
    //   没有"当前连接"可显示（`connectionSummary` 只能给状态名）。
    expect(
      source.contains('transport.onAttempt = app.reportEndpointAttempt'),
      isTrue,
      reason: '拨号结果是"通不通"与"为什么走了中转"的唯一数据来源',
    );
    expect(
      source.contains('transport.onActivated = app.reportActiveEndpoint'),
      isTrue,
      reason: '"当前走哪条"走同一根线；漏了连接 sheet 只剩状态名',
    );
  });

  test('配对页接了旧配对标识（漏接 = 重新配对又攒一行，且没有任何报错）', () {
    // 2026-10-17：`previousPairingIdOf` 是"同一台手机重扫**替换**旧行"的钩子。
    // 漏接它不报错、编译也过 —— 只是电脑侧每次重配多一行，而用户已经为
    // "我一个手机怎么显示五个"吵过一次。取舍与威胁模型见
    // `.agents/notes/implemented/2026-10-17-repair-replaces-device-row.md`。
    expect(
      source.contains('previousPairingIdOf: _previousPairingIdOf'),
      isTrue,
      reason: '装配点必须把旧配对标识接进配对页，否则替换退化成新增',
    );
    // 清凭据的缝必须先抓快照再清。直接传静态方法（`clearCredentials:
    // PairingStore.clear`）就抓不到 —— 顺序反了快照永远是 null。
    expect(
      source.contains('clearCredentials: PairingStore.clear'),
      isFalse,
      reason: '清凭据之前必须先抓旧配对标识快照，直接传静态方法抓不到',
    );
  });

  test('跨屏导航走 navigatorKey，不用 State 自带的 context', () {
    // **这条守的是一个真 bug**（2026-10-16 真机实测，拿一次装配换来的）：
    // State 的 context 在 MaterialApp **之上**，祖先里没有 Navigator ——
    // 于是抽屉「归档」「设置」、抽屉连接行的 sheet、「文件/自动化」的 toast、
    // 新建会话失败的提示，在真机上**全部一碰就抛**
    // `Navigator operation requested with a context that does not include a
    // Navigator`，而 widget 测试全绿（测试宿主挂在 Navigator 之下）。
    // 判据是机械的：这两个调用形状在 main.dart 里一次都不许出现
    // （注释里也不许提字面形状，免得断言被自己的注释骗过去）。
    expect(
      source.contains('Navigator.of(context)'),
      isFalse,
      reason: 'State 的 context 找不到 Navigator（真机实测全抛），必须走 navigatorKey',
    );
    expect(
      source.contains('ScaffoldMessenger.of(context)'),
      isFalse,
      reason: 'ScaffoldMessenger 同样由 MaterialApp 在内部创建，State 的 context 找不到它',
    );
    // 正向也钉：MaterialApp 真的挂了这把钥匙。
    final app = _callTextOf(source, 'MaterialApp(');
    expect(app, isNotNull, reason: '装配点应有 MaterialApp(...) 调用');
    expect(
      app!.contains('navigatorKey: navigatorKey'),
      isTrue,
      reason: '不挂钥匙 = 上面的替代方案全部落空',
    );
  });

  test('根 State 挂着前后台态上报者（否则 setAppState 永远不被调用）', () {
    // **这条守的是一个真缺口**（2026-10-13 定位）：`setAppState` 在 `app/lib` 里
    // 没有任何产品调用点，客户端从构造起就以为自己在**前台** —— 心跳照走、
    // `sync.hello` 恒报 foreground，电脑侧 `foreground` 档于是把审批继续推给一部
    // 已经退到后台的手机（契约 §6.3.1 的"退到后台自动 delegate"是断的），
    // 而后台长连接也违反 §2.2 / §13。
    // 装配点少接一根线**不报错**，所以这里断言形状。映射与派发由
    // `app_state_reporter_test.dart` 行为用例钉，本文只守"挂了没有"。
    expect(
      source.contains('AppStateReporter'),
      isTrue,
      reason: '装配点要创建上报者（platform/app_state_reporter.dart）',
    );
    expect(
      source.contains('WidgetsBinding.instance.addObserver(_reporter)'),
      isTrue,
      reason: '不注册 = observer 永远收不到态变化，与没有它一样',
    );
    expect(
      source.contains('WidgetsBinding.instance.removeObserver(_reporter)'),
      isTrue,
      reason: 'dispose 不摘 = 往一个已经 close 的客户端上继续写',
    );
    // 客户端必须**现取**：`_app` 会被换掉（重新配对 / 清凭据都重建 AppModel），
    // 持有一个就会在换掉之后往旧的（已 close 的）上报 —— 无声的空转。
    final reporter = _callTextOf(source, 'AppStateReporter(');
    expect(reporter, isNotNull, reason: '装配点应有 AppStateReporter(...) 调用');
    expect(
      reporter!.contains('_app?.client'),
      isTrue,
      reason: '上报目标要现取当前那个客户端，不能持有一个不放',
    );
  });
}
