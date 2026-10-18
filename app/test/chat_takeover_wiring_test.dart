/// 接管卡在**聊天页里的接线**（不是接管逻辑本身 —— 那是 `takeover_test.dart`）。
///
/// ## 为什么这一组放在 `test/` 而不是 `integration_test/`
///
/// 它验的是"接管卡接进了底部、且与输入栏共存"，那是**纯 widget 组装**，
/// 不需要平台插件。而 `integration_test/` 那一组（真机）里也有同一条 ——
/// 两边都留是因为它们的失败原因不同：
///
/// - 这一条：接线错了（比如忘了把 `TakeoverPanel` 放进 Column）；
/// - 真机那条：**点得中吗**（布局对了不等于能点中）。
///
/// 实测教训：模拟器在这台机器上跑 `integration_test` 时**反复崩**
///（进程直接消失，日志无异常），所以关键接线必须有单测兜底 ——
/// 否则"真机跑不起来"会等于"这条路径完全没验"。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/ui/dsh_composer.dart';
import 'package:dsh_mobile/ui/takeover.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

class _FakeClient implements SyncClient {
  @override
  ConnectionState get state => ConnectionState.idle;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Future<void> start() async {}

  @override
  Future<void> reconnect() => start();

  @override
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> close() async {}

  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();
  @override
  Future<void> subscribe(String sid, {required int since}) async {}
  @override
  Future<void> unsubscribe(String sid) async {}
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();
  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => throw const ProtocolException(ErrorCode.relayOffline, '测试里不连');
}

/// 权限链的假电脑：给真目录、真切换、真投影回读。
///
/// **为什么要单独一个**：`_FakeClient` 对一切都回 `relayOffline`，
/// 于是权限 sheet 只会说"拿不到目录"。而"切了权限档，接管队列真的跟着变"
/// 这条接线要**走完整条链**才验得到：目录 → sheet → `permission.switch`
/// → 电脑侧落新值 → 重读投影 → chip 与接管队列都变。
///
/// 形状照 DSH 的 base 配置（`packages/bundle/base/cordis.patch.yml:262-271`）：
/// 三个预设、`name` 没配所以 DSH 回显键本身（`optionOf`，`permission-presets/src/index.ts:389`）。
class _PermissionFakeClient implements SyncClient {
  /// 电脑侧的当前档位（切换后由本假身改它，模拟 DSH 落盘 + 投影更新）。
  String current = 'workspace-write';

  /// 收到过哪些切换（断言用）。
  final List<String> switched = <String>[];

  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Future<void> start() async {}

  @override
  Future<void> reconnect() => start();

  @override
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> close() async {}
  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();
  @override
  Future<void> subscribe(String sid, {required int since}) async {}
  @override
  Future<void> unsubscribe(String sid) async {}
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    switch (method) {
      case 'permission.catalog':
        final catalog = <String, Object?>{
          'available': true,
          'catalog': <String, Object?>{
            'options': <Object?>[
              <String, Object?>{'value': 'read-only', 'name': 'read-only'},
              <String, Object?>{
                'value': 'workspace-write',
                'name': 'workspace-write',
              },
              <String, Object?>{
                'value': 'danger-full-access',
                'name': 'danger-full-access',
                'description': 'Full file access without approval prompts.',
              },
            ],
            'defaultOptions': <Object?>[
              <String, Object?>{'value': 'read-only', 'name': 'read-only'},
              <String, Object?>{
                'value': 'workspace-write',
                'name': 'workspace-write',
              },
              <String, Object?>{
                'value': 'danger-full-access',
                'name': 'danger-full-access',
              },
            ],
            'defaultPreset': 'workspace-write',
          },
        };
        return catalog as T;
      case 'permission.switch':
        final preset = params['preset'];
        switched.add(preset is String ? preset : '');
        current = preset is String ? preset : current;
        final reply = <String, Object?>{
          'matched': true,
          'execution': <String, Object?>{
            'commandId': 'cmd-1-1',
            'result': <String, Object?>{
              'kind': 'success',
              'text': 'preset $preset',
            },
          },
        };
        return reply as T;
      case 'session.projections':
        final projections = <String, Object?>{
          'permissions': <String, Object?>{'currentValue': current},
        };
        return projections as T;
      default:
        throw const ProtocolException(ErrorCode.relayOffline, '测试里不连');
    }
  }
}

