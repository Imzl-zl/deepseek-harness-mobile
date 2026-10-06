/// 底部 sheet 体系（`ui/dsh_sheet.dart`）的回归。
///
/// 照 `mock/proto` 的 `openSheet` 与 `sheet-*` action。
///
/// ## 这一组守三条硬规则（都是文档里写死的）
///
/// 1. **§7.9 的行结构**：`[名称 / 其下标签组] [勾位(恒占位)]` ——
///    能力标签**不做同行第三列**、勾位**不是"选中才渲染"**。
///    原型有 `verify-picker.mjs` 断言"切换选中前后 `nameRight`/`ckLeft` 不变"。
/// 2. **§7.10 的授权边界**：未勾"我已了解风险"时点启用**绝不生效**。
/// 3. sheet 里的行**可点**（面板缺 `Material` 祖先时点击会直接失败 ——
///    那个 bug 在右抽屉上踩过一次，这里用"点得动"来钉住）。
library;

import 'package:dsh_mobile/theme/dsh_colors.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/dsh_sheet.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(body: child),
);

void main() {
  group('§7.9 选择类列表的行结构', () {
    testWidgets('勾位**恒占位**：选中与不选中时，名称右边界不动', (tester) async {
      // 这是 §7.9 的核心断言（原型 `verify-picker.mjs` 也测这个）。
      // "选中才渲染勾"会让整行文字在选中瞬间横移。
      Future<double> nameRightOf(bool selected) async {
        await tester.pumpWidget(
          _wrap(
            DshPickerRow(
              name: 'claude-opus',
              tags: const ['图片', '工具'],
              selected: selected,
              onTap: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        return tester.getRect(find.text('claude-opus')).right;
      }

      final off = await nameRightOf(false);
      final on = await nameRightOf(true);
      expect(off, closeTo(on, 0.01), reason: '勾位必须恒占位 —— 否则选中时名称列宽变化，整行横移');
    });

    testWidgets('能力标签在**名称下面第二行**，不是同行第三列', (tester) async {
      await tester.pumpWidget(
        _wrap(
          DshPickerRow(
            name: 'claude-opus',
            tags: const ['图片', '工具'],
            selected: true,
            onTap: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final name = tester.getRect(find.text('claude-opus'));
      final tag = tester.getRect(find.text('图片'));
      // 标签在名称**下方**（top 更大）。
      expect(
        tag.top,
        greaterThanOrEqualTo(name.bottom - 1),
        reason: '标签该在名称下面第二行 —— 同行会与勾位互相顶',
      );
    });

    testWidgets('点得动（缺 Material 祖先时点击会失败）', (tester) async {
      // 右抽屉上踩过 `No Material widget found`：面板是裸 Container，
      // 里面的 InkWell 点不动，而单测不点它就不会暴露。
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          Material(
            color: DshColors.layer1,
            child: DshPickerRow(
              name: 'x',
              selected: false,
              onTap: () => taps += 1,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('x'));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('没有标签时不渲染空行（不留一段空白）', (tester) async {
      await tester.pumpWidget(
        _wrap(DshPickerRow(name: 'x', selected: false, onTap: () {})),
      );
      await tester.pumpAndSettle();
      final name = tester.getRect(find.text('x'));
      // 单行高度应在 20 上下（不是"名称 + 空标签行"的 40+）。
      expect(name.height, lessThan(30));
    });
  });

  group('统计 sheet 的三件（照原型 sheet-*）', () {
    testWidgets('会话统计 / Token 用量 / 上下文 三个标题各自对', (tester) async {
      for (final (title, body) in [
        ('会话统计', const DshKeyValue(label: '模型用时', value: '12.4', unit: 's')),
        ('Token 用量', const DshKeyValue(label: '缓存命中', value: '0%')),
        (
          '上下文已用 2%',
          const DshContextMeter(
            systemTokens: 7200,
            toolTokens: 10100,
            messageTokens: 2600,
            limitTokens: 1000000,
          ),
        ),
      ]) {
        await tester.pumpWidget(
          _wrap(
            Builder(
              builder: (context) => TextButton(
                onPressed: () => showDshSheet<void>(
                  context: context,
                  title: title,
                  body: body,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text(title), findsOneWidget, reason: '标题该是「$title」');

        // **每轮要关掉**：sheet 是路由级的，不关的话下一轮会在旧 sheet
        // 还开着时重建宿主 —— 第一版因此找不到第二个标题
        //（报"Found 0 widgets with text Token 用量"）。
        Navigator.of(tester.element(find.text('open'))).pop();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('上下文用量条：三段之和与上限算出百分比', (tester) async {
      const meter = DshContextMeter(
        systemTokens: 7200,
        toolTokens: 10100,
        messageTokens: 2600,
        limitTokens: 1000000,
      );
      expect(meter.usedTokens, 19900);
      // 19900 / 1000000 = 1.99% → 四舍五入 2%。
      expect(meter.percent, 2);
    });

    testWidgets('token 数按 `19.9K / 1M` 那样缩写（不是裸数字）', (tester) async {
      const meter = DshContextMeter(
        systemTokens: 7200,
        toolTokens: 10100,
        messageTokens: 2600,
        limitTokens: 1000000,
      );
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showDshSheet<void>(
                context: context,
                title: '上下文已用 ${meter.percent}%',
                body: meter,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // 三段各自的缩写 + 已用/上限。
      expect(find.text('7.2K'), findsOneWidget);
      expect(find.text('10.1K'), findsOneWidget);
      expect(find.text('2.6K'), findsOneWidget);
      expect(find.text('19.9K / 1M'), findsOneWidget);
    });
  });

  group('§7.10 授权边界（未授权绝不生效）', () {
    /// 一个带风险门的宿主（复刻 `chat_page` 里那条路径）。
    Widget host({required void Function(String) onEnabled}) => _wrap(
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            var acked = false;
            await showDshSheet<void>(
              context: context,
              title: '启用完全权限？',
              body: StatefulBuilder(
                builder: (context, setSheetState) => Row(
                  children: [
                    Checkbox(
                      value: acked,
                      onChanged: (v) => setSheetState(() => acked = v ?? false),
                    ),
                    // **标签也可点**（生产里这一行外层包了 `InkWell`）——
                    // 只让那个小方块可点会让靶子太小。测试宿主也照做，
                    // 否则测的就不是生产那条路径。
                    Expanded(
                      child: InkWell(
                        onTap: () => setSheetState(() => acked = !acked),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text('我已了解风险'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                DshSheetAction(
                  label: '取消',
                  onPressed: () => Navigator.of(context).pop(),
                ),
                DshSheetAction(
                  label: '启用',
                  filled: true,
                  onPressed: () {
                    if (!acked) return; // **没勾就不生效**
                    onEnabled('fullAccess');
                    Navigator.of(context).pop();
                  },
                ),
              ],
            );
          },
          child: const Text('open'),
        ),
      ),
    );

    testWidgets('不勾就点启用 → **权限不变**、门仍开着', (tester) async {
      final applied = <String>[];
      await tester.pumpWidget(host(onEnabled: applied.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('启用'));
      await tester.pumpAndSettle();

      expect(applied, isEmpty, reason: '未勾选时点启用绝不生效');
      // 门**仍开着**（没被误关）。
      expect(find.text('启用完全权限？'), findsOneWidget);
    });

    testWidgets('勾选后点取消 → 权限不变', (tester) async {
      final applied = <String>[];
      await tester.pumpWidget(host(onEnabled: applied.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('我已了解风险'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(applied, isEmpty, reason: '勾了但取消，权限不该变');
    });

    testWidgets('勾选 + 启用 → 才生效', (tester) async {
      final applied = <String>[];
      await tester.pumpWidget(host(onEnabled: applied.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('我已了解风险'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('启用'));
      await tester.pumpAndSettle();

      expect(applied, ['fullAccess']);
    });

    testWidgets('关掉后**重开**：勾选态不残留，点启用仍无效', (tester) async {
      // §7.10 表格里的那一条。它是这个门最容易被写错的地方 ——
      // 用外层的 `_riskAcked` 字段时，上一次的勾会留下来。
      final applied = <String>[];
      await tester.pumpWidget(host(onEnabled: applied.add));
      await tester.pumpAndSettle();

      // 第一次：勾上再取消。
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我已了解风险'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      // 第二次重开：直接点启用（不勾）。
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('启用'));
      await tester.pumpAndSettle();

      expect(applied, isEmpty, reason: '勾选态不该跨次残留');
    });
  });
}
