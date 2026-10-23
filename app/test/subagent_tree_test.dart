/// 右抽屉「子智能体」**目录树**（`ui/subagent_tree.dart`）的回归。
///
/// 结构照 DSH Web 的 `CatalogRows`
/// （`packages/client/ui-subagent/src/client/SubagentHeaderLineage.tsx:190-408`）。
/// 这组守四件事：
///
/// 1. **三态分开**：加载中 / 失败+重试 / 读到空，是三句不同的话；
/// 2. **点行是进入，点 disclosure 才是展开**（两个手势，两个回调）；
/// 3. **直接子级 + 懒加载**：展开才请求那一级的目录，收起重置整枝；
/// 4. **行里不许有假数字**：token / 时长来自子会话自己的投影，没给就整格不显示。
///
/// 注意：在跑的行里有一个会转的状态点（`DshStateDot(ongoing)`）与一个 1 秒
/// 定时器，所以**这些用例不能用 `pumpAndSettle`**（永远不会 settle）。
library;

import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/model/session_stats.dart';
import 'package:dsh_mobile/model/subagent.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/subagent_tree.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _usage = TokenUsage(
  uncachedInputTokens: 1000,
  outputTokens: 200,
  cacheReadTokens: 40000,
  cacheWriteTokens: 500,
);

SubagentRow _row(String id, {String mode = 'continuable', String? label}) =>
    SubagentRow(id: id, createdAt: 0, mode: mode, label: label ?? id);

/// 一屏树。`catalogs` / `nodes` 由用例自己持有并在需要时改写（`StatefulBuilder`
/// 负责重建，与生产里"`AppModel` 通知 → 页面重建"同一条路）。
Widget _host({
  required Map<String, SubagentCatalog> catalogs,
  required Map<String, SubagentNode> nodes,
  String rootSid = 'root',
  String? currentSid,
  List<String>? opened,
  List<String>? openedParents,
  List<String>? loaded,
  int Function()? clock,
}) {
  return _Host(
    catalogs: catalogs,
    nodes: nodes,
    rootSid: rootSid,
    currentSid: currentSid,
    opened: opened,
    openedParents: openedParents,
    loaded: loaded,
    clock: clock,
  );
}

/// 宿主：`catalogs` / `nodes` 由用例持有，改写后调 [rebuild] 才重画 ——
/// 与生产里"`AppModel` 通知 → 页面重建"同一条路（**不**在 build 里轮询）。
class _Host extends StatefulWidget {
  const _Host({
    required this.catalogs,
    required this.nodes,
    required this.rootSid,
    required this.currentSid,
    required this.opened,
    required this.openedParents,
    required this.loaded,
    required this.clock,
  });

  final Map<String, SubagentCatalog> catalogs;
  final Map<String, SubagentNode> nodes;
  final String rootSid;
  final String? currentSid;
  final List<String>? opened;

  /// 每次 `onOpen` 的**父级**（画出那一行的那一层）。与 [opened] 一一对应。
  final List<String>? openedParents;
  final List<String>? loaded;
  final int Function()? clock;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  /// 用例改写数据后手动触发一次重建。
  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: DshTheme.dark(),
      home: Scaffold(
        body: SubagentTree(
          rootSid: widget.rootSid,
          catalogOf: (sid) =>
              widget.catalogs[sid] ?? const SubagentCatalog.loading(),
          nodeOf: (row) => widget.nodes[row.id] ?? SubagentNode(row: row),
          onOpen: (node, parentSid) {
            widget.opened?.add(node.id);
            widget.openedParents?.add(parentSid);
          },
          onLoad: (sid) {
            widget.loaded?.add(sid);
            rebuild();
          },
          currentSid: widget.currentSid,
          clock: widget.clock ?? () => 0,
        ),
      ),
    );
  }
}

