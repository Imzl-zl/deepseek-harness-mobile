/// 输入栏的模型 / 推理等级两枚 chip，以及抽屉的菜单层级。
///
/// 四条**用户当场指出**的规则：
/// 1. 「思考」chip 点了要有面板（之前 `onPickReasoning` 没接线，哪怕目录里有档位也不动）；
/// 2. 模型面板**只显示渠道 + 模型名**，不摆说明文字与"几档推理"；
/// 3. 新会话（blank / 首页）**不显示**「对话 / 轨迹」分段；
/// 4. 工作区是一级菜单（更大更重更深），会话行缩进。
library;

import 'dart:convert';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/ui/collapsible_group.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 过一遍 JSON：与线上解码后的类型一致（手写字面量的嵌套泛型会撞 `readObject`）。
Map<String, Object?> _wire(Object value) =>
    jsonDecode(jsonEncode(value)) as Map<String, Object?>;

Map<String, Object?> _catalog() => _wire({
  'available': true,
  'catalog': {
    'groups': [
      {
        'id': 'p',
        'name': '渠道 A',
        'models': [
          {
            'id': 'm1',
            'name': '模型一',
            'description': '这段说明不该出现在面板里',
            'reasoning': {
              'defaultEffort': 'high',
              'efforts': [
                {'id': 'high', 'name': '高', 'description': '档位说明也不该出现'},
                {'id': 'low', 'name': '低'},
              ],
            },
          },
        ],
      },
    ],
  },
});

class _PickerClient extends FakeSyncClient {
  _PickerClient({this.blank = false});

  final bool blank;
  final sent = <(String, Map<String, Object?>)>[];

  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> reconnect() => start();
  @override
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> unsubscribe(String sid) async {}

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    sent.add((method, params));
    switch (method) {
      case 'repo.info':
        return <String, Object?>{'protocol': 1, 'caps': <String, Object?>{}}
            as T;
      case 'session.modelCatalog':
        return _catalog() as T;
      case 'session.list':
        return <String, Object?>{
              'sessions': [
                {
                  'sid': 'sid_1',
                  'updatedAt': 1,
                  'running': false,
                  'blank': blank,
                  'subagent': false,
                  'model': {'provider': 'p', 'model': 'm1'},
                },
              ],
            }
            as T;
      case 'session.select-model':
        return <String, Object?>{
              'selected': {
                'provider': params['provider'],
                'model': params['model'],
                if (params['reasoningEffort'] != null)
                  'reasoningEffort': params['reasoningEffort'],
              },
            }
            as T;
    }
    return <String, Object?>{} as T;
  }
}

Future<AppModel> _seeded(_PickerClient client) async {
  final app = AppModel(client: client);
  addTearDown(app.dispose);
  await app.refreshRepoInfo();
  await app.refreshSessions();
  await app.openSession('sid_1');
  return app;
}

Future<void> _pump(WidgetTester tester, AppModel app) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: DshTheme.dark(),
      home: ChatPage(
        app: app,
        paired: true,
        onOpenDrawer: () {},
        onNewSession: () {},
        drawer: const Drawer(child: SizedBox(height: 200)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('「思考」chip 有面板：点它列出档位，选一档就发 select-model', (tester) async {
    final client = _PickerClient();
    final app = await _seeded(client);
    await _pump(tester, app);

    final chip = find.byKey(const Key('composer-reasoning'));
    expect(chip, findsOneWidget, reason: '目录里有档位时这枚 chip 要在');
    await tester.tap(chip);
    await tester.pumpAndSettle();

    expect(find.text('推理等级 · 模型一'), findsOneWidget);
    expect(find.text('高'), findsOneWidget);
    expect(find.text('低'), findsOneWidget);

    await tester.tap(find.text('低'));
    await tester.pumpAndSettle();

    final sent = client.sent.where((c) => c.$1 == 'session.select-model');
    expect(sent, hasLength(1));
    expect(sent.first.$2['reasoningEffort'], 'low');
  });

  testWidgets('模型面板只有渠道 + 模型名，不摆说明与档数', (tester) async {
    final client = _PickerClient();
    final app = await _seeded(client);
    await _pump(tester, app);

    await tester.tap(find.byKey(const Key('composer-model-chip')));
    await tester.pumpAndSettle();

    expect(find.text('渠道 A'), findsOneWidget, reason: '渠道是分组头');
    // 模型名两处出现：输入栏那枚 chip + 面板里的行 —— 面板里必须有一行。
    expect(find.text('模型一'), findsAtLeastNWidgets(2));
    expect(find.textContaining('这段说明不该出现在面板里'), findsNothing);
    expect(find.textContaining('档推理等级'), findsNothing);
  });

  testWidgets('新会话（blank）不显示「对话 / 轨迹」分段', (tester) async {
    final client = _PickerClient(blank: true);
    final app = await _seeded(client);
    await _pump(tester, app);

    expect(find.text('轨迹'), findsNothing);
    expect(find.text('对话'), findsNothing);
  });

  testWidgets('工作区是一级菜单：标题 13/w700，会话行缩进在它右边', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: Scaffold(
          body: CollapsibleGroup(
            label: 'dsh-mobile',
            expanded: true,
            onToggle: () {},
            childCount: 2,
            children: const [
              SizedBox(key: Key('row1'), height: 20),
              SizedBox(key: Key('row2'), height: 20),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final header = tester.widget<Text>(find.text('dsh-mobile'));
    expect(header.style?.fontSize, 13);
    expect(header.style?.fontWeight, FontWeight.w700);

    // 缩进用**几何**判：会话行比组本身窄（右边不缩、左边让出 indent）。
    final groupWidth = tester.getSize(find.byType(CollapsibleGroup)).width;
    expect(
      tester.getSize(find.byKey(const Key('row1'))).width,
      lessThanOrEqualTo(groupWidth - 14),
      reason: '会话行要缩进，层级才看得出来',
    );
    expect(tester.getTopLeft(find.byKey(const Key('row1'))).dx, 14);
  });
}
