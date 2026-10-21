/// 会话抽屉的行动作与拖动排序（2026-10-21 用户问「左侧的会话可以折叠、移动吗」，
/// 当晚补一句「会话和工作区都可以拖拽换位置而不是弹框啊」）。
///
/// 守六件事：
///
/// 1. **行尾「…」开菜单**（长按自 2026-10-21 起是拖动，见第 5 条），不是删除
///    —— DSH 的会话面没有删除方法（`workspace-controller` 只有归档 / 取消归档 /
///    置顶 / 取消置顶）。
/// 2. 未置顶的行给「置顶会话」，已置顶的给「取消置顶」。
/// 3. 边界项（首条上移 / 末条下移）**保留在菜单里但不可点**，
///    避免菜单项在边界前后跳位。
/// 4. 「下移」传给数据层的锚点是**目标位的下一行**（`insertSessionBefore` 语义）。
/// 5. **拖动会话**：落在目标行的下半 ⇒ 插到它后面；跨置顶分区**不接受**。
/// 6. **拖动项目头**：落到另一个头的上半/下半 ⇒ 插到它前/后（`workspace.insertBefore`）。
library;

import 'package:dsh_mobile/ui/dsh_popover.dart';
import 'package:dsh_mobile/ui/session_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

DrawerSession row(String sid, {bool pinned = false}) => DrawerSession(
  sid: sid,
  title: sid.toUpperCase(),
  preview: '预览',
  timeLabel: '10:00',
  isPinned: pinned,
);

Widget host(SessionDrawer drawer) => MaterialApp(home: Scaffold(body: drawer));

