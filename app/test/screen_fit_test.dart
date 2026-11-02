/// **屏占比 / 尺寸适配**：常见三档长宽比下，抽屉与会话行都不该溢出，且抽屉要占满屏。
///
/// 用户原话：「还要考虑手机屏占比的问题」。可机械判定的只有两条：
///
/// 1. **不溢出**：`RenderFlex overflowed` 在 widget 测试里是抛出来的异常 ——
///    不接住就等于用例通过，所以这里显式 `takeException()` 断言为空。
/// 2. **不吃掉屏幕**：抽屉是整屏高的面板，它的高度必须等于屏幕可用高度
///    （被安全区/内边距切掉一块，就是"屏占比"被白吃掉）。
///
/// 三档取真机常见值：
/// - `360×640`（16:9，小屏/旧机，最容易挤爆的一档）
/// - `412×915`（20:9，当前主流）
/// - `390×844`（19.5:9，iPhone 一档）
library;

import 'package:dsh_mobile/model/session_dot.dart';
import 'package:dsh_mobile/ui/session_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

DrawerSession _row(String sid, {SessionDot dot = SessionDot.idle}) =>
    DrawerSession(
      sid: sid,
      title: '一个不算短但也不该换三行的会话标题 $sid',
      preview: '预览正文一行，够长到能顶到右边',
      timeLabel: '10:00',
      isPinned: false,
      dot: dot,
    );

/// 抽屉在真机上是**定宽面板**（`Drawer` 默认 304dp），不是整屏宽的 body ——
/// 拿 body 铺满整屏会得到一条harness 自己的横向溢出，与产品无关。
const double kDrawerWidth = 304;

Widget _host(SessionDrawer drawer) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(width: kDrawerWidth, child: drawer),
    ),
  ),
);

SessionDrawer _drawer() => SessionDrawer(
  sections: [
    DrawerSection(
      label: 'dsh-mobile',
      workspaceId: 'w1',
      sessions: [
        _row('a', dot: SessionDot.warning),
        _row('b', dot: SessionDot.ongoing),
        _row('c', dot: SessionDot.done),
        _row('d'),
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
  onPin: (_) {},
  onMove: (_, _) {},
  onArchive: (_) {},
);

void main() {
  for (final size in const [Size(360, 640), Size(412, 915), Size(390, 844)]) {
    testWidgets('抽屉在 ${size.width.toInt()}×${size.height.toInt()} 下不溢出、占满屏', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_host(_drawer()));
      // **不用 pumpAndSettle**：运行中那一行有个循环转圈动画，settle 永远不会到。
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull, reason: '任何 RenderFlex 溢出都算失败');

      // 抽屉占满屏幕高度（屏占比：不该被内边距/安全区白吃一截）。
      final drawer = tester.getSize(find.byType(SessionDrawer));
      expect(drawer.height, size.height, reason: '抽屉是整屏高的面板');
      expect(drawer.width, kDrawerWidth, reason: '抽屉是定宽面板');

      // 四行都在屏内（没有"第一行被顶出屏幕"那种溢出式布局）。
      for (final sid in ['a', 'b', 'c', 'd']) {
        final row = find.textContaining(sid);
        expect(row, findsWidgets, reason: '第 $sid 行渲染出来了');
      }
    });
  }
}
