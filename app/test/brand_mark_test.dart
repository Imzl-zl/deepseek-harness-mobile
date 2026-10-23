/// 品牌图：**DSH 那枚鲸鱼**（白底圆角方 + 鲸鱼位图）。
///
/// ## 这一组守什么
///
/// 用户 2026-10-23 连提两次：
///
/// - 「助手头像也是 dsh 的图标啊」
/// - 「我看侧边抽屉的图标还是之前的啊？看看全部显示图标的位置吧」
///
/// 也就是"凡是品牌位（助手头像、抽屉头部 logo）都用同一枚图标"。
/// 这两处以前各画一个**蓝紫渐变方块 + `sparkle` 字形** —— 那是我们自己的装饰。
///
/// 判据（机械）：
///
/// 1. [DshBrandMark] 里是 `assets/brand/dsh-whale.png`（不是字形、不是别的图）；
/// 2. 抽屉头部真的用了它，且 App 名是 `DeepSeek Harness`；
/// 3. 「助手」头像真的用了它。
library;

import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_turns.dart';
import 'package:dsh_mobile/ui/dsh_brand.dart';
import 'package:dsh_mobile/ui/session_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(body: Center(child: child)),
);

/// 徽标里的那枚位图（找不到就返回 null）。
AssetImage? _brandImage(WidgetTester tester) {
  final mark = find.byKey(kDshBrandMarkKey);
  if (mark.evaluate().isEmpty) return null;
  final image = tester.widget<Image>(
    find.descendant(of: mark.first, matching: find.byType(Image)),
  );
  final provider = image.image;
  return provider is AssetImage ? provider : null;
}

void main() {
  testWidgets('徽标 = 鲸鱼位图（不是图标字形）', (tester) async {
    await tester.pumpWidget(_host(const DshBrandMark(size: 26)));
    await tester.pumpAndSettle();
    expect(_brandImage(tester)?.assetName, kDshWhaleAsset);
  });

  testWidgets('抽屉头部：logo 用同一枚鲸鱼，App 名是 DeepSeek Harness', (tester) async {
    await tester.pumpWidget(
      _host(
        SessionDrawer(
          sections: const [],
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
    await tester.pumpAndSettle();

    expect(find.text('DeepSeek Harness'), findsOneWidget);
    expect(
      _brandImage(tester)?.assetName,
      kDshWhaleAsset,
      reason: '抽屉头部那枚 logo 必须是 DSH 的图标（用户：还是之前的）',
    );
    // 旧的装饰性字形不该再出现在头部（它已随渐变方块一起删掉）。
    expect(
      find.descendant(
        of: find.byKey(kDshBrandMarkKey).first,
        matching: find.byType(Icon),
      ),
      findsNothing,
    );
  });

  testWidgets('助手头像用同一枚鲸鱼', (tester) async {
    await tester.pumpWidget(_host(const AssistantHead()));
    await tester.pumpAndSettle();
    expect(_brandImage(tester)?.assetName, kDshWhaleAsset);
  });
}