/// 开一行的「…」菜单（2026-10-21 起长按是拖动，菜单在行尾那枚按钮上）。
Future<void> openMenu(WidgetTester tester, String sid) async {
  await tester.tap(find.byKey(ValueKey<String>('session-menu-$sid')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('「…」菜单（未置顶行）：置顶 / 上移 / 下移 / 归档', (tester) async {
    DrawerSession? pinnedSession;
    DrawerSession? archived;
    String? movedTo;
    await tester.pumpWidget(
      host(
        SessionDrawer(
          sections: [
            DrawerSection(
              label: 'dsh-mobile',
              // 真工作区 ⇒ 组内上下移可用（`workspace.insertSessionBefore` 要它）。
              workspaceId: 'w1',
              sessions: [row('a', pinned: true), row('b')],
            ),
          ],
          connection: const DrawerConnection(
            name: '我的电脑',
            detail: '已连接',
            platform: 'DSH',
            online: true,
          ),
          footItems: const [],
          onNewSession: () {},
          onOpenSession: (_) {},
          onClose: () {},
          onPin: (session) => pinnedSession = session,
          onMove: (session, beforeSid) => movedTo = beforeSid,
          onArchive: (session) => archived = session,
        ),
      ),
    );

    await openMenu(tester, 'b');

    expect(find.text('置顶会话'), findsOneWidget);
    expect(find.text('取消置顶'), findsNothing);
    expect(find.text('上移'), findsOneWidget);
    expect(find.text('下移'), findsOneWidget);

    // B 是最后一条：下移不可点。菜单不关，说明点了也不会发生任何事。
    await tester.tap(find.text('下移'));
    await tester.pumpAndSettle();
    expect(movedTo, isNull);
    expect(find.text('下移'), findsOneWidget);

    // 上移可点：B 的上一条是置顶的 A，但 B 是普通行 —— 跨分区，同样不可点。
    await tester.tap(find.text('上移'));
    await tester.pumpAndSettle();
    expect(movedTo, isNull, reason: '普通行不能跨过置顶块');

    await tester.tap(find.text('置顶会话'));
    await tester.pumpAndSettle();
    expect(pinnedSession?.sid, 'b');

    // 再开一次，归档走同一条菜单。
    await openMenu(tester, 'b');
    await tester.tap(find.text('归档'));
    await tester.pumpAndSettle();
    expect(archived?.sid, 'b');
  });

  testWidgets('「…」菜单（已置顶行）：取消置顶，下移到置顶块末尾时锚点是普通块首条', (tester) async {
    DrawerSession? unpinned;
    String? movedTo;
    await tester.pumpWidget(
      host(
        SessionDrawer(
          sections: [
            DrawerSection(
              label: 'dsh-mobile',
              workspaceId: 'w1',
              // 显示顺序已经是置顶在前（数据层分区），抽屉只照显示顺序算邻位。
              sessions: [
                row('a', pinned: true),
                row('b', pinned: true),
                row('c', pinned: true),
                row('d'),
              ],
            ),
          ],
          connection: const DrawerConnection(
            name: '我的电脑',
            detail: '已连接',
            platform: 'DSH',
            online: true,
          ),
          footItems: const [],
          onNewSession: () {},
          onOpenSession: (_) {},
          onClose: () {},
          onUnpin: (session) => unpinned = session,
          onMove: (session, beforeSid) => movedTo = beforeSid,
        ),
      ),
    );

    await openMenu(tester, 'b');
    expect(find.text('取消置顶'), findsOneWidget);
    await tester.tap(find.text('下移'));
    await tester.pumpAndSettle();
    expect(movedTo, 'd', reason: 'B 下移到 C 之后、普通块 D 之前 = 落在置顶块末尾');

    await openMenu(tester, 'b');
    await tester.tap(find.text('取消置顶'));
    await tester.pumpAndSettle();
    expect(unpinned?.sid, 'b');
  });

  testWidgets('「未分组」这类兜底桶：上移/下移留着但不可点（没有 workspaceId）', (tester) async {
    String? movedTo;
    await tester.pumpWidget(
      host(
        SessionDrawer(
          sections: [
            DrawerSection(
              label: '未分组',
              // 兜底桶：会话不属于任何工作区 ⇒ 发不出
              // `workspace.insertSessionBefore`（它要求 workspaceId）。
              sessions: [row('a'), row('b'), row('c')],
            ),
          ],
          connection: const DrawerConnection(
            name: '我的电脑',
            detail: '已连接',
            platform: 'DSH',
            online: true,
          ),
          footItems: const [],
          onNewSession: () {},
          onOpenSession: (_) {},
          onClose: () {},
          onMove: (session, beforeSid) => movedTo = beforeSid,
        ),
      ),
    );

    // B 在中间：如果按"普通行"算，上移与下移都可点。
    await openMenu(tester, 'b');
    expect(find.text('上移'), findsOneWidget, reason: '菜单项不隐藏，只变灰');
    expect(find.text('下移'), findsOneWidget);

    await tester.tap(find.text('上移'));
    await tester.pumpAndSettle();
    expect(movedTo, isNull, reason: '兜底桶不能重排');
    expect(find.text('上移'), findsOneWidget, reason: '不可点时点了不会关菜单');

    await tester.tap(find.text('下移'));
    await tester.pumpAndSettle();
    expect(movedTo, isNull);
  });

  testWidgets('「…」菜单锚在**那一行**下面（跟手判据）', (tester) async {
    await tester.pumpWidget(
      host(
        SessionDrawer(
          sections: [
            DrawerSection(
              label: 'dsh-mobile',
              workspaceId: 'w1',
              sessions: [row('a'), row('b'), row('c')],
            ),
          ],
          connection: const DrawerConnection(
            name: '我的电脑',
            detail: '已连接',
            platform: 'DSH',
            online: true,
          ),
          footItems: const [],
          onNewSession: () {},
          onOpenSession: (_) {},
          onClose: () {},
        ),
      ),
    );

    final rowRect = tester.getRect(find.text('B'));
    await openMenu(tester, 'b');

    final panel = tester.getRect(find.byKey(popoverPanelKey));
    expect(
      panel.top - rowRect.bottom,
      lessThan(80),
      reason: '菜单要长在被长按的那一行下面（底部 sheet 会差出一整屏）',
    );
    expect(
      (panel.left - rowRect.left).abs(),
      lessThan(80),
      reason: '水平方向也要落在那一行这一侧',
    );
  });

  /// 长按起手 + 拖到 [to]（`kLongPressTimeout` 之后才算拖动）。
  Future<void> dragTo(WidgetTester tester, Offset from, Offset to) async {
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('拖动会话到目标行下半：锚点是那一行的下一行', (tester) async {
    String? movedTo;
    var calls = 0;
    await tester.pumpWidget(
      host(
        SessionDrawer(
          sections: [
            DrawerSection(
              label: 'w',
              workspaceId: 'w1',
              sessions: [row('a'), row('b'), row('c')],
            ),
          ],
          connection: const DrawerConnection(
            name: '我的电脑',
            detail: '已连接',
            platform: 'DSH',
            online: true,
          ),
          footItems: const [],
          onNewSession: () {},
          onOpenSession: (_) {},
          onClose: () {},
          onMove: (session, beforeSid) {
            calls += 1;
            movedTo = beforeSid;
          },
        ),
      ),
    );

    final a = tester.getRect(find.text('A'));
    // 落点用**行**的中心，不是标题文字的中心：标题在行的上半，用它算会判成上半。
    // 行尾「…」是 36×36 且垂直居中，它的中心就是行的垂直中心。
    final rowCenterY = tester
        .getCenter(find.byKey(const ValueKey<String>('session-menu-a')))
        .dy;
    await dragTo(
      tester,
      tester.getCenter(find.text('C')),
      Offset(a.center.dx, rowCenterY + 8),
    );

    expect(calls, 1, reason: '拖到 A 的下半 ⇒ 一次移动');
    expect(movedTo, 'b', reason: '落在 A 之后 = 插到 B 之前（Host 的 insertBefore 语义）');
  });

  testWidgets('跨置顶分区拖动：不接受，不发请求', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        SessionDrawer(
          sections: [
            DrawerSection(
              label: 'w',
              workspaceId: 'w1',
              sessions: [row('a', pinned: true), row('b')],
            ),
          ],
          connection: const DrawerConnection(
            name: '我的电脑',
            detail: '已连接',
            platform: 'DSH',
            online: true,
          ),
          footItems: const [],
          onNewSession: () {},
          onOpenSession: (_) {},
          onClose: () {},
          onMove: (session, beforeSid) => calls += 1,
        ),
      ),
    );

    final a = tester.getRect(find.text('A'));
    await dragTo(
      tester,
      tester.getCenter(find.text('B')),
      Offset(a.center.dx, a.top + 4),
    );

    expect(calls, 0, reason: '普通行不能越过置顶块（Web 的 drag.pinned === node.pinned）');
  });

  testWidgets('拖动项目头到另一个头上半：插到它前面', (tester) async {
    String? movedWorkspace;
    String? beforeWorkspace;
    DrawerSection section(String id, String label) =>
        DrawerSection(label: label, workspaceId: id, sessions: [row('$id-s')]);
    await tester.pumpWidget(
      host(
        SessionDrawer(
          sections: [
            section('w1', 'W1'),
            section('w2', 'W2'),
            section('w3', 'W3'),
          ],
          connection: const DrawerConnection(
            name: '我的电脑',
            detail: '已连接',
            platform: 'DSH',
            online: true,
          ),
          footItems: const [],
          onNewSession: () {},
          onOpenSession: (_) {},
          onClose: () {},
          onMoveWorkspace: (workspaceId, beforeWorkspaceId) {
            movedWorkspace = workspaceId;
            beforeWorkspace = beforeWorkspaceId;
          },
        ),
      ),
    );

    final w1 = tester.getRect(find.text('W1'));
    await dragTo(
      tester,
      tester.getCenter(find.text('W3')),
      Offset(w1.center.dx, w1.top + 4),
    );

    expect(movedWorkspace, 'w3');
    expect(beforeWorkspace, 'w1', reason: '落在 W1 的上半 ⇒ 插到 W1 前面');
  });
}
