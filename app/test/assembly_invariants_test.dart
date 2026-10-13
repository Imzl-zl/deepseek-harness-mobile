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

  test('PairingClient 与 PairingPage 用同一个明文放行判据', () {
    // **这条守的是一个真 bug**（2026-10-13 真机实测）：`PairingPage` 放了明文，
    // 于是配对成功；而装配里的 `PairingClient` 没放，于是**换不到票** ——
    // 症状正是文档里那句"码认了、票换不了"，而两端日志都看不出原因。
    //
    // 两处必须是同一个判据（`kDebugMode`）：放行的范围是"debug 构建的本机回环"，
    // 不是"某个调用点忘了"。
    final client = _callTextOf(source, 'PairingClient(');
    expect(client, isNotNull, reason: '装配点应有 PairingClient(...) 调用');
    expect(
      client!.contains('allowInsecureLocal: kDebugMode'),
      isTrue,
      reason: '换票也必须放行本机明文；只放 PairingPage 会出现"配对成功但永远换不到票"',
    );
    // 反向也钉：别把放行写成无条件 true（那会让 release 也走明文）。
    expect(
      client.contains('allowInsecureLocal: true'),
      isFalse,
      reason: 'release 构建不允许明文（契约 §2：手机侧恒为 wss）',
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
