/// `/` 候选菜单：**名单来自电脑侧**（`repo.info.commands`），手机不抄第二份。
///
/// ## 这一组守什么
///
/// 1. `slashQueryOf` 的判据：整段文本以 `/` 开头、且**还没出现空白**
///    （有空白 = 命令名打完了，后面在写参数）；正文中间的 `/` 不算。
/// 2. 候选**只**来自传进来的名单 —— 名单空（老连接器）就不出菜单，
///    而不是回落到手机里写死的 `/goal` `/plan`。
/// 3. 点一枚胶囊 ⇒ 输入框变成 `/名字 `（带尾空格），菜单随即消失。
library;

import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/permission.dart';
import 'package:dsh_mobile/model/send_mode.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/dsh_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 只回答 `repo.info` 的替身（`commands` 可定制）。
class _Client extends FakeSyncClient {
  _Client({required this.commands});

  final List<String>? commands;

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

Widget host(TextEditingController controller, List<String> commands) =>
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

  group('候选项', () {
    testWidgets('打一个 `/` 就出两枚（名单来自电脑侧）', (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(host(input, const ['goal', 'plan']));
      expect(find.byKey(const ValueKey<String>('slash-goal')), findsNothing);

      input.text = '/';
      await tester.pump();

      expect(find.byKey(const ValueKey<String>('slash-goal')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('slash-plan')), findsOneWidget);
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

    testWidgets('打 /p 过滤到一枚', (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(host(input, const ['goal', 'plan']));
      input.text = '/p';
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('slash-goal')), findsNothing);
      expect(find.byKey(const ValueKey<String>('slash-plan')), findsOneWidget);
    });

    testWidgets('点一枚 ⇒ 输入框变 `/名字 `，菜单消失', (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(host(input, const ['goal', 'plan']));
      input.text = '/g';
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey<String>('slash-goal')));
      await tester.pump();

      expect(input.text, '/goal ');
      expect(input.selection.baseOffset, input.text.length);
      expect(find.byKey(const ValueKey<String>('slash-goal')), findsNothing);
    });
  });

  group('名单从 repo.info 来', () {
    test('读到 commands ⇒ 落进 slashCommands', () async {
      final app = AppModel(client: _Client(commands: const ['goal', 'plan']));
      addTearDown(app.dispose);
      expect(app.slashCommands, isEmpty);
      await app.refreshRepoInfo();
      expect(app.slashCommands, ['goal', 'plan']);
    });

    test('老连接器不报这个键 ⇒ 空表（不是"没有命令可用"）', () async {
      final app = AppModel(client: _Client(commands: null));
      addTearDown(app.dispose);
      await app.refreshRepoInfo();
      expect(app.slashCommands, isEmpty);
    });
  });
}
