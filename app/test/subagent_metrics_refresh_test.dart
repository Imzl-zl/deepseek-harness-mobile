/// 真机缺陷回归（2026-10-21）：**打开子智能体面板必须现拉一次 `session.list`**。
///
/// ## 缺陷现场
///
/// 子智能体面板一行里的标题、`running`、时长、token 全部来自**子会话自己**的
/// `session.list` 行（`projections.values`），而那一包只在**连上 / 建会话**时拉过
/// （`AppModel.refreshSessions` 的两个调用点）。子会话是父会话**回合里**才出现的，
/// 于是真机上打开面板看到的是「当前未运行 + 没有 token + 没有时长」——
/// 杀掉 App 重连才变对（那次重连会重拉清单）。
///
/// 这一份钉的是**触发点**：面板真的被看见的那一刻要再拉一次。只钉
/// `AppModel.refreshSessionMetrics()` 本身不够 —— 少的是"谁来调它"。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/ui/dsh_app_bar.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 第一次 `session.list`（连上那一刻）里**还没有子会话**；
/// 之后的行里子会话跑完了，带着 timing / token / title。
class _FreshnessClient extends FakeSyncClient {
  int listCalls = 0;

  /// 会话事件流：测试自己往里推（回合结束那条判据要它）。
  final deltas = StreamController<SessionDelta>.broadcast();

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
  Future<void> close() async {
    await deltas.close();
  }

  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();
  @override
  Future<void> unsubscribe(String sid) async {}
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => deltas.stream;

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    switch (method) {
      case 'session.list':
        listCalls += 1;
        return {
              'sessions': [
                {'sid': 'sid_A', 'updatedAt': 1, 'blank': false},
                if (listCalls > 1) ...[
                  {
                    'sid': 'child-1',
                    'updatedAt': 2,
                    'subagent': true,
                    'running': false,
                    'projections': {
                      'kind': 'cached',
                      'asOfSeq': 9,
                      'values': {
                        'title': 'Reply with the current date',
                        'subagentTiming': {
                          'settledMs': 102000,
                          'lastTurnCompleted': true,
                        },
                        'tokenUsage': {
                          'uncachedInputTokens': 21588,
                          'outputTokens': 1548,
                          'cacheReadTokens': 0,
                          'cacheWriteTokens': 0,
                        },
                      },
                    },
                  },
                ],
              ],
            }
            as T;
      case 'session.projections':
        // 目录里**一直**有这个子级：它来自父会话的 `subagentCatalog` 投影，
        // 与清单行是两条来路（这正是"目录有、指标空"能同时成立的原因）。
        return {
              'subagentCatalog': [
                {
                  'id': 'child-1',
                  'createdAt': 1,
                  'mode': 'continuable',
                  'label': 'Reply with current date',
                },
              ],
            }
            as T;
      default:
        return null as T;
    }
  }
}

void main() {
  testWidgets('顶栏 chip → 子智能体面板：打开时重拉清单，行上才有真实时长与 token', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final client = _FreshnessClient();
    final app = AppModel(client: client);
    await app.refreshSessions();
    await app.openSession('sid_A');
    expect(client.listCalls, 1, reason: '连上那一刻只拉过一次');

    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: ChatPage(
          app: app,
          onOpenDrawer: () {},
          onNewSession: () {},
          onOpenSession: (_) {},
          drawer: const Drawer(child: SizedBox()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 打开面板之前：行里没有指标（真机上这就是"当前未运行、没有 token"）。
    expect(find.textContaining('1分42秒'), findsNothing);

    // 点 chip = 打开右抽屉并落在子智能体页。
    await tester.tap(find.byType(DshCountChip).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      client.listCalls,
      greaterThan(1),
      reason: '打开面板必须重拉 `session.list`（否则指标永远是连上那一刻的）',
    );
    expect(
      find.textContaining('已完成'),
      findsOneWidget,
      reason: '跑完的子会话要显示「已完成」，不是「正在运行」',
    );
    expect(
      find.textContaining('1分42秒'),
      findsOneWidget,
      reason: '时长来自子会话自己的 `subagentTiming.settledMs`（102 s）',
    );
    expect(
      find.textContaining('23.1K tok'),
      findsOneWidget,
      reason: 'token 来自子会话自己的 `tokenUsage`（21588 + 1548）',
    );
    app.dispose();
  });

  test('回合结束也重拉一次会话行（顶栏 running 与行指标都靠它）', () async {
    // 2026-10-21 真机：派了新子智能体之后，顶栏**计数**跟着目录变了（2 → 3），
    // 而 `running` 一直是 0 —— 因为行还是连上那一刻那一包，新子会话根本不在里面。
    // 子会话是在回合里出现的，所以"回合结束"是补这一次的天然边界。
    final client = _FreshnessClient();
    final app = AppModel(client: client);
    await app.refreshSessions();
    await app.openSession('sid_A');
    expect(client.listCalls, 1);
    // 目录里有一个子级（否则这条补拉没有信息量，代码会跳过）。
    expect(app.subagentCatalogOf('sid_A').entries, hasLength(1));

    client.deltas.add(
      SessionDelta(
        sid: 'sid_A',
        transient: const {},
        events: [
          SessionEvent(
            itemId: 'turn:1',
            type: 'turn/end',
            seq: 10,
            time: 10,
            data: const {'turn': 1},
          ),
        ],
      ),
    );
    // 让流回调跑完（`_onDelta` 是同步的，补拉是 `unawaited`）。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      client.listCalls,
      greaterThan(1),
      reason: '回合结束要重拉 `session.list`，否则顶栏永远不显示"正在运行"',
    );
    app.dispose();
  });

  test('没有 turn/end 的批次不补拉（普通消息不该带来一次 list）', () async {
    final client = _FreshnessClient();
    final app = AppModel(client: client);
    await app.refreshSessions();
    await app.openSession('sid_A');
    expect(client.listCalls, 1);

    client.deltas.add(
      SessionDelta(
        sid: 'sid_A',
        transient: const {},
        events: [
          SessionEvent(
            itemId: 'i:u1',
            type: 'user/message',
            seq: 11,
            time: 11,
            data: const {
              'content': [
                {'type': 'text', 'text': '你好'},
              ],
            },
          ),
        ],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(client.listCalls, 1, reason: '只有回合结束才需要补拉');
    app.dispose();
  });
}
