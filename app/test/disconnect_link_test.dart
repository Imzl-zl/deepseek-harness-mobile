/// 「断开连接」= 只断链、不碰凭据；并且**不自动连回来**。
///
/// 守三件事：
/// 1. 用户按断开 → 客户端收到 `disconnect()`，凭据层一行都没被调（不配对、不清库）。
/// 2. 断开后 `start()`（启动 / 回前台 / 退避到点）不再自动重连。
/// 3. 「重新连接」是唯一的恢复动作：它清掉意图并真的拨一次。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

class _LinkClient extends FakeSyncClient implements LinkControl {
  int disconnects = 0;
  int reconnects = 0;
  int starts = 0;

  /// 模拟"用户断开后仍会被自动拉起"的路径：`start()` 真的被调到了就记下来。
  bool userDisconnected = false;

  @override
  ConnectionState get state =>
      userDisconnected ? ConnectionState.closed : ConnectionState.serving;

  @override
  Stream<ConnectionState> get connection => const Stream.empty();

  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();

  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();

  @override
  Future<void> start() async {
    if (userDisconnected) {
      starts += 1;
      return;
    }
  }

  @override
  Future<void> reconnect() async {
    userDisconnected = false;
    reconnects += 1;
  }

  /// 替身自己实现 [LinkControl]，同一个形状（`implements` 而非继承默认实现）。
  @override
  Future<void> disconnect() async {
    userDisconnected = true;
    disconnects += 1;
  }

  @override
  Future<void> setAppState(AppState state) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> unsubscribe(String sid) async {}
}

void main() {
  test('断开：调客户端 disconnect、置意图位，且不碰凭据', () async {
    final client = _LinkClient();
    var credentialsCleared = 0;
    const pairingsOpened = 0;
    final app = AppModel(
      client: client,
      onEndpointsChanged: (_) async {
        credentialsCleared += 1;
      },
    );
    addTearDown(app.dispose);

    expect(app.userDisconnected, isFalse);
    await app.disconnectLink();

    expect(client.disconnects, 1, reason: '连接层要真的断');
    expect(app.userDisconnected, isTrue, reason: '界面据此说"已按你的要求断开"');
    expect(credentialsCleared, 0, reason: '**不动凭据**：清凭据是「重新配对」的事');
    expect(pairingsOpened, 0);
  });

  test('断开后自动 start 不会把它连回来', () async {
    final client = _LinkClient();
    final app = AppModel(client: client);
    addTearDown(app.dispose);

    await app.disconnectLink();
    await client.start(); // 启动 / 回前台 / 退避到点都走这条

    expect(client.userDisconnected, isTrue, reason: '用户要离线，自动路径一律不动');
  });

  test('「重新连接」是唯一恢复动作：清意图 + 真的拨一次', () async {
    final client = _LinkClient();
    final app = AppModel(client: client);
    addTearDown(app.dispose);

    await app.disconnectLink();
    await app.reconnectLink();

    expect(app.userDisconnected, isFalse);
    expect(client.reconnects, 1);
  });
}
