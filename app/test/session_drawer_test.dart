/// 会话抽屉的长按菜单（2026-10-21 用户问「左侧的会话可以折叠、移动吗」）。
///
/// 守四件事：
///
/// 1. **长按开菜单**，不是删除 —— DSH 的会话面没有删除方法
///    （`workspace-controller` 只有归档 / 取消归档 / 置顶 / 取消置顶）。
/// 2. 未置顶的行给「置顶会话」，已置顶的给「取消置顶」。
/// 3. 边界项（首条上移 / 末条下移）**保留在菜单里但不可点**，
///    避免菜单项在边界前后跳位。
/// 4. 「下移」传给数据层的锚点是**目标位的下一行**（`insertSessionBefore` 语义）。
library;

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

void main() {
  testWidgets('长按未置顶行：菜单给置顶 / 上移 / 下移 / 归档', (tester) async {
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

    await tester.longPress(find.text('B'));
    await tester.pumpAndSettle();

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
    await tester.longPress(find.text('B'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('归档'));
    await tester.pumpAndSettle();
    expect(archived?.sid, 'b');
  });

  testWidgets('长按已置顶行：给「取消置顶」，下移到置顶块末尾时锚点是普通块首条', (tester) async {
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

    await tester.longPress(find.text('B'));
    await tester.pumpAndSettle();
    expect(find.text('取消置顶'), findsOneWidget);
    await tester.tap(find.text('下移'));
    await tester.pumpAndSettle();
    expect(movedTo, 'd', reason: 'B 下移到 C 之后、普通块 D 之前 = 落在置顶块末尾');

    await tester.longPress(find.text('B'));
    await tester.pumpAndSettle();
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
    await tester.longPress(find.text('B'));
    await tester.pumpAndSettle();
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
}
