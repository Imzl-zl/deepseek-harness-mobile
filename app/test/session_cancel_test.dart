/// 打断这条链的回归（`session.cancel` → 主键变停止）。
///
/// ## 为什么单独一组
///
/// 2026-10-17 之前手机上**没有"打断"这个动作**：会话在跑时想停，只能等它
/// 自己跑完。DSH Web 的主键在运行中且没有草稿时是停止钮
/// （`ui-conversation/src/client/skeleton/InputBar.tsx:323` 的
/// `primaryStops`），走 `session/select-model`… 不，走 `session.cancel`
/// （`@Remote('cancel')`，`session-controller/src/index.ts:472`）。
/// 语义是"取消当前轮次但**保留待处理收件箱**"（`:467-470` 注释原话）——
/// 排队中的消息不会被这次取消丢掉。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/permission.dart';
import 'package:dsh_mobile/model/send_mode.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/dsh_composer.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

class _CancelClient implements SyncClient {
  _CancelClient({this.onCall});

  final Object? Function(String method, Map<String, Object?> params)? onCall;
  final List<Map<String, Object?>> calls = [];
  final _jobs = StreamController<JobFrame>.broadcast();

  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => _jobs.stream;
  @override
  Future<void> start() async {}

  @override
  Future<void> reconnect() => start();

  @override
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> subscribe(String sid, {required int since}) async {}
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
    calls.add({'method': method, 'params': params, 'requestId': requestId});
    return onCall?.call(method, params) as T;
  }
}

void main() {
  test('cancel：只带 sid，不带幂等键（契约 §5.7 那一列是空的）', () async {
    final client = _CancelClient(
      onCall: (m, p) => m == 'session.cancel' ? const {'accepted': true} : null,
    );
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');

    expect(await app.cancel('sid_A'), isTrue);
    final call = client.calls.lastWhere((c) => c['method'] == 'session.cancel');
    expect(call['params'], {'sid': 'sid_A'});
    expect(call['requestId'], isNull, reason: '取消没有第二次副作用，不需要幂等键');
    app.dispose();
  });

  test('cancel 失败：留声并返回 false', () async {
    final client = _CancelClient(
      onCall: (m, p) =>
          throw const ProtocolException(ErrorCode.sessionAgentBusy, '电脑侧正忙着'),
    );
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');

    expect(await app.cancel('sid_A'), isFalse);
    expect(app.lastError?.code, ErrorCode.sessionAgentBusy);
    app.dispose();
  });

  // 主键的语义（照 Web 的 primaryStops）：运行中且没草稿 → 停止；
  // 有草稿 → 发送（按当前发送模式）。
  group('主键：停止 / 发送', () {
    Widget wrap({
      required bool running,
      required VoidCallback? onStop,
      required TextEditingController controller,
    }) => MaterialApp(
      theme: DshTheme.dark(),
      home: Scaffold(
        body: DshComposer(
          controller: controller,
          attachments: const [],
          modelName: 'auto',
          reasoningLabel: '默认',
          access: const PermissionChip(
            icon: 'permissionReadOnly',
            label: '只读',
            warn: false,
          ),
          sendMode: SendMode.queue,
          sending: false,
          running: running,
          onStop: onStop,
          onSend: () {},
          onAttach: () {},
          onPickModel: () {},
          onPickAccess: () {},
          onRemoveAttachment: (_) {},
        ),
      ),
    );

    testWidgets('运行中 + 空草稿：主键是停止', (tester) async {
      var stopped = false;
      final controller = TextEditingController();
      await tester.pumpWidget(
        wrap(
          running: true,
          onStop: () => stopped = true,
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      // 用 key 找主键：tooltip 不唯一（发送模式 chip 也说"排队发送"）。
      final primary = find.byKey(const Key('composer-primary'));
      expect(primary, findsOneWidget);
      expect(find.byTooltip('停止'), findsOneWidget);
      await tester.tap(
        find.descendant(of: primary, matching: find.byType(InkWell)),
      );
      await tester.pumpAndSettle();
      expect(stopped, isTrue);
      controller.dispose();
    });

    testWidgets('运行中 + 有草稿：主键是发送（ tooltip 说当前模式）', (tester) async {
      final controller = TextEditingController(text: '排队中的一句');
      await tester.pumpWidget(
        wrap(running: true, onStop: () {}, controller: controller),
      );
      await tester.pumpAndSettle();

      final primary = find.byKey(const Key('composer-primary'));
      expect(
        tester
            .widget<Tooltip>(
              find
                  .descendant(of: primary, matching: find.byType(Tooltip))
                  .first,
            )
            .message,
        '排队发送',
        reason: '有草稿时主键仍是发送，tooltip 说当前模式',
      );
      controller.dispose();
    });

    testWidgets('没在跑：主键是发送', (tester) async {
      final controller = TextEditingController(text: '一句');
      await tester.pumpWidget(
        wrap(running: false, onStop: () {}, controller: controller),
      );
      await tester.pumpAndSettle();

      final primary = find.byKey(const Key('composer-primary'));
      expect(
        tester
            .widget<Tooltip>(
              find
                  .descendant(of: primary, matching: find.byType(Tooltip))
                  .first,
            )
            .message,
        '发送',
      );
      controller.dispose();
    });
  });
}
