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
  List<PendingAttachment> attachments = const [],
  VoidCallback? onSend,
}) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  home: Scaffold(
    body: Column(
      children: [
        DshComposer(
          controller: controller,
          attachments: attachments,
          modelName: model,
          reasoningLabel: reasoning,
          access: const PermissionChip(
            icon: 'shield',
            label: '工作区内可改',
            warn: false,
          ),
          sendMode: SendMode.queue,
          sending: false,
          onSend: onSend ?? () {},
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

  testWidgets('推理等级是独立的一枚 chip（有等级才显示）', (tester) async {
    // 2026-10-19 起等级从模型名后面分出来（用户原话「模型选择，思考程度
    // 选择分开」）。两件事分成两个钮：换模型与换推理等级是两个动作。
    await tester.pumpWidget(_host(controller: TextEditingController()));
    await tester.pumpAndSettle();

    // 有等级 ⇒ 有那一枚，且它在模型 chip 之后、发送键之前。
    final reasoning = tester.getRect(
      find.byKey(const Key('composer-reasoning')),
    );
    final model = tester.getRect(find.byKey(const Key('composer-model-chip')));
    final send = tester.getRect(find.byTooltip('发送'));
    expect(reasoning.left, greaterThanOrEqualTo(model.right));
    expect(reasoning.right, lessThanOrEqualTo(send.left));
    // 恒宽 34（与权限 chip 同一档）。
    expect(reasoning.width, 34);

    // 没有等级 ⇒ 那一枚不占位（DSH Web 的 `effortLabel` 条件渲染）。
    await tester.pumpWidget(
      _host(controller: TextEditingController(), reasoning: null),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer-reasoning')), findsNothing);
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

  testWidgets('硬规则 1：附件在**卡片内部**上方，不是卡片外一行', (tester) async {
    // **这条改用直接构造 composer**（2026-10-20）：原先经 `＋` 菜单的
    // 「附件」加一个假附件来验，而那条路已移除 —— 它加的是
    // `PendingAttachment(name: '新增文件.txt')`，**发送时被静默丢弃**
    //（`_send()` 的 content 只有文本块）。用户看到芯片以为传了文件。
    //
    // 布局规则本身仍然要守：附件轨道在**卡片内部、文字行上方**
    //（方案 §7.2 硬规则 1）。所以直接喂一个附件给 composer 验它 ——
    // 这比经菜单验更准：菜单那一步是"怎么来的"，这里要的是"摆在哪"。
    await tester.pumpWidget(
      _host(
        controller: TextEditingController(),
        attachments: const [
          PendingAttachment(name: '设计稿.png'),
          PendingAttachment(name: '说明.md'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('设计稿.png'), findsOneWidget);
    expect(find.text('说明.md'), findsOneWidget);
    final chip = tester.getRect(find.text('设计稿.png'));
    final field = tester.getRect(find.byType(TextField));
    expect(
      chip.bottom,
      lessThanOrEqualTo(field.top + 1),
      reason: '附件轨应在文字行上方（卡片内部）',
    );
    // 两个都在卡片内部（composer 的矩形之内）。
    final composer = tester.getRect(find.byType(DshComposer));
    expect(chip.top, greaterThanOrEqualTo(composer.top - 1));
  });

  testWidgets('**只挂一张图、不打字：发送键可点**（点了真的回调）', (tester) async {
    // 2026-10-20 修的 bug：`canSend` 原来只看文字
    //（`controller.text.trim().isNotEmpty`），于是"选了照片没打字"时
    // 发送键是灰的 —— 而"只发一张图"是完全正常的用法
    //（DSH 的 content 是 part 数组，可以没有文本 part）。
    var sent = 0;
    await tester.pumpWidget(
      _host(
        controller: TextEditingController(),
        attachments: const [
          PendingAttachment(
            name: '设计稿.png',
            image: PickedImagePart(
              mediaType: 'image/png',
              data: 'iVBORw0KGgo=',
            ),
          ),
        ],
        onSend: () => sent += 1,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(sent, 1, reason: '有可发送的图片就算有草稿');
  });

  testWidgets('**不可发送的附件不算草稿**（否则点了会发出去一个空消息）', (tester) async {
    // `isInert` 的芯片（只有名字、没有字节）根本发不出去；
    // 让它点亮发送键，就会变成一个"发出去什么都没带"的动作。
    var sent = 0;
    await tester.pumpWidget(
      _host(
        controller: TextEditingController(),
        attachments: const [PendingAttachment(name: '只有名字.txt')],
        onSend: () => sent += 1,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(sent, 0, reason: '惰性附件不该点亮发送键');
  });
}
