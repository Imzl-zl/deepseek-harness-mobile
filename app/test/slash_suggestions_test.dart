/// `/` 候选菜单：**名单来自电脑侧**（`repo.info.commands`），手机不抄第二份。
///
/// ## 这一组守什么
///
/// 1. `slashQueryOf` 的判据：整段文本以 `/` 开头、且**还没出现空白**
///    （有空白 = 命令名打完了，后面在写参数）；正文中间的 `/` 不算。
/// 2. 候选**只**来自传进来的名单 —— 名单空（老连接器）就不出菜单，
///    而不是回落到手机里写死的 `/goal` `/plan`。
/// 3. 行是**列表行**（与 `@` 同一个形状）：分组标题 + 名字 + 右侧说明；
///    说明来自宿主命令定义（`repo.info.commands` 的对象形状），没有就不画那一列。
/// 4. 点一行 ⇒ 输入框变成 `/名字 `（带尾空格），菜单随即消失。
library;

import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/command.dart';
import 'package:dsh_mobile/model/permission.dart';
import 'package:dsh_mobile/model/send_mode.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/dsh_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 只回答 `repo.info` 的替身（`commands` 可定制，**两种形状都能发**）。
class _Client extends FakeSyncClient {
  _Client({required this.commands});

  /// 老连接器给 `['goal']`，新连接器给 `[{name, description}]`。
  final Object? commands;

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'repo.info') {
      return <String, Object?>{
            'protocol': 1,
            if (commands != null) 'commands': commands,
          }
          as T;
    }
    return <String, Object?>{} as T;
  }
}

Widget host(TextEditingController controller, List<SlashCommand> commands) =>
    MaterialApp(
      theme: DshTheme.dark(),
      home: Scaffold(
        body: DshComposer(
          controller: controller,
          attachments: const [],
          modelName: 'auto',
          reasoningLabel: null,
          access: const PermissionChip(
            icon: 'shield',
            label: '工作区',
            warn: false,
          ),
          sendMode: SendMode.queue,
          sending: false,
          slashCommands: commands,
          onSend: () {},
          onAttach: () {},
          onPickModel: () {},
          onPickAccess: () {},
          onRemoveAttachment: (_) {},
        ),
      ),
    );

const List<SlashCommand> _two = [
  SlashCommand(name: 'goal', description: 'Set or view the goal'),
  SlashCommand(name: 'plan'),
];

