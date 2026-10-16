/// 顶栏下方那行计数 chip 的**排版回归**（换不换行、占几行）。
///
/// 2026-10-16 用户反馈："子智能体和后台任务也在最上面啊,非要换行吗?"
/// —— 当时的 `Row` 改成 `Wrap` 是为了防溢出（旧口径下子智能体的文案带
/// "，正在运行"，两枚两位数 chip 能到 380px+）。口径改回 DSH 之后文案变短
/// （子智能体只报总数、后台任务报在跑数），所以**常态应该是一行**：
/// 这条断言把"一行"钉住，溢出交给 `Wrap` 兜底（`takeException` 判据）。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

/// 只回介面需要的形状：会话行、子智能体投影、任务清单。
class _ChipsClient implements SyncClient {
  _ChipsClient({required this.subagents, required this.liveJobs});

  final int subagents;
  final int liveJobs;

  @override
  ConnectionState get state => ConnectionState.idle;

  @override
  Stream<ConnectionState> get connection => const Stream.empty();

  @override
  Future<void> start() async {}

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
      case 'session.list':
        return {
              'sessions': [
                {'sid': 's1', 'itemCount': 3, 'updatedAt': 1},
              ],
            }
            as T;
      case 'session.projections':
        return {
              'subagentCatalog': [
                for (var i = 0; i < subagents; i += 1)
                  {'id': 'sub-$i', 'createdAt': 1, 'mode': 'continuable'},
              ],
            }
            as T;
      case 'job.list':
        return {
              'jobs': [
                for (var i = 0; i < totalJobs; i += 1)
                  {
                    'id': 'j$i',
                    'kind': 'bash',
                    'label': 'flutter build apk --release $i',
                    'status': i < liveJobs ? 'running' : 'completed',
                    'startedAt': 1,
                  },
              ],
            }
            as T;
      default:
        return null as T;
    }
  }

  /// 任务总量：在跑的 + 4 条已结束（用来验证"报的是在跑数，不是总数"）。
  int get totalJobs => liveJobs + 4;
}

/// 在指定宽度下量那行 chip：返回两枚 chip 的 `top` 与宽度。
Future<({double subTop, double jobTop, double subWidth, double jobWidth})>
_measure(
  WidgetTester tester, {
  required double width,
  required int subagents,
  required int liveJobs,
}) async {
  final view = tester.view;
  view.physicalSize = Size(width, 844);
  view.devicePixelRatio = 1;
  addTearDown(() {
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  final client = _ChipsClient(subagents: subagents, liveJobs: liveJobs);
  final app = AppModel(client: client);
  await app.refreshSessions();
  await app.openSession('s1');
  await app.refreshJobs('s1');

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
  // **不能用 `pumpAndSettle`**：在跑的任务/chip 会画一枚永不结束的转圈点，
  // settle 会一直等下去（是超时，不是断言失败）。推进两帧就够量布局了。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));

  final sub = tester.getRect(find.text('$subagents 个子智能体'));
  final job = tester.getRect(find.text('$liveJobs 个后台任务运行中'));
  return (
    subTop: sub.top,
    jobTop: job.top,
    subWidth: sub.width,
    jobWidth: job.width,
  );
}

void main() {
  testWidgets('390px：两枚 chip 排在同一行（文案短了，不该再换行）', (tester) async {
    final m = await _measure(tester, width: 390, subagents: 3, liveJobs: 2);
    expect(m.subTop, equals(m.jobTop), reason: '同一行：两枚 chip 的 top 必须相等');
    expect(tester.takeException(), isNull, reason: '390px 下不许溢出');

    // 宽度账留在断言里：下次谁把文案改长，这里会先红。
    final total = m.subWidth + m.jobWidth;
    expect(
      total,
      lessThan(390 - 24 - 8),
      reason: '两枚 chip 的文字宽度加起来必须给 8px 间距与 24px 边距留出余量',
    );
  });

  testWidgets('360px：同样一行，且不溢出', (tester) async {
    final m = await _measure(tester, width: 360, subagents: 3, liveJobs: 2);
    expect(m.subTop, equals(m.jobTop));
    expect(tester.takeException(), isNull);
  });

  testWidgets('两位数计数 + 长文案极端情况：允许换行兜底，但不许溢出', (tester) async {
    // 12 个子智能体 + 12 个后台任务在跑：这时两枚 chip 一定放不下，
    // `Wrap` 会换成两行 —— 那是兜底，不是常态。
    final m = await _measure(tester, width: 360, subagents: 12, liveJobs: 12);
    expect(tester.takeException(), isNull, reason: '放不下也不许溢出');
    expect(m.subTop, isNot(equals(m.jobTop)), reason: '真的放不下时应当换行（而不是被裁掉一半）');
  });
}