Future<void> _pumpChat(WidgetTester tester) async {
  final app = AppModel(client: _FakeClient());
  await tester.pumpWidget(
    MaterialApp(
      theme: DshTheme.dark(),
      home: ChatPage(
        app: app,
        paired: false,
        onOpenDrawer: () {},
        onNewSession: () {},
        drawer: const Drawer(child: SizedBox()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('看示例数据'));
  await tester.pumpAndSettle();
  // 需要一个当前会话，输入栏与统计条才活。
  await app.openSession('preview-1');
  await tester.pumpAndSettle();
}

/// 用权限假电脑起一页聊天（目录 / 切换 / 投影都真）。
Future<(AppModel, _PermissionFakeClient)> _pumpChatWithPermission(
  WidgetTester tester,
) async {
  final client = _PermissionFakeClient();
  final app = AppModel(client: client);
  await tester.pumpWidget(
    MaterialApp(
      theme: DshTheme.dark(),
      home: ChatPage(
        app: app,
        paired: false,
        onOpenDrawer: () {},
        onNewSession: () {},
        drawer: const Drawer(child: SizedBox()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('看示例数据'));
  await tester.pumpAndSettle();
  await app.openSession('preview-1');
  await tester.pumpAndSettle();
  // 目录随 `refreshSessions` 一起拉（与 `session.modelCatalog` 同一条纪律）。
  await app.refreshSessions();
  await tester.pumpAndSettle();
  return (app, client);
}

/// 走 `＋` 菜单 → "演示：接管输入栏"。
Future<void> _enqueueDemo(WidgetTester tester) async {
  await tester.tap(find.byTooltip('添加文件或调用指令'));
  await tester.pumpAndSettle();
  // **先滚到它再点**：菜单 6 项，最后一项在 320×640 上超出屏幕
  //（`tap` 会报 "would not hit test"）。
  await tester.ensureVisible(find.text('演示：接管输入栏'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('演示：接管输入栏'));
  await tester.pumpAndSettle();
}

/// 把浮在底部的 SnackBar 放完（默认 4 s 自动消失）。
///
/// 切换权限档成功后有一句 toast，而它**正盖在输入栏上方** ——
/// 不等它走掉，下一个 `tap('＋')` 会"would not hit test"。
/// 用 `pump(duration)` 推进假时钟，让那个计时器真的到点。
Future<void> _drainSnackBars(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('接管卡接进底部，且**输入栏仍在**（并排而不是替换）', (tester) async {
    await _pumpChat(tester);
    // 装之前：只有输入栏。
    expect(find.byType(TakeoverPanel), findsOneWidget);
    expect(find.text('等待确认计划'), findsNothing);

    await _enqueueDemo(tester);

    // 装之后：接管卡在，输入栏**也还在**。
    // 队首是**计划**（DSH 的优先级：计划 2 > 提问 1 > 审批 0，
    // `ui-user-questions/.../index.ts:372`）—— 演示三个都装了，先出计划。
    expect(find.text('等待确认计划'), findsOneWidget);
    expect(
      find.byType(DshComposer),
      findsOneWidget,
      reason: '接管卡与输入栏并排（手机上更省高度，且不会让用户以为输入框不见了）',
    );
    // 接管卡在输入栏**上方**。
    final card = tester.getRect(find.text('等待确认计划'));
    final composer = tester.getRect(find.byType(DshComposer));
    expect(
      card.bottom,
      lessThanOrEqualTo(composer.top + 1),
      reason: '接管卡该在输入栏上方',
    );
  });

  testWidgets('队列是瀑布：一次只出一个，顺序按 DSH 优先级(计划→提问→审批)', (tester) async {
    await _pumpChat(tester);
    await _enqueueDemo(tester);

    // ① 计划（优先级 2）。
    expect(find.text('等待确认计划'), findsOneWidget);
    expect(find.text('等待回答'), findsNothing, reason: '瀑布：一次只出一个');
    expect(find.text('等待审批'), findsNothing);

    await tester.tap(find.text('同意执行'));
    await tester.pumpAndSettle();

    // ② 提问（优先级 1）。
    expect(find.text('等待回答'), findsOneWidget);
    expect(find.text('等待确认计划'), findsNothing);
    // 推荐是独立徽标（不在标签里）。
    expect(find.text('推荐'), findsOneWidget);
    expect(find.textContaining('（推荐）'), findsNothing);

    // 未回答时提交无效。
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(find.text('等待回答'), findsOneWidget, reason: '没答就不该走');

    await tester.tap(find.text('先只拆资源束'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();

    // ③ 审批（优先级 0）。
    expect(find.text('等待审批'), findsOneWidget);
    await tester.tap(find.text('允许一次'));
    await tester.pumpAndSettle();

    // 三个都答完 → 接管卡消失，输入栏还在。
    expect(find.text('等待审批'), findsNothing);
    expect(find.byType(DshComposer), findsOneWidget);
  });

  testWidgets('完全权限下审批**不入队**（但提问与计划照常）', (tester) async {
    // §7.10：完全权限下审批不再逐次确认 —— 那是"已授权"的**结果**。
    // 这一条在接管层有用例，这里验的是**接线**：切了权限档，
    // 聊天页里的接管队列真的跟着变了。
    //
    // **走完整条链**（目录 → sheet → `permission.switch` → 电脑侧落值 →
    // 重读投影）：权限档的真值在电脑侧，手机不再持有本地副本，
    // 所以这条接线只能这样验。曾经这里点的是一个写死的三档枚举。
    final (app, client) = await _pumpChatWithPermission(tester);

    // 还没切：电脑侧说是 workspace-write。
    expect(find.byTooltip('工作区内可改'), findsOneWidget);

    // 走权限 sheet + 风险门切到完全权限。
    await tester.tap(find.byTooltip('工作区内可改'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完全权限'));
    await tester.pumpAndSettle();
    // 风险门：勾选 + 启用。
    await tester.tap(find.text('我已了解风险'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('启用'));
    await tester.pumpAndSettle();

    expect(client.switched, [
      'danger-full-access',
    ], reason: '切预设必须真的发到电脑侧，而不是只改本地字段');
    expect(
      app.permissionValue,
      'danger-full-access',
      reason: '当前档位来自 `permissions` 投影，切换后要重读',
    );
    expect(find.byTooltip('完全权限'), findsOneWidget);

    await _drainSnackBars(tester);
    await _enqueueDemo(tester);

    // 审批被跳过 ⇒ 队首是计划（优先级仍高于提问）。
    expect(find.text('等待审批'), findsNothing, reason: '完全权限下审批不该入队');
    expect(find.text('等待确认计划'), findsOneWidget);
  });

  testWidgets('收起接管卡：卡片消失但队列不减（可恢复）', (tester) async {
    await _pumpChat(tester);
    await _enqueueDemo(tester);
    expect(find.text('等待确认计划'), findsOneWidget);

    await tester.tap(find.byTooltip('收起'));
    await tester.pumpAndSettle();
    expect(find.text('等待确认计划'), findsNothing);
    expect(find.byType(DshComposer), findsOneWidget, reason: '输入栏该回来');
  });
}
