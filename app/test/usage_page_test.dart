/// 用量独立页的回归（总量 + 按项目 + 按会话）。
///
/// ## 这一组守什么
///
/// 2026-10-19 用户原话：「用量你最好也是做成一个页面的，你看 D:\sudy\github\rikkahub
/// 你这样信息量不多，单页面的话信息量可以做很多，总量，单个项目使用量是吧」。
/// 所以从"设置页里的一组"搬成独立页（`ui/usage_page.dart`），明细的断言
/// 也从 `settings_page_test.dart` 搬到这里。
///
/// ## 数据契约
///
/// 电脑侧答 `{sessions, grandTotalTokens, byProject:[{path,tokens,sessions}],
/// bySession:[{sid,title,cwd,tokens}]}`（契约 §5.7 的 `usage.summary`）。
/// **DSH 没有跨会话汇总接口**，聚合在连接器做（见 `model/usage_summary.dart`
/// 的文件头）。
library;

import 'package:dsh_mobile/model/usage_summary.dart';
import 'package:dsh_mobile/ui/usage_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一份**带项目分组**的汇总（两个项目、三个会话）。
///
/// 注意 `byProject` 两档都 > 0 —— 电脑侧会过滤掉全零的档
/// （契约 §5.7 的聚合规则②），fixture 照真实形状来。
const _summary = UsageSummary(
  sessions: 3,
  grandTotalTokens: 298000000,
  byProject: [
    UsageProject(
      path: 'D:\\sudy\\myproject\\dsh-mobile',
      tokens: 249000000,
      sessions: 2,
    ),
    UsageProject(path: '', tokens: 49000000, sessions: 1),
  ],
  bySession: [
    UsageEntry(
      sid: 'sid-1',
      title: '插件UI与交互体验优化',
      tokens: 200000000,
      cwd: 'D:\\sudy\\myproject\\dsh-mobile',
    ),
    UsageEntry(
      sid: 'sid-2',
      title: '',
      tokens: 49000000,
      cwd: 'D:\\sudy\\myproject\\dsh-mobile',
    ),
    UsageEntry(sid: 'sid-3', title: '另一个项目', tokens: 49000000, cwd: ''),
  ],
);

void main() {
  testWidgets('总量 + 按项目 + 按会话，一页三级', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: UsagePage(summary: _summary)),
    );
    await tester.pumpAndSettle();

    // ① 总量卡（同一个格式化函数 ⇒ `298M`）。
    expect(find.text('这台电脑一共'), findsOneWidget);
    expect(find.text('298M'), findsOneWidget);
    expect(find.text('来自 3 个会话（子智能体不计入）'), findsOneWidget);

    // ② 项目名取**路径末段**（`D:\sudy\myproject\dsh-mobile` → `dsh-mobile`）。
    expect(find.text('dsh-mobile'), findsOneWidget);
    // 没有 `cwd` 的那个项目档显示成「未关联项目」。
    expect(find.text(UsageProject.kUnlinkedProjectLabel), findsOneWidget);

    // ③ 会话行：标题空串按 DSH 的链退到「未命名」。
    expect(find.text('插件UI与交互体验优化'), findsOneWidget);
    expect(find.text('未命名'), findsOneWidget);
    // 挂在「未关联项目」下的那个会话。
    expect(find.text('另一个项目'), findsOneWidget);
  });

  testWidgets('点会话行：回调带上 sid', (tester) async {
    String? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: UsagePage(
          summary: _summary,
          onOpenSession: (sid) => opened = sid,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('插件UI与交互体验优化'));
    await tester.pumpAndSettle();
    expect(opened, 'sid-1');
  });

  testWidgets('拉不到：空态说原因，不摆 0 tok', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: UsagePage(failure: '电脑侧炸了')),
    );
    await tester.pumpAndSettle();

    expect(find.text('拉不到用量'), findsOneWidget);
    expect(find.text('电脑侧炸了'), findsOneWidget);
    // 不摆一个看起来在统计的 0。
    expect(find.text('这台电脑一共'), findsNothing);
  });

  group('UsageSummary.fromWire', () {
    test('认不出就回 null', () {
      expect(UsageSummary.fromWire(null), isNull);
      expect(UsageSummary.fromWire('nope'), isNull);
      expect(
        UsageSummary.fromWire(<String, Object?>{'sessions': 1}),
        isNull,
        reason: '缺 grandTotalTokens',
      );
    });

    test('按项目分组：空目录单独一档', () {
      final summary = UsageSummary.fromWire(<String, Object?>{
        'sessions': 3,
        'grandTotalTokens': 300,
        'byProject': <Object?>[
          <String, Object?>{'path': 'D:\\a', 'tokens': 200, 'sessions': 2},
          <String, Object?>{'path': '', 'tokens': 100, 'sessions': 1},
        ],
        'bySession': <Object?>[
          <String, Object?>{
            'sid': 's1',
            'title': 'x',
            'cwd': 'D:\\a',
            'tokens': 200,
          },
          <String, Object?>{'sid': 's2', 'title': '', 'cwd': '', 'tokens': 100},
        ],
      })!;
      expect(summary.byProject.length, 2);
      expect(summary.byProject.first.label, 'a');
      expect(summary.byProject.last.label, UsageProject.kUnlinkedProjectLabel);
      // `grouped` 把会话挂到项目下（顺序仍按用量降序）。
      final groups = summary.grouped;
      expect(groups.length, 2);
      expect(groups.first.entries.length, 1);
      expect(groups.first.entries.single.sid, 's1');
      expect(groups.last.entries.single.sid, 's2');
    });

    test('老连接器没有 byProject：grouped 空，界面退回扁平榜', () {
      final summary = UsageSummary.fromWire(<String, Object?>{
        'sessions': 1,
        'grandTotalTokens': 10,
        'bySession': <Object?>[
          <String, Object?>{'sid': 's1', 'title': 'x', 'tokens': 10},
        ],
      })!;
      expect(summary.byProject, isEmpty);
      expect(summary.grouped, isEmpty);
      // 会话行仍解析得出来（`cwd` 缺省为空串）。
      expect(summary.bySession.single.cwd, '');
    });
  });
}