void main() {
  group('slashQueryOf（判据）', () {
    test('行首一个 `/` 且还没空白 ⇒ 查询串', () {
      expect(slashQueryOf('/'), '');
      expect(slashQueryOf('/g'), 'g');
      expect(slashQueryOf('/go'), 'go');
    });

    test('有空白 = 命令名打完了（后面是参数）⇒ 不查', () {
      expect(slashQueryOf('/goal '), isNull);
      expect(slashQueryOf('/goal 写个目标'), isNull);
    });

    test('正文中间的 `/` 不是命令 ⇒ 不查', () {
      expect(slashQueryOf('看一下 a/b'), isNull);
      expect(slashQueryOf(' /goal'), isNull);
    });
  });

  group('候选行（列表形状，不是胶囊）', () {
    testWidgets('打一个 `/` 就出两行 + 一个分组标题', (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(host(input, _two));
      expect(find.byKey(const ValueKey<String>('slash-goal')), findsNothing);

      input.text = '/';
      await tester.pump();

      expect(find.byKey(const ValueKey<String>('slash-goal')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('slash-plan')), findsOneWidget);
      // 分组标题是宿主 zh 词典的原话（`ui-input-trigger/src/client/locales.ts`
      // 的 `'command'`）—— 不是另起一个"命令"。
      expect(find.text(kSectionCommands), findsOneWidget);
    });

    testWidgets('说明右对齐在行尾；没有说明的那一行只占名字那一列', (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(host(input, _two));
      input.text = '/';
      await tester.pump();

      final goal = find.byKey(const ValueKey<String>('slash-goal'));
      final plan = find.byKey(const ValueKey<String>('slash-plan'));
      final desc = find.descendant(
        of: goal,
        matching: find.text('Set or view the goal'),
      );
      expect(desc, findsOneWidget);
      // 说明贴行尾（右对齐）：它的右边缘与「这一段没有说明」的行右边缘齐。
      final planRow = tester.getRect(plan);
      final descRect = tester.getRect(desc);
      expect(
        descRect.right,
        greaterThan(tester.getRect(goal).right - 60),
        reason: '说明该在行的右侧，不是紧贴名字',
      );
      // 没有说明的行不摆占位说明。
      expect(
        find.descendant(of: plan, matching: find.text('Set or view the goal')),
        findsNothing,
      );
      // 行是**左对齐的一列**：名字的起点在面板左侧（不是居中的胶囊）。
      final panel = tester.getRect(
        find.byKey(const ValueKey<String>('slash-panel')),
      );
      expect(tester.getRect(goal).left, lessThan(panel.center.dx));
      expect(
        planRow.width,
        greaterThan(panel.width - 20),
        reason: '行撑满面板宽度（列表行，不是胶囊）：只差面板自身的 4px 内边距',
      );
    });

    testWidgets('名单空（老连接器）⇒ 一枚都不出（不回落写死的名单）', (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(host(input, const []));
      input.text = '/';
      await tester.pump();
      expect(find.text('/goal'), findsNothing);
      expect(find.text('/plan'), findsNothing);
    });

    testWidgets('打 /p 过滤到一行', (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(host(input, _two));
      input.text = '/p';
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('slash-goal')), findsNothing);
      expect(find.byKey(const ValueKey<String>('slash-plan')), findsOneWidget);
    });

    testWidgets('点一行 ⇒ 输入框变 `/名字 `，菜单消失', (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(host(input, _two));
      input.text = '/g';
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey<String>('slash-goal')));
      await tester.pump();

      expect(input.text, '/goal ');
      expect(input.selection.baseOffset, input.text.length);
      expect(find.byKey(const ValueKey<String>('slash-goal')), findsNothing);
    });
  });

  group('名单从 repo.info 来（两种形状都收）', () {
    test('新连接器：`{name, description}` ⇒ 名字与说明都落进 slashCommands', () async {
      final app = AppModel(
        client: _Client(
          commands: const [
            {'name': 'goal', 'description': 'Set or view the goal'},
            {'name': 'plan'},
          ],
        ),
      );
      addTearDown(app.dispose);
      expect(app.slashCommands, isEmpty);
      await app.refreshRepoInfo();
      expect(app.slashCommands.map((c) => c.name), ['goal', 'plan']);
      expect(app.slashCommands.first.description, 'Set or view the goal');
      // 没给说明的那条是 **null**（不编一句话）。
      expect(app.slashCommands.last.description, isNull);
    });

    test(r"老连接器：`['goal','plan']` 仍然收（说明为空）", () async {
      final app = AppModel(client: _Client(commands: const ['goal', 'plan']));
      addTearDown(app.dispose);
      await app.refreshRepoInfo();
      expect(app.slashCommands.map((c) => c.name), ['goal', 'plan']);
      expect(app.slashCommands.every((c) => c.description == null), isTrue);
    });

    test('带前导 `/` 也认（连接器原样过线，两种写法都可能出现）', () {
      expect(parseSlashCommands(const ['/goal']).single.name, 'goal');
      expect(
        parseSlashCommands(const [
          {'name': '/plan'},
        ]).single.name,
        'plan',
      );
    });

    test('条目认不出就跳过（不编一个名字）', () {
      expect(
        parseSlashCommands(const [
          42,
          {'description': '没有名字'},
          '',
          {'name': 'goal', 'description': ''},
        ]).map((c) => c.name),
        ['goal'],
      );
      // 空说明视同没给。
      expect(
        parseSlashCommands(const [
          {'name': 'goal', 'description': ''},
        ]).single.description,
        isNull,
      );
    });

    test('老连接器不报这个键 ⇒ 空表（不是"没有命令可用"）', () async {
      final app = AppModel(client: _Client(commands: null));
      addTearDown(app.dispose);
      await app.refreshRepoInfo();
      expect(app.slashCommands, isEmpty);
    });
  });
}
