/// 连上之后落到哪个会话（`AppModel.landingSessionOf` + 进服务态那一步）。
///
/// ## 为什么只能做到这一步
///
/// 桌面"当前打开哪个会话"是**浏览器本地 UI 状态**（`ctx.uiWorkspace.openSession`），
/// 宿主没有这个字段 —— 手机拿不到。拿得到的只有 `session.list` 的 `updatedAt`
/// 与 `running`，所以落点规则只能是"上次看的 → 在跑的 → 最新的 → 空白"。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/projection.dart';
import 'package:dsh_mobile/data/store.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 假电脑：先给一套会话行，`subscribe` 记录发起过哪些。
class _LandingClient extends FakeSyncClient {
  _LandingClient(this.rows);

  final List<Map<String, Object?>> rows;
  final subscribed = <String>[];
  final _state = StreamController<ConnectionState>.broadcast();

  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => _state.stream;
  void emit(ConnectionState state) => _state.add(state);
  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> reconnect() => start();
  @override
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> unsubscribe(String sid) async {}

  @override
  Future<SessionAnchor> subscribe(String sid, {required int since}) async {
    subscribed.add(sid);
    return const SessionAnchor(since: 0, hasMore: false);
  }

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'repo.info') {
      return <String, Object?>{'protocol': 1, 'caps': <String, Object?>{}} as T;
    }
    if (method == 'session.list') {
      return <String, Object?>{'sessions': rows} as T;
    }
    return <String, Object?>{} as T;
  }
}

/// 内存偏好（`PreferenceStore` 的假实现）。
class _MemoryPrefs implements PreferenceStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

Map<String, Object?> _wireRow(
  String sid, {
  required int updatedAt,
  bool running = false,
  bool subagent = false,
}) => {
  'sid': sid,
  'updatedAt': updatedAt,
  'running': running,
  'blank': false,
  'subagent': subagent,
};

void main() {
  group('落点规则（纯函数）', () {
    /// 用一次真的 `session.list` 把行喂进模型（走线上解码，不另造测试钩子）。
    Future<AppModel> modelWith(List<Map<String, Object?>> rows) async {
      final app = AppModel(client: _LandingClient(rows));
      addTearDown(app.dispose);
      await app.refreshSessions();
      return app;
    }

    test('在跑的优先于"更新的空闲会话"', () async {
      final app = await modelWith([
        _wireRow('idle-new', updatedAt: 900),
        _wireRow('running-old', updatedAt: 100, running: true),
      ]);
      expect(app.landingSessionOf()?.sid, 'running-old');
    });

    test('都在跑 / 都没跑 → 取 updatedAt 最大的', () async {
      final app = await modelWith([
        _wireRow('a', updatedAt: 100, running: true),
        _wireRow('b', updatedAt: 300, running: true),
        _wireRow('c', updatedAt: 200),
      ]);
      expect(app.landingSessionOf()?.sid, 'b');
    });

    test('记得的那个还在 → 优先它，哪怕它更旧且没在跑', () async {
      final app = await modelWith([
        _wireRow('remembered', updatedAt: 10),
        _wireRow('running-now', updatedAt: 900, running: true),
      ]);
      expect(app.landingSessionOf(remembered: 'remembered')?.sid, 'remembered');
    });

    test('记得的那个已经不在了 → 走正常规则', () async {
      final app = await modelWith([
        _wireRow('running-now', updatedAt: 50, running: true),
        _wireRow('idle-new', updatedAt: 900),
      ]);
      expect(app.landingSessionOf(remembered: 'gone')?.sid, 'running-now');
    });

    test('子会话不参与落点；只有子会话时给 null（不发明会话）', () async {
      final app = await modelWith([
        _wireRow('child', updatedAt: 999, subagent: true),
      ]);
      expect(app.landingSessionOf(), isNull);
    });
  });

  group('进服务态那一步', () {
    testWidgets('连上后自动打开在跑的会话，并画出运行条（"电脑那边在跑"）', (tester) async {
      final client = _LandingClient([
        _wireRow('idle-new', updatedAt: 900),
        _wireRow('running-now', updatedAt: 100, running: true),
      ]);
      final app = AppModel(client: client, prefs: _MemoryPrefs());
      addTearDown(app.dispose);
      await app.start();
      // 给"在跑"的那个会话一条条目：空会话走的是 hero 屏，不画运行条。
      app.seedForTest(
        sid: 'running-now',
        title: '跑着的',
        updatedAt: 100,
        items: [
          projectEvent(
            type: 'assistant/message',
            seq: 2,
            turn: 1,
            data: <String, Object?>{
              'turn': 1,
              'step': 1,
              'message': <String, Object?>{
                'role': 'assistant',
                'content': [
                  {'type': 'text', 'text': '在跑的一轮'},
                ],
                'source': {'kind': 'model'},
                'id': 'm1',
              },
            },
          ).item!,
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: ChatPage(
            app: app,
            paired: true,
            onOpenDrawer: () {},
            onNewSession: () {},
            drawer: const Drawer(child: SizedBox(height: 200)),
          ),
        ),
      );
      client.emit(ConnectionState.serving);
      // **不能 pumpAndSettle**：运行条的转圈是 `repeat()` 的无限动画，
      // settle 永远到不了。按帧推进到"列表回来 + 落点完成 + 运行条挂上"。
      for (var i = 0; i < 8; i += 1) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(app.currentSid, 'running-now', reason: '在跑的会话应当被自动打开');
      expect(client.subscribed, contains('running-now'));
      expect(
        find.byType(RunningBar),
        findsOneWidget,
        reason: '在跑就该显示运行条，而不是让人以为没动静',
      );
    });

    testWidgets('记得的会话还在：回到它，不跳到在跑的别的会话', (tester) async {
      final prefs = _MemoryPrefs()
        ..values[AppModel.kLastSessionKey] = 'remembered';
      final client = _LandingClient([
        _wireRow('remembered', updatedAt: 10),
        _wireRow('running-now', updatedAt: 900, running: true),
      ]);
      final app = AppModel(client: client, prefs: prefs);
      addTearDown(app.dispose);
      await app.start();
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: ChatPage(
            app: app,
            paired: true,
            onOpenDrawer: () {},
            onNewSession: () {},
            drawer: const Drawer(child: SizedBox(height: 200)),
          ),
        ),
      );
      client.emit(ConnectionState.serving);
      await tester.pumpAndSettle();

      expect(app.currentSid, 'remembered');
      // 打开过就落盘：下次还是它。
      expect(prefs.values[AppModel.kLastSessionKey], 'remembered');
    });

    test('列表为空：不打开任何会话（currentSid 仍是 null）', () async {
      final client = _LandingClient(const []);
      final app = AppModel(client: client, prefs: _MemoryPrefs());
      addTearDown(app.dispose);
      await app.start();
      client.emit(ConnectionState.serving);
      await Future<void>.delayed(Duration.zero);
      expect(app.currentSid, isNull);
    });
  });
}
