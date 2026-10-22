/// 界面字号：**两层倍率**（系统 × App）与字号角色表。
///
/// 守四件事：
///
/// 1. **角色表的派生公式照 DSH**（`gradient-shadow-text.css:56-99`）—— 那一层没变，
///    仍然是正文 / secondary / 标题阶梯；
/// 2. **App 内是四档倍率**（0.9 / 1.0 / 1.15 / 1.3），落盘、越界夹取、重启读回；
/// 3. **等比放大**：`MediaQuery.textScaler` 一乘，**所有**文字（含 caption）一起长，
///    对比关系不变 —— 这正是"全局"且不丑的原因；
/// 4. **390dp 上到 1.3 不溢出**（长正文 + 标题 + 用户气泡各一条）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/store.dart';
import 'package:dsh_mobile/model/preferences.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/theme/dsh_type.dart';
import 'package:dsh_mobile/ui/chat_turns.dart';
import 'package:dsh_mobile/ui/dsh_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

void main() {
  group('字号角色表（照 DSH 的派生）', () {
    test('默认档：与改造前手写的字面量逐个相同', () {
      const type = DshType.standard;
      expect(type.body, 14);
      expect(type.bodyLine, 24);
      expect(type.secondary, 13);
      expect(type.secondaryLine, 20);
      expect(type.h1, 21);
      expect(type.h1Line, 30);
      expect(type.h2, 19);
      expect(type.h2Line, 28);
      expect(type.h3, 18);
      expect(type.h3Line, 26);
    });

    test('secondary 的四档（10→9 / 14→13 / 15→13 / 22→20）', () {
      expect(const DshType(10).secondary, 9);
      expect(const DshType(14).secondary, 13);
      expect(const DshType(15).secondary, 13);
      expect(const DshType(22).secondary, 20);
      expect(const DshType(22).secondaryLine, 20 + (20 - 13));
    });

    test('标题阶梯跟着同一个 delta', () {
      expect(const DshType(22).h1, 21 + 8);
      expect(const DshType(10).h2, 19 - 4);
      expect(const DshType(18).h3, 18 + 4);
    });
  });

  group('App 内倍率（四档）', () {
    test('档位表与标签：0.9 / 1.0 / 1.15 / 1.3，默认 1.0', () {
      expect(kUiScaleSteps, [0.9, 1.0, 1.15, 1.3]);
      expect(kUiScaleLabels.length, kUiScaleSteps.length);
      expect(kUiScaleDefaultIndex, 1);
      expect(kUiScaleSteps[kUiScaleDefaultIndex], 1.0);
    });

    test('设了会落盘；越界夹到档位两端', () async {
      final prefs = _MemoryPreferences();
      final app = AppModel(client: _NullClient(), prefs: prefs);
      addTearDown(app.dispose);

      expect(app.uiScale, 1.0, reason: '默认标准档');
      await app.setUiScaleIndex(3);
      expect(app.uiScale, 1.3);
      expect(prefs.values[AppModel.kUiScaleKey], '3');

      await app.setUiScaleIndex(99);
      expect(app.uiScaleIndex, 3, reason: '上界夹到最后档');
      await app.setUiScaleIndex(-5);
      expect(app.uiScaleIndex, 0, reason: '下界夹到第一档');
    });

    test('重启后读回同一个档位；盘中是垃圾值就用默认', () async {
      final prefs = _MemoryPreferences()..values[AppModel.kUiScaleKey] = '2';
      final app = AppModel(client: _NullClient(), prefs: prefs);
      addTearDown(app.dispose);
      await app.start();
      expect(app.uiScaleIndex, 2);
      expect(app.uiScale, 1.15);

      final broken = _MemoryPreferences()
        ..values[AppModel.kUiScaleKey] = 'huge';
      final app2 = AppModel(client: _NullClient(), prefs: broken);
      addTearDown(app2.dispose);
      await app2.start();
      expect(app2.uiScaleIndex, kUiScaleDefaultIndex, reason: '垃圾值 ⇒ 默认档');
    });
  });

  group('390dp 上到 1.3 不溢出（等比放大，含 caption）', () {
    Future<void> pumpAt(WidgetTester tester, double scale, Widget body) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SingleChildScrollView(child: body),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Markdown 正文 / 标题 / 行内代码：390dp / 1.3 不溢出且真的变大', (tester) async {
      const doc =
          '## 标题二\n\n'
          '正文里最长的这一段是用来量换行的：Run 3 separate shell commands '
          'one at a time, then print `echo done` in the same shell.\n\n'
          '# 标题一\n\n'
          '### 标题三\n\n'
          '| 列一 | 列二 |\n|---|---|\n| a | b |\n';
      await pumpAt(tester, 1.0, const DshMarkdown(doc));
      final at10 = tester.getSize(find.byType(DshMarkdown)).height;
      await pumpAt(tester, 1.3, const DshMarkdown(doc));
      expect(tester.takeException(), isNull, reason: '1.3 档不许溢出');
      final at13 = tester.getSize(find.byType(DshMarkdown)).height;
      expect(at13, greaterThan(at10 * 1.15), reason: '等比放大真的生效');
    });

    testWidgets('用户气泡：390dp / 1.3 不溢出、基准字号不被改', (tester) async {
      const text =
          'A very long single line of english words that must wrap inside '
          'the bubble instead of overflowing the right edge.';
      await pumpAt(tester, 1.3, const UserTurn(text));
      expect(tester.takeException(), isNull);
      // 基准字号仍是 14（角色表没被改），实际渲染由 `TextScaler` 放大。
      final widget = tester.widget<Text>(find.text(text));
      expect(widget.style?.fontSize, 14);
    });
  });
}

/// 内存版偏好缝（`meta` 表在纯 Dart 测试里的替身）。
class _MemoryPreferences implements PreferenceStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

/// `AppModel.start()` 要的那几条缝；这个用例不连通道。
class _NullClient extends FakeSyncClient {
  final _sessions = StreamController<SessionDelta>.broadcast();

  @override
  conn.ConnectionState get state => conn.ConnectionState.idle;
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
}