void main() {
  group('三态：加载中 / 失败 / 读到空', () {
    testWidgets('还没读到的目录 = 加载中，不是"没有子智能体"', (tester) async {
      await tester.pumpWidget(_host(catalogs: {}, nodes: {}));
      // Web 的判据：`state==='loading' && entries 空`（`:212`）。
      expect(find.text('正在加载子智能体…'), findsOneWidget);
      expect(
        find.text('没有子智能体。'),
        findsNothing,
        reason: '"没读到"与"读到空"是两句话（本仓第八条教训 4）',
      );
    });

    testWidgets('读失败：错误原文位 + 重试；点重试重读这一层', (tester) async {
      final loaded = <String>[];
      await tester.pumpWidget(
        _host(
          catalogs: {'root': const SubagentCatalog.failed()},
          nodes: {},
          loaded: loaded,
        ),
      );
      // 文案照 DSH 的 zh 词典（`locales.ts:23,25`）。
      expect(find.text('无法加载子智能体'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('正在加载子智能体…'), findsNothing);

      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(loaded, ['root'], reason: '重试 = 重读这一层的目录（Web `:222-234`）');
    });

    testWidgets('成功读到且为空：空态一句（只有这时才说没有）', (tester) async {
      await tester.pumpWidget(
        _host(catalogs: {'root': const SubagentCatalog.ready([])}, nodes: {}),
      );
      expect(find.text('没有子智能体。'), findsOneWidget);
      expect(find.text('正在加载子智能体…'), findsNothing);
    });

    testWidgets('还没有选中会话（rootSid 空）：说空态，不永远转"加载中"', (tester) async {
      await tester.pumpWidget(_host(catalogs: {}, nodes: {}, rootSid: ''));
      expect(find.text('正在加载子智能体…'), findsNothing);
      expect(find.text('没有子智能体。'), findsOneWidget);
    });
  });

  group('行：label + 第二行 + 右侧两行指标', () {
    testWidgets('三段文字都在（title · mode · activity / token / 时长）', (tester) async {
      final row = _row('child-1', label: '研究图标链路');
      final node = SubagentNode(
        row: row,
        title: '调研实现',
        tokens: _usage,
        timing: const SubagentTiming(settledMs: 65000, lastTurnCompleted: true),
      );
      await tester.pumpWidget(
        _host(
          catalogs: {
            'root': SubagentCatalog.ready([row]),
          },
          nodes: {'child-1': node},
        ),
      );

      expect(find.text('研究图标链路'), findsOneWidget);
      // 详情行 = `title · mode · activity · 时长`（Web 的前三段 + 挪进来的时长）。
      expect(find.text('调研实现 · 可继续 · 已完成 · 1分05秒'), findsOneWidget);
      // 右列**只放 token 一个数**（触屏：300dp 放不下两行小字）。
      expect(find.text('41.7K tok'), findsOneWidget);
      // 时长不再单独占右列的一行。
      expect(find.text('1分05秒'), findsNothing);
    });

    testWidgets('没有计时 / token：那两格整个不显示（不摆 0）', (tester) async {
      final row = _row('child-1', label: '抽图标');
      await tester.pumpWidget(
        _host(
          catalogs: {
            'root': SubagentCatalog.ready([row]),
          },
          nodes: {'child-1': SubagentNode(row: row)},
        ),
      );
      expect(find.text('抽图标'), findsOneWidget);
      expect(find.textContaining('tok'), findsNothing);
      expect(find.textContaining('秒'), findsNothing);
      expect(find.textContaining('分'), findsNothing);
    });

    testWidgets('当前行加粗（Web 的 currentLabel）', (tester) async {
      final current = _row('child-1', label: '正在看的');
      final other = _row('child-2', label: '别的');
      await tester.pumpWidget(
        _host(
          catalogs: {
            'root': SubagentCatalog.ready([current, other]),
          },
          nodes: {
            'child-1': SubagentNode(row: current),
            'child-2': SubagentNode(row: other),
          },
          currentSid: 'child-1',
        ),
      );
      final currentStyle = tester.widget<Text>(find.text('正在看的')).style!;
      final otherStyle = tester.widget<Text>(find.text('别的')).style!;
      expect(currentStyle.fontWeight, FontWeight.w600);
      expect(otherStyle.fontWeight, FontWeight.w400);
    });

    testWidgets('在跑的行：时长每秒长一格（1 秒定时器真的在走）', (tester) async {
      var now = 1000000;
      final row = _row('child-1', label: '跑着的');
      final node = SubagentNode(
        row: row,
        running: true,
        timing: SubagentTiming(
          settledMs: 0,
          activeSince: now - 5000,
          activeThrough: now,
        ),
      );
      await tester.pumpWidget(
        _host(
          catalogs: {
            'root': SubagentCatalog.ready([row]),
          },
          nodes: {'child-1': node},
          clock: () => now,
        ),
      );
      expect(find.textContaining('· 5秒'), findsOneWidget);

      now += 1000;
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('· 6秒'), findsOneWidget, reason: '在跑的时长要跟着秒走');
    });
  });

  group('两个手势：点行进入，点 disclosure 展开', () {
    testWidgets('点行 = onOpen（不是展开，也不是加载）', (tester) async {
      final opened = <String>[];
      final openedParents = <String>[];
      final loaded = <String>[];
      final row = _row('child-1', label: '调研实现');
      await tester.pumpWidget(
        _host(
          catalogs: {
            'root': SubagentCatalog.ready([row]),
          },
          nodes: {'child-1': SubagentNode(row: row)},
          opened: opened,
          openedParents: openedParents,
          loaded: loaded,
        ),
      );

      await tester.tap(find.text('调研实现'));
      await tester.pump();

      expect(opened, ['child-1'], reason: '点目录项 = openChild（`:279-287`）');
      expect(openedParents, [
        'root',
      ], reason: '父级由画出这一行的那一层交出（`_Level.sid`），调用方不必回目录里查');
      expect(loaded, isEmpty, reason: '点行不该顺手去读子级目录');
    });

    testWidgets('点 disclosure：先懒加载，读到后展开出孙级', (tester) async {
      final loaded = <String>[];
      final opened = <String>[];
      final openedParents = <String>[];
      final child = _row('child-1', label: '调研实现');
      final grand = _row('grand-1', label: '孙级');
      final catalogs = <String, SubagentCatalog>{
        'root': SubagentCatalog.ready([child]),
      };
      await tester.pumpWidget(
        _host(
          catalogs: catalogs,
          nodes: {
            'child-1': SubagentNode(row: child),
            'grand-1': SubagentNode(row: grand),
          },
          loaded: loaded,
          opened: opened,
          openedParents: openedParents,
        ),
      );

      final disclosure = find.byTooltip('展开 调研实现 的下级子智能体');
      expect(
        disclosure,
        findsOneWidget,
        reason: '未知下级的行要给 disclosure（Web :242）',
      );

      await tester.tap(disclosure);
      await tester.pump();

      expect(loaded, [
        'child-1',
      ], reason: '展开才读（Web `toggleBranch` → `refreshProjection`）');
      // **两个手势互不串**：点展开按钮不该顺手进入那个子会话。
      expect(opened, isEmpty, reason: '展开 ≠ 进入');
      // 只有"成功读到且为空"才是空叶；还在读 ⇒ 显示加载中（`:382-384`）。
      expect(find.text('正在加载子智能体…'), findsOneWidget);

      catalogs['child-1'] = SubagentCatalog.ready([grand]);
      tester.state<_HostState>(find.byType(_Host)).rebuild();
      await tester.pump();

      expect(find.text('孙级'), findsOneWidget);
      expect(find.text('正在加载子智能体…'), findsNothing);
      expect(
        find.byTooltip('收起 调研实现 的下级子智能体'),
        findsOneWidget,
        reason: '展开后 disclosure 的无障碍名换成"收起"（`locales.ts:34-35`）',
      );

      // 孙级那一行的父级是 **child-1**（画出它的那一层），不是 root ——
      // 这一条钉的就是"父级随行交出"：调用方不需要（也不该）扫目录反推。
      await tester.tap(find.text('孙级'));
      await tester.pump();
      expect(opened, ['grand-1'], reason: '点孙级 = 进入它');
      expect(openedParents, ['child-1'], reason: '父级是它所在的那一层');
    });

    testWidgets('子级读失败：展开后显示错误 + 重试，点重试重读那个子级', (tester) async {
      final loaded = <String>[];
      final child = _row('child-1', label: '调研实现');
      final catalogs = <String, SubagentCatalog>{
        'root': SubagentCatalog.ready([child]),
      };
      await tester.pumpWidget(
        _host(
          catalogs: catalogs,
          nodes: {'child-1': SubagentNode(row: child)},
          loaded: loaded,
        ),
      );
      await tester.tap(find.byTooltip('展开 调研实现 的下级子智能体'));
      await tester.pump();

      catalogs['child-1'] = const SubagentCatalog.failed();
      tester.state<_HostState>(find.byType(_Host)).rebuild();
      await tester.pump();
      expect(find.text('无法加载子智能体'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(loaded, ['child-1', 'child-1'], reason: '重试要重读**那个子级**');
    });

    testWidgets('已确认空叶：没有 disclosure，但仍然可以进入', (tester) async {
      final opened = <String>[];
      final child = _row('child-1', label: '抽图标');
      await tester.pumpWidget(
        _host(
          catalogs: {
            'root': SubagentCatalog.ready([child]),
            'child-1': const SubagentCatalog.ready([]),
          },
          nodes: {'child-1': SubagentNode(row: child)},
          opened: opened,
        ),
      );

      expect(
        find.byTooltip('展开 抽图标 的下级子智能体'),
        findsNothing,
        reason: '成功读到空才是已知空叶（Web `isKnownLeaf`，:196-198）',
      );
      await tester.tap(find.text('抽图标'));
      await tester.pump();
      expect(opened, ['child-1']);
    });

    testWidgets('external 行：不能进入、也不能展开', (tester) async {
      final opened = <String>[];
      final external = _row('ext', mode: 'external', label: '外部跑批');
      await tester.pumpWidget(
        _host(
          catalogs: {
            'root': SubagentCatalog.ready([external]),
          },
          nodes: {'ext': SubagentNode(row: external)},
          opened: opened,
        ),
      );
      // 外部任务没有活动态词，第二行只剩 mode。
      expect(find.text('外部任务'), findsOneWidget);
      expect(find.byTooltip('展开 外部跑批 的下级子智能体'), findsNothing);
      await tester.tap(find.text('外部跑批'));
      await tester.pump();
      expect(
        opened,
        isEmpty,
        reason: 'Web 的 `open()` 第一行就 `if (external) return`',
      );
    });

    testWidgets('空叶行没有展开按钮（有下级的行才有）', (tester) async {
      final expandable = _row('child-1', label: '可展开');
      final leaf = _row('child-2', label: '空叶');
      await tester.pumpWidget(
        _host(
          catalogs: {
            'root': SubagentCatalog.ready([expandable, leaf]),
            'child-2': const SubagentCatalog.ready([]),
          },
          nodes: {
            'child-1': SubagentNode(row: expandable),
            'child-2': SubagentNode(row: leaf),
          },
        ),
      );
      expect(find.byTooltip('展开 可展开 的下级子智能体'), findsOneWidget);
      expect(find.byTooltip('展开 空叶 的下级子智能体'), findsNothing);
    });
  });

  group('展开状态', () {
    testWidgets('畸形目录成环：不再给展开能力，也不会把栈打穿', (tester) async {
      // 健康的 catalog 是树（子级不会是自己或自己的祖先），但递归跑的是
      // **线上投影**的形状 —— 真出现环时必须停下来，否则是不可捕获的
      // `StackOverflowError`（整页白屏）。
      final a = _row('a', label: '环 A');
      final b = _row('b', label: '环 B');
      final catalogs = <String, SubagentCatalog>{
        'root': SubagentCatalog.ready([a]),
        'a': SubagentCatalog.ready([b]),
        'b': SubagentCatalog.ready([a]), // b 的下级又指回 a
      };
      await tester.pumpWidget(
        _host(
          catalogs: catalogs,
          nodes: {
            'a': SubagentNode(row: a),
            'b': SubagentNode(row: b),
          },
        ),
      );

      await tester.tap(find.byTooltip('展开 环 A 的下级子智能体'));
      await tester.pump();
      await tester.tap(find.byTooltip('展开 环 B 的下级子智能体'));
      await tester.pump();

      // a 已在祖先链上 ⇒ 它那一行仍然画出来（数据如此，两处 label），
      // 但**只有根层那一个**还带着 disclosure（它正展开着，名字是"收起"）。
      expect(find.text('环 A'), findsNWidgets(2));
      expect(find.byTooltip('展开 环 A 的下级子智能体'), findsNothing);
      expect(
        find.byTooltip('收起 环 A 的下级子智能体'),
        findsOneWidget,
        reason: '祖先链上已有的行不再给展开能力（否则递归打穿栈）',
      );
    });

    testWidgets('收起连带收起整枝；再展开要重新读', (tester) async {
      final loaded = <String>[];
      final child = _row('child-1', label: '子级');
      final grand = _row('grand-1', label: '孙级');
      final great = _row('great-1', label: '曾孙级');
      final catalogs = <String, SubagentCatalog>{
        'root': SubagentCatalog.ready([child]),
        'child-1': SubagentCatalog.ready([grand]),
        'grand-1': SubagentCatalog.ready([great]),
      };
      await tester.pumpWidget(
        _host(
          catalogs: catalogs,
          nodes: {
            'child-1': SubagentNode(row: child),
            'grand-1': SubagentNode(row: grand),
            'great-1': SubagentNode(row: great),
          },
          loaded: loaded,
        ),
      );

      await tester.tap(find.byTooltip('展开 子级 的下级子智能体'));
      await tester.pump();
      await tester.tap(find.byTooltip('展开 孙级 的下级子智能体'));
      await tester.pump();
      expect(find.text('曾孙级'), findsOneWidget);
      expect(loaded, ['child-1', 'grand-1']);

      // 收起子级：整枝都收（Web `closeBranch`，`:556-568`）。
      await tester.tap(find.byTooltip('收起 子级 的下级子智能体'));
      await tester.pump();
      expect(find.text('孙级'), findsNothing);
      expect(find.text('曾孙级'), findsNothing);

      // 再展开：深层不该"突然又冒出来"，而且会重新读一次。
      await tester.tap(find.byTooltip('展开 子级 的下级子智能体'));
      await tester.pump();
      expect(find.text('孙级'), findsOneWidget);
      expect(find.text('曾孙级'), findsNothing);
      expect(loaded, ['child-1', 'grand-1', 'child-1']);
    });
  });
}
