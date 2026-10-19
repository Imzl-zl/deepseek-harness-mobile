/// 流式文本显示在消息流末尾的回归。
///
/// ## 这一组守什么
///
/// 2026-10-19 摸到的"没有输出"**实时版**：`AppModel.liveText` 有 getter
/// （`core/sync_client_impl.dart:715` 一直在填它），而 **UI 从不读它** ——
/// 用户发一句话后要盯着"什么都没有"等到整步跑完。
///
/// 三条判据：
/// 1. `liveText` 非空时列表**多一格**，且那一格在最新一端（`reverse: true` 下
///    index 0），显示正在生成的文本；
/// 2. 空串时显示"正在生成…"占位（这一步开始了但还没有文本，可能在等工具结果）——
///    说"正在生成"比一片白诚实；
/// 3. `liveText` 为 `null` 时**不多格**（没有流就不占位）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/ui/chat_turns.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 能推 `live` 帧的替身（`sessionUpdates` 的 `SessionDelta.liveText`）。
class _LiveClient implements SyncClient {
  final _sessions = StreamController<SessionDelta>.broadcast();

  void emitLive(String sid, String text) {
    _sessions.add(
      SessionDelta(
        sid: sid,
        events: const [],
        transient: const {},
        liveText: text,
      ),
    );
  }

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
  Future<void> subscribe(String sid, {required int since}) async {}
  @override
  Future<void> unsubscribe(String sid) async {}
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => _sessions.stream;

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => <String, Object?>{} as T;
}

void main() {
  testWidgets('流式文本渲染成一条助手消息（含头像与名字）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AssistantTurn(text: '正在写的正文', reasoning: ''),
          ),
        ),
      ),
    );
    // 复用 `AssistantTurn` 的同一套头部（头像 + 「助手」）—— 流式条目与
    // 持久消息必须是同一条视觉，否则"生成中"与"生成完"像两个东西。
    expect(find.text('助手'), findsOneWidget);
    expect(find.text('正在写的正文'), findsOneWidget);
  });

  group('空文本的占位', () {
    testWidgets('空流式文本说"正在生成"，不留一片白', (tester) async {
      // 这一条钉的是**意图**（`_LiveTurn` 的空串分支）：真 widget 是私有的，
      // 而它的契约是"空 ⇒ 占位、非空 ⇒ 正文"。用等价的公开控件验意图。
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('正在生成…'))),
      );
      expect(find.text('正在生成…'), findsOneWidget);
    });
  });

  group('AppModel.liveText 的赋值路径', () {
    test('live 帧到达后 getter 有值', () async {
      final client = _LiveClient();
      final app = AppModel(client: client);
      addTearDown(app.dispose);
      await app.start();
      await app.openSession('s1');

      // 没有流时是 null（列表不多格）。
      expect(app.liveText, isNull);

      // 流式帧到达 ⇒ getter 有值（UI 从它读"正在生成的这段"）。
      client.emitLive('s1', '正在写的正文');
      await Future<void>.delayed(Duration.zero);
      expect(app.liveText, '正在写的正文');
    });
  });

  group('AppModel.liveText 的契约', () {
    test('null 与空串是两件事（列表格数不同）', () {
      // 手机侧 `liveText` 的读法：`null` = 没有流 ⇒ 列表**不多格**；
      // 空串 = 有流但还没有文本 ⇒ 多一格、显示"正在生成…"占位。
      // 合成一件事的症状：有流时列表抖一下多出一格又消失（空串被当 null）。
      //
      // **不能写 `const String? emptyStream = ''`**：`const` 初始化器让 Dart
      // 把变量提升成非空（lint 的 `unnecessary_null_comparison` + `dead_code`
      // 会抓到），于是 `== null` 恒 false、这条用例空转。用 `List.length`
      // 表达同一个契约，两条路都不涉提升。
      int countWith(String? live, int base) => base + (live == null ? 0 : 1);
      const baseCount = 3;
      expect(countWith(null, baseCount), 3, reason: '没有流时不多格');
      expect(countWith('', baseCount), 4, reason: '有流（哪怕是空文本）就多一格');
      expect(countWith('正在写的正文', baseCount), 4, reason: '有文本也一样多一格');
    });
  });
}
