/// 按电脑池化（`lib/data/host_sessions.dart`）：切走不拆、移除才拆。
///
/// ## 这一组守什么
///
/// S4 之前"切电脑"= 换槽 + 重新装配 + `dispose` 旧的。于是切回 A 时 A 从零开始：
/// 重新拨号、重新握手、重新订阅、信息流重刷 —— 而 A 一直是好的，用户只是看了一眼 B。
/// 三条判据：
///
/// 1. **切 A→B→A：A 不重启**（`start()` 只调过一次、连接没被关掉）；
/// 2. **移除 B 只拆 B**（A 的 socket / 订阅 / 通知都不受影响）；
/// 3. 重新配对 = **换掉这一台**（旧模型带的是旧 token，不能复用）。
///
/// 通知 id 的电脑前缀（同一 `sid` 两台的 id 不同）在 `notice_test.dart` 里，
/// 它是通知的判据，不是池子的。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/host_sessions.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 一台电脑的替身：只记"起来过几次""被关过几次"。
///
/// 其余成员一律 `UnimplementedError`：本组不该碰会话（没有事件流、不发请求）。
class _ProbeClient extends FakeSyncClient {
  _ProbeClient();

  int startCount = 0;
  int closeCount = 0;

  @override
  conn.ConnectionState get state => conn.ConnectionState.idle;

  @override
  Stream<conn.ConnectionState> get connection => const Stream.empty();

  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();

  @override
  Future<void> start() async {
    startCount += 1;
  }

  @override
  Future<void> close() async {
    // 同步先记一笔：`AppModel.dispose()` 里是 `unawaited(client.close())`。
    closeCount += 1;
  }
}

/// 让 `dispose` 里那些 `unawaited` 的收尾跑完。
Future<void> pump() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('切 A→B→A：A 不重启、不关连接', () async {
    final sessions = HostSessions();
    final clientA = _ProbeClient();
    final clientB = _ProbeClient();

    final a = await sessions.acquire(
      'hostA',
      build: () async => AppModel(client: clientA),
    );
    expect(a.created, isTrue, reason: '第一次要装配');
    await a.app.start();

    final b = await sessions.acquire(
      'hostB',
      build: () async => AppModel(client: clientB),
    );
    expect(b.created, isTrue);
    await b.app.start();

    // 切回 A：池子里有，就不该再装配、再 start。
    final back = await sessions.acquire(
      'hostA',
      build: () async => throw StateError('切回已有的那台不该重新装配'),
    );
    expect(back.created, isFalse, reason: '切回去只是换可见指针');
    expect(identical(back.app, a.app), isTrue, reason: '还是原来那一份');

    // "A 的 client.state 不被重置"的具体形状：没有第二次 start（不重新拨号/握手），
    // 也没有 close（socket 与订阅都还在）。
    expect(clientA.startCount, 1, reason: '一次装配一次 start');
    expect(clientA.closeCount, 0, reason: '切走不拆旧的');
    expect(clientB.startCount, 1);
    expect(sessions.hostIds.toSet(), <String>{'hostA', 'hostB'});

    sessions.disposeAll();
    await pump();
  });

  test('移除 B 只拆 B：A 的模型、连接与 start 次数都不受影响', () async {
    final sessions = HostSessions();
    final clientA = _ProbeClient();
    final clientB = _ProbeClient();
    final a = await sessions.acquire(
      'hostA',
      build: () async => AppModel(client: clientA),
    );
    final b = await sessions.acquire(
      'hostB',
      build: () async => AppModel(client: clientB),
    );
    await a.app.start();
    await b.app.start();

    // 解绑 / 吊销 / 删除走这条。
    sessions.forget('hostB');
    await pump();

    expect(clientB.closeCount, 1, reason: '移除这一台要真的断开它的传输层');
    expect(clientA.closeCount, 0, reason: '别的电脑不受影响');
    expect(clientA.startCount, 1);
    expect(sessions.has('hostB'), isFalse);
    expect(identical(sessions.of('hostA'), a.app), isTrue);
    expect(b.app, isNotNull); // 引用还在，但它已经被释放（下面再 dispose 是幂等空操作）

    sessions.forget('hostB'); // 重复移除不抛
    sessions.disposeAll();
    await pump();
  });

  test('重新配对换掉这一台：旧的 dispose，新的顶替同一个 hostId', () async {
    final sessions = HostSessions();
    final oldClient = _ProbeClient();
    final newClient = _ProbeClient();
    final before = await sessions.acquire(
      'hostA',
      build: () async => AppModel(client: oldClient),
    );
    await before.app.start();

    final after = await sessions.replace(
      'hostA',
      build: () async => AppModel(client: newClient),
    );
    await pump();

    expect(oldClient.closeCount, 1, reason: '旧模型带的是旧 token，必须换掉');
    expect(identical(after, before.app), isFalse);
    expect(identical(sessions.of('hostA'), after), isTrue);
    expect(sessions.hostIds.toList(), <String>['hostA'], reason: '同一台不占两格');

    sessions.disposeAll();
    await pump();
  });
}
