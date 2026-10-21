/// 轨迹页接真投影的回归（`turnOutline` → 账本）。
///
/// ## 这一组守什么
///
/// 2026-10-19 发现的"没看到的问题"之一：`TrajectoryTab` 一直接收
/// `rows` / `entries`，而 `chat_page.dart` 的 `_TrajectoryTab` **只传了
/// `onTapEntry`** —— 两个表恒为空，轨迹页永远显示"电脑侧跑完一轮后…"。
/// 契约里 `turnOutline` 投影一直都在（`session.projections`，§5.7），
/// 手机也早就解析了别的投影，只是从没把它接进来。
///
/// 三条判据：
/// 1. `AppModel.turnOutline` 按 wire view 解析（`{turn, seq, prompt, response}`）；
/// 2. 形状不对的项**跳过**，不抛（投影认不出 = 空态，不是崩）；
/// 3. 空表时轨迹页显示空态，**不造假数据**（2026-10-15 删 `_sampleRows` 的理由）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/turn_outline.dart';
import 'package:dsh_mobile/ui/trajectory_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

class _OutlineClient extends FakeSyncClient {
  _OutlineClient(this.projections);

  final Map<String, Object?> projections;

  final _sessions = StreamController<SessionDelta>.broadcast();

  @override
  conn.ConnectionState get state => conn.ConnectionState.serving;
  @override
  Stream<conn.ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();
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
  Stream<SessionDelta> sessionUpdates(String sid) => _sessions.stream;

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'session.projections') return projections as T;
    return <String, Object?>{} as T;
  }
}

void main() {
  group('AppModel.turnOutline 按 wire view 解析', () {
    test('四项都取到；缺字段的项跳过而不是抛', () async {
      final app = AppModel(
        client: _OutlineClient({
          'turnOutline': <Object?>[
            <String, Object?>{
              'turn': 1,
              'seq': 6,
              'prompt': '记录一下给我新会话提示词',
              'response': '已写进 docs/',
            },
            // 缺 seq：这一项没有意义（跳转不到消息），跳过。
            <String, Object?>{'turn': 2, 'prompt': 'x', 'response': 'y'},
            // turn 不是 int：跳过。
            <String, Object?>{
              'turn': '3',
              'seq': 9,
              'prompt': '',
              'response': '',
            },
            // 形状对但预览为空：**保留**（轮次存在，只是没预览）——
            // 空预览由 `promptLabel` / `responseLabel` 给占位。
            <String, Object?>{
              'turn': 4,
              'seq': 12,
              'prompt': '',
              'response': '',
            },
          ],
        }),
      );
      addTearDown(app.dispose);
      await app.start();
      // 投影**按 sid 存**（`refreshProjections(sid)`），而"当前会话那一包"
      // 只在 `sid == currentSid` 时才落地（子级目录的重读不能覆盖它），
      // 所以先打开会话 —— 生产里也是 `openSession` 调它。
      await app.openSession('s1');

      final outline = app.turnOutline;
      expect(outline.length, 2, reason: '另两项形状不对，跳过');
      expect(outline.first.turn, 1);
      expect(outline.first.prompt, '记录一下给我新会话提示词');
      expect(outline.first.response, '已写进 docs/');
      // 空预览给占位，不留一片白。
      expect(outline.last.promptLabel, TurnOutlineEntry.kEmptyPreview);
      expect(outline.last.responseLabel, TurnOutlineEntry.kEmptyPreview);
    });

    test('投影缺失 = 空表（不抛、不造）', () async {
      final app = AppModel(client: _OutlineClient(const {}));
      addTearDown(app.dispose);
      await app.start();
      expect(app.turnOutline, isEmpty);
    });
  });

  group('轨迹页', () {
    testWidgets('空表显示空态，不摆假行', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: TrajectoryTab(onTapEntry: null)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('电脑侧跑完一轮后'), findsOneWidget);
    });

    testWidgets('有轮次就一行一轮，提问与回复都显示', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TrajectoryTab(
              entries: [
                TraceEntry(
                  kind: TraceKind.assistant,
                  name: '第 1 轮',
                  took: '',
                  prompt: '帮我启动',
                  summary: '已经在跑了',
                ),
              ],
              onTapEntry: null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('第 1 轮'), findsOneWidget);
      expect(find.text('帮我启动'), findsOneWidget);
      expect(find.text('已经在跑了'), findsOneWidget);
    });
  });
}
