/// 抽屉的 **watermark（每组默认显示几条）** 与「展开其余 N 个会话」。
///
/// 判据照 DSH 桌面：`SESSION_WATERMARK_BASE = 5`
/// （`packages/client/ui-workspace/src/client/rows/WorkspaceBrowser.tsx:55`）、
/// `watermarkRows()`（`:60-70`，blank 行恒显示、非 blank 计数受 watermark 限）、
/// 文案 `sessions.expand = '展开其余 {n} 个会话'`（`locales.ts:34`，用在 `:665`）。
///
/// 2026-10-27 用户原话：「桌面他不是所有展开，默认展开五个会话列表，
/// 然后下面有一个展开其余 xx 个会话这样」——手机之前把每组会话全渲染。
library;

import 'package:dsh_mobile/model/workspace.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/session_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

DrawerSession _row(String sid) =>
    DrawerSession(sid: sid, title: sid, preview: '', timeLabel: '');

List<String> _sids(int n) => [for (var i = 0; i < n; i += 1) 's$i'];

void main() {
  group('watermarkRowsOf（照桌面 watermarkRows）', () {
    test('默认只留 5 条非 blank，其余进 hiddenCount', () {
      final out = watermarkRowsOf(_sids(12));
      expect(out.rows, ['s0', 's1', 's2', 's3', 's4']);
      expect(out.hiddenCount, 7);
    });

    test('blank 行恒显示，且不占 watermark 名额', () {
      final out = watermarkRowsOf(<String>[
        'b0',
        ..._sids(7),
      ], isBlank: (sid) => sid.startsWith('b'));
      expect(out.rows, ['b0', 's0', 's1', 's2', 's3', 's4']);
      expect(out.hiddenCount, 2);
    });

    test('必须可见的会话会把 watermark 抬到刚好覆盖它', () {
      // s8 是"在跑"的那个：它不能被裁掉，否则抽屉里看不到正在出活的会话。
      final out = watermarkRowsOf(_sids(12), mustShow: const {'s8'});
      expect(out.rows.last, 's8');
      expect(out.rows.length, 9);
      expect(out.hiddenCount, 3);
    });

    test('抬高不超过 AUTO_MAX（50）', () {
      final many = _sids(120);
      final out = watermarkRowsOf(many, mustShow: {'s99'});
      expect(out.rows.length, 50, reason: '抬高上限照桌面 SESSION_WATERMARK_AUTO_MAX');
      expect(out.hiddenCount, 70);
    });

    test('不超过 watermark 时不产生 hiddenCount', () {
      final out = watermarkRowsOf(_sids(3));
      expect(out.rows.length, 3);
      expect(out.hiddenCount, 0);
    });
  });

  group('抽屉里的「展开其余 N 个会话」', () {
    Widget host(
      DrawerSection section, {
      void Function(DrawerSection section)? onRevealMore,
    }) => MaterialApp(
      theme: DshTheme.dark(),
      home: Scaffold(
        body: SessionDrawer(
          sections: [section],
          connection: const DrawerConnection(
            name: '我的电脑',
            detail: '已连接',
            platform: 'Windows',
          ),
          onNewSession: () {},
          onOpenSession: (_) {},
          onClose: () {},
          footItems: const [],
          onRevealMore: onRevealMore,
        ),
      ),
    );

    testWidgets('hiddenCount > 0 → 出现那行，点它回调（文案照桌面）', (tester) async {
      // 抽屉本身有品牌头 + 连接卡 + 搜索，默认 800×600 会把"展开其余"那行
      // 挤出 ListView 的构建范围（惰性构建，没构建就找不到）。
      await tester.binding.setSurfaceSize(const Size(420, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var revealed = 0;
      await tester.pumpWidget(
        host(
          DrawerSection(
            label: 'dsh-mobile',
            workspaceId: 'w-1',
            hiddenCount: 7,
            sessions: [for (final sid in _sids(5)) _row(sid)],
          ),
          onRevealMore: (_) => revealed += 1,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('展开其余 7 个会话'), findsOneWidget);
      await tester.tap(find.text('展开其余 7 个会话'));
      await tester.pumpAndSettle();
      expect(revealed, 1);
    });

    testWidgets('hiddenCount == 0 → 不占位', (tester) async {
      await tester.pumpWidget(
        host(
          DrawerSection(
            label: 'dsh-mobile',
            workspaceId: 'w-1',
            sessions: [_row('s0')],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('展开其余'), findsNothing);
    });
  });
}
