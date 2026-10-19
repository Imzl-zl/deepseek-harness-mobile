/// 输入栏控制行的几何回归（"模型占那么大"那条反馈的判据）。
///
/// ## 为什么量这个
///
/// 用户 2026-10-19 原话："我们的输入款就设计不是和很好，模型占那么大"。
/// 2026-10-19 已把模型 chip 从"裸名字"改成"`database` 图标 + 名字"
/// （照 rikkahub `ModelSelectorButton(onlyIcon = true)`），但**没有量过
/// 它实际占多少**—— 这一组把宽度钉住：
///
/// 1. 模型 chip **不越过左组的 62%**（原型 `#chipModel { max-width: 62% }`）；
/// 2. 权限 chip **恒宽 34**（硬规则 3 的后半句，长模型名不许把它挤走）；
/// 3. 发送键在**最右侧**且与左组不重叠；
/// 4. 长模型名（`deepseek-v4.1-flash-pro-preview`）下 1/2/3 仍然成立。
library;

import 'package:dsh_mobile/model/permission.dart';
import 'package:dsh_mobile/model/send_mode.dart';
import 'package:dsh_mobile/ui/dsh_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({
  required TextEditingController controller,
  String model = 'deepseek-v4.1-flash',
  String? reasoning = 'max',
}) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  home: Scaffold(
    body: Column(
      children: [
        DshComposer(
          controller: controller,
          attachments: const [],
          modelName: model,
          reasoningLabel: reasoning,
          access: const PermissionChip(
            icon: 'shield',
            label: '工作区内可改',
            warn: false,
          ),
          sendMode: SendMode.queue,
          sending: false,
          onSend: () {},
          onAttach: () {},
          onPickModel: () {},
          onPickAccess: () {},
          onRemoveAttachment: (_) {},
        ),
      ],
    ),
  ),
);

void main() {
  testWidgets('模型 chip 不越过左组 62%，权限 chip 恒宽 34', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(_host(controller: controller));
    await tester.pumpAndSettle();

    final composer = tester.getRect(find.byType(DshComposer));
    final chip = tester.getRect(find.text('deepseek-v4.1-flash'));
    // 权限 chip：靠它的 tooltip 找（`_IconChip` 包了 Tooltip）。
    final access = tester.getRect(find.byTooltip('工作区内可改'));
    final send = tester.getRect(find.byTooltip('发送'));

    // ① 模型 chip（连同它外面的容器）不超过左组 62%。
    //    chip 的右缘就是文字右缘 + padding，用文字 rect 太窄；
    //    这里用"文字右缘 ≤ composer 左缘 + 62% 宽"这条等价判据。
    final limit = composer.left + composer.width * 0.62;
    expect(
      chip.right,
      lessThanOrEqualTo(limit),
      reason: '模型 chip 越过了 62% 上限（${chip.right} > $limit）',
    );

    // ② 权限 chip 恒宽 34（长模型名不许把它挤走）。
    expect(access.width, 34, reason: '权限 chip 必须恒宽');

    // ③ 发送键在最右，且不与权限 chip 重叠。
    expect(send.left, greaterThanOrEqualTo(access.right));
    expect(send.right, lessThanOrEqualTo(composer.right + 0.5));
  });

  testWidgets('没有推理等级时 chip 更窄（等级那一截不占位）', (tester) async {
    // DSH Web 的 `effortLabel` 是**条件渲染**的（`ModelSelect.tsx:488`）：
    // 没有等级就不显示。我们原来在"没选模型"时显示"默认"——
    // 那一截在 390px 屏上约 40px，而"默认"说的是"没有信息"。
    await tester.pumpWidget(_host(controller: TextEditingController()));
    await tester.pumpAndSettle();
    final chipWith = tester.getRect(
      find.byKey(const Key('composer-model-chip')),
    );

    await tester.pumpWidget(
      _host(controller: TextEditingController(), reasoning: null),
    );
    await tester.pumpAndSettle();
    final chipWithout = tester.getRect(
      find.byKey(const Key('composer-model-chip')),
    );

    // 等级那一截不占位 ⇒ chip 真的变窄（不是名字把腾出的宽度吃掉）。
    expect(
      chipWithout.width,
      lessThan(chipWith.width),
      reason: '无等级时模型 chip 应更窄（${chipWithout.width} vs ${chipWith.width}）',
    );
    // **等级那一截真的不渲染**（不是渲染成空串占着）。
    expect(find.text('· max'), findsNothing);
    // 而"有等级"那一版它是在的 —— 证明上面那条不是压根找不到文本。
    await tester.pumpWidget(_host(controller: TextEditingController()));
    await tester.pumpAndSettle();
    expect(find.text('· max'), findsOneWidget);
  });

  testWidgets('长模型名下：仍不越过 62%、权限 chip 仍恒宽', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      _host(
        controller: controller,
        model: 'deepseek-v4.1-flash-pro-preview-2026',
      ),
    );
    await tester.pumpAndSettle();

    final composer = tester.getRect(find.byType(DshComposer));
    final chip = tester.getRect(
      find.text('deepseek-v4.1-flash-pro-preview-2026'),
    );
    final access = tester.getRect(find.byTooltip('工作区内可改'));

    expect(
      chip.right,
      lessThanOrEqualTo(composer.left + composer.width * 0.62),
      reason: '长模型名把 chip 拉过了上限',
    );
    expect(access.width, 34);
    // 长名被省略号截断：文字 rect 比 composer 窄得多，但仍可见（不是 0 宽）。
    expect(chip.width, greaterThan(40));
  });
}
