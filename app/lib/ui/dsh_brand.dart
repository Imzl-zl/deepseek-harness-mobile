/// DSH 的品牌徽标：**DSH 那枚鲸鱼图标**（白底圆角方 + 鲸鱼）。
///
/// 用在两处「这是 DSH 这个 App」的地方：
///
/// | 位置 | 尺寸 |
/// |---|---|
/// | 会话流里的「助手」头像（`AssistantHead`） | 26 |
/// | 侧边抽屉头部（logo + App 名） | 28 |
///
/// ## 为什么不用图标字体里的 `fishLogo`
///
/// `fishLogo` 是单色描边字形（新会话页的 headline 用它，因为 DSH Web 那里就是
/// 一枚线性 logo）。而 App 图标、启动器、助手头像要用的是**同一枚**实心鲸鱼位图 ——
/// 用户 2026-10-23：「助手头像也是 dsh 的图标啊」「侧边抽屉的图标还是之前的」。
///
/// 资产：`assets/brand/dsh-whale.png`（透明底鲸鱼，源
/// `D:\sudy\github\deepseek-harness\apps\desktop\resources\icon.png`；
/// 生成方式见 `.agents/notes/implemented/2026-10-23-app-name-and-icon-from-dsh.md`）。
library;

import 'package:flutter/widgets.dart';

import '../theme/dsh_colors.dart';

/// 鲸鱼位图的资产路径（启动图标是另一套 PNG，同源）。
const String kDshWhaleAsset = 'assets/brand/dsh-whale.png';

/// 徽标根节点的 key：测试用它断言"这一处用的是品牌图标"。
const Key kDshBrandMarkKey = Key('dsh-brand-mark');

/// 白底圆角方 + 鲸鱼。尺寸随 [size] 等比：圆角 `0.34×size`、内边距 `0.12×size`。
class DshBrandMark extends StatelessWidget {
  const DshBrandMark({super.key, this.size = 26});

  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Container(
      key: kDshBrandMarkKey,
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.12),
      decoration: BoxDecoration(
        // 图标本身就是白底（与启动图标同形）；浅色主题下靠这圈 hairline 分层，
        // 否则白底贴在浅色抽屉上会看不出边界。
        color: const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(size * 0.34),
        border: Border.all(color: c.layer1),
      ),
      child: Image.asset(
        kDshWhaleAsset,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}
