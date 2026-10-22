/// 字号刻度：`base + delta`（`app/lib/theme/dsh_type.dart`）。
///
/// 守三件事：
///
/// 1. **派生公式照 DSH 逐档对**（`ui-theme/src/styles/gradient-shadow-text.css:56-63`）：
///    delta = size−14；secondary = min(size−1, max(13, size−2))；标题阶梯 21/19/18 + delta。
/// 2. **落盘与边界**：10–22、默认 14；越界夹到端点；重启读回同一个值。
/// 3. **390dp 上到 22 不溢出**：这是用户最担心的"大了样式崩了"的机械判据。
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
  group('派生公式（照 DSH）', () {
    test('默认档 14：与改造前手写的字面量逐个相同', () {
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
      // 这四组是 DSH 注释里点名的那四个（`:53`）。
      expect(const DshType(10).secondary, 9);
      expect(const DshType(14).secondary, 13);
      expect(const DshType(15).secondary, 13);
      expect(const DshType(22).secondary, 20);
      // 行高跟着 secondary 的相对增量走（13→20 是默认那一档）。
      expect(const DshType(22).secondaryLine, 20 + (20 - 13));
      expect(const DshType(10).secondaryLine, 20 + (9 - 13));
    });

    test('标题阶梯跟着同一个 delta', () {
      expect(const DshType(22).h1, 21 + 8);
      expect(const DshType(22).h1Line, 30 + 8);
      expect(const DshType(10).h2, 19 - 4);
      expect(const DshType(10).h2Line, 28 - 4);
      expect(const DshType(18).h3, 18 + 4);
    });

    test('范围与默认值是 DSH 那三个数', () {
      expect(DshType.minSize, 10);
      expect(DshType.maxSize, 22);
      expect(DshType.defaultSize, 14);
      expect(kContentFontSizeMin, 10);
      expect(kContentFontSizeMax, 22);
      expect(kContentFontSizeDefault, 14);
    });
  });

  group('落盘与边界', () {
    test('设了会落盘；越界夹到端点', () async {
      final prefs = _MemoryPreferences();
      final app = AppModel(client: _NullClient(), prefs: prefs);
      addTearDown(app.dispose);

      expect(app.contentFontSize, 14, reason: '默认 14');
      await app.setContentFontSize(18);
      expect(app.contentFontSize, 18);
      expect(prefs.values[AppModel.kContentFontSizeKey], '18');

      await app.setContentFontSize(99);
      expect(app.contentFontSize, 22, reason: '上界夹到 22');
      await app.setContentFontSize(-3);
      expect(app.contentFontSize, 10, reason: '下界夹到 10');
    });

    test('重启后读回同一个值；盘中是垃圾值就用默认（不猜）', () async {
      final prefs = _MemoryPreferences()
        ..values[AppModel.kContentFontSizeKey] = '19';
      final app = AppModel(client: _NullClient(), prefs: prefs);
      addTearDown(app.dispose);
      await app.start();
      expect(app.contentFontSize, 19);

      final broken = _MemoryPreferences()
        ..values[AppModel.kContentFontSizeKey] = 'huge';
      final app2 = AppModel(client: _NullClient(), prefs: broken);
      addTearDown(app2.dispose);
      await app2.start();
      expect(app2.contentFontSize, 14, reason: '盘上是垃圾值 ⇒ 默认，不猜');
    });
  });

  group('390dp 上到 22 不溢出（用户最担心的那条）', () {
    Future<void> pumpAt(WidgetTester tester, int size, Widget body) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: DshTypeScope(
            type: DshType(size),
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

    testWidgets('Markdown 正文 / 标题阶梯 / 行内代码：390dp / 22px 不溢出', (tester) async {
      const doc =
          '## 标题二\n\n'
          '正文里最长的这一段是用来量换行的：Run 3 separate shell commands '
          'one at a time, then print `echo done` in the same shell.\n\n'
          '# 标题一\n\n'
          '### 标题三\n\n'
          '| 列一 | 列二 |\n|---|---|\n| a | b |\n';
      await pumpAt(tester, 14, const DshMarkdown(doc));
      expect(tester.takeException(), isNull);
      final at14 = tester.getSize(find.byType(DshMarkdown)).height;

      await pumpAt(tester, 22, const DshMarkdown(doc));
      expect(tester.takeException(), isNull, reason: '22 档不许溢出');
      final at22 = tester.getSize(find.byType(DshMarkdown)).height;
      expect(
        at22,
        greaterThan(at14 * 1.15),
        reason: '字号真的作用到了正文（22 档明显更高），而不是被主题里的 14 顶掉',
      );
    });

    testWidgets('用户气泡：390dp / 22px 不溢出（长英文串要能折行）', (tester) async {
      await pumpAt(tester, 22, const UserTurn(_longText));
      expect(tester.takeException(), isNull);
      final text = tester.widget<Text>(find.text(_longText));
      expect(text.style?.fontSize, 22, reason: '用户正文按 22 排');
    });
  });
}

/// 390dp 上一定会折行的长英文串（气泡宽度上限 82%）。
const String _longText =
    'A very long single line of english words that must wrap inside '
    'the bubble instead of overflowing the right edge.';

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
