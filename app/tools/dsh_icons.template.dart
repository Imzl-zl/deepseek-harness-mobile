// GENERATED FILE - DO NOT EDIT BY HAND.
//
// DSH 图标集（手机端）。**由 mock/proto/icons.js 机生成** —— 与原型同一份来源，
// 所以两边定义上不可能漂移。
//
// 生成：`node app/tools/extract-dsh-icons-dart.mjs`
// 上游：`mock/proto/icons.js`（由 `node mock/proto/tools/extract-dsh-icons.mjs` 从 DSH 源抽）
// DSH 源（只读）：
//   packages/client/ui-primitives/src/icons/index.tsx
//   packages/client/ui-primitives/src/icons/shared-artwork.tsx
//   packages/client/ui-primitives/src/PermissionIcon.tsx
// 抽取日期：@@DATE@@  图标数：@@COUNT@@
//
// **不要手改下面的 SVG 载荷**：DSH 升级后重跑抽取器再 diff。
//
// ## 为什么用 SVG 串渲染，而不是图标字体（IconData）
//
// 图标字体只能表达"单色实心字形"，而这套图标里有三样它表达不了的东西，
// 而它们在 DSH 里都是有意义的视觉区分：
//
// - **`<mask>`**：`archiveOff` 的斜杠是挖空出来的 —— 去掉它就是另一个图标了；
// - **`opacity`**：`compact` / `folderOpen` 靠同色两层叠加出层次；
// - **描边 + 填充混合**：同一个图标里两种都有（250 个 `<path>` 里大部分是描边）。
//
// ## 为什么颜色在这里字符串替换，而不是让 SVG 用 `currentColor`
//
// 所有图标**全部**用 `currentColor`，而 `flutter_svg` 对它支持有已知缺口
// （flutter/flutter#158680、dnfield/flutter_svg#31）。
// 与其赌渲染器行为，不如在**编译期**就换成真实色值：
// 代价是一次字符串替换，收益是"颜色一定生效"这件事不再依赖第三方实现细节。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 一个图标的原始数据。
class _IconArt {
  const _IconArt(this.defaultSize, this.aspect, this.template);

  /// DSH artwork 自己画布上的默认宽度（16 居多，也有 14/12/10/20/8）。
  final double defaultSize;

  /// 高 / 宽。**绝大多数是 1，但 `treeCorner` 是 8×10** ——
  /// 一律按正方形画会把它拉变形。
  final double aspect;

  /// SVG 模板。占位符：`_sizeToken` / `_strokeToken` / `_colorToken`。
  final String template;
}

const String _sizeToken = '@@SIZETOKEN@@';
const String _strokeToken = '@@SWTOKEN@@';
const String _colorToken = '@@COLORTOKEN@@';

/// DSH 图标的常规描边宽（DSH 侧常量 `ICON_REGULAR_STROKE`）。
const double _regularStroke = 1;

const Map<String, _IconArt> _art = <String, _IconArt>{
@@ART@@
};

/// DSH 图标集：全部图标的**唯一**来源（与原型同一份）。
///
/// 用法：
/// ```dart
/// DshIcon(DshIcons.refresh, color: DshColors.labelSecondary)
/// ```
abstract final class DshIcons {
  /// 全部图标名（升序，与 `mock/proto/icons.js` 的 `names` 相同）。
  static const List<String> names = <String>[
@@NAMES@@
  ];

  /// 某个图标的默认宽度（DSH artwork 自己画布上的值）。
  static double defaultSizeOf(String name) {
    final art = _art[name];
    if (art == null) {
      assert(false, 'unknown DSH icon: $name');
      return 16;
    }
    return art.defaultSize;
  }

  /// 某个图标的高 / 宽比（绝大多数是 1）。
  static double aspectOf(String name) => _art[name]?.aspect ?? 1;

  /// 渲染成 SVG 串（尺寸与颜色已填好）。
  static String svg(String name, {double? size, required Color color}) {
    final art = _art[name];
    if (art == null) {
      assert(false, 'unknown DSH icon: $name');
      // release 下给一个空 SVG 而不是抛异常：画不出图标不该让整屏崩掉。
      return '<svg viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg"></svg>';
    }
    final hex =
        '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    return art.template
        .split(_sizeToken)
        // 整数不写成 `32.0`：SVG 接受两者，但 `32.0` 会让人读断言时困惑
        //（第一版测试写 `width="32"` 就因为它没通过 —— 那是**测试与产物不一致**，
        //  不是产物错；这里统一成最短形式，让两边都自然）。
        .join(_formatNumber(size ?? art.defaultSize))
        .split(_strokeToken)
        .join(_formatNumber(_regularStroke))
        .split(_colorToken)
        .join(hex);
  }

  /// 数字的最短写法：整数不带小数点（`32`），小数去掉尾随零（`1.3`）。
  static String _formatNumber(double value) {
    if (value == value.roundToDouble()) return value.toInt().toString();
    return value.toString();
  }

  /// 是否认识这个图标名（测试与"清单校验"用）。
  ///
  /// 名字拼错时 `DshIcon` 在 debug 下会断言 —— 但那要等它被构建到。
  /// 这个函数给"清单级"校验用：遍历一份用到的名字，一次问完。
  static bool has(String name) => _art.containsKey(name);
}

/// 一个 DSH 图标。
///
/// 它只负责"把一个 DSH 图标画出来"，**不负责"什么时候用哪个"** ——
/// 选哪个图标是各屏的事，而名字必须来自 [DshIcons.names]。
class DshIcon extends StatelessWidget {
  const DshIcon(this.name, {super.key, this.size, required this.color});

  /// 图标名（必须是 [DshIcons.names] 里的一员）。
  final String name;

  /// 边长；`null` 时用该图标在 DSH artwork 里的默认值。
  final double? size;

  /// 颜色。**不在这里做主题查找** —— 由调用方从 `DshColors` 取名，
  /// 于是"这个图标该是什么颜色"在每一屏都看得见。
  final Color color;

  @override
  Widget build(BuildContext context) {
    final edge = size ?? DshIcons.defaultSizeOf(name);
    // 非正方形图标（`treeCorner` 8×10）按比例给高度 —— 一律正方形会拉变形。
    final height = edge * DshIcons.aspectOf(name);
    return SizedBox(
      width: edge,
      height: height,
      child: SvgPicture.string(
        DshIcons.svg(name, size: edge, color: color),
        width: edge,
        height: height,
        // 颜色已在 SVG 串里定死，所以这里**不做** colorFilter 着色
        //（做两遍会让"到底哪个生效"变成一个要读源码才能回答的问题）。
        fit: BoxFit.contain,
      ),
    );
  }
}
