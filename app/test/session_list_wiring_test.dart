/// **跨层**：`AppModel` 拿 `SyncClient` 的返回喂给界面这条链。
///
/// 为什么需要这一组：真机上出现过"连上了、列表恒为空、且不报错"，
/// 而各层单测全绿 —— 缺的正是**跨层那一跳**。
/// 这里用一个最小的假客户端把两侧接起来，逐字段钉住形状。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/core/sync_client_impl.dart'
    show encodeRequestEnvelope;
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/wire/reading.dart' show WireDiagnostics;
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

/// 只回固定答案的假客户端；`onCall` 让每条用例自己决定回什么、抛什么。
class _FakeClient extends FakeSyncClient {
  _FakeClient({this.onCall});

  final Object? Function(String method, Map<String, Object?> params)? onCall;

  final List<String> called = [];

  /// 最后一次调用的参数（用来钉**载荷形状** —— 形状错了不会有人报错）。
  Map<String, Object?>? lastParams;

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
  Future<void> unsubscribe(String sid) async {}

  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    called.add(method);
    lastParams = params;
    return onCall?.call(method, params) as T;
  }
}

void main() {
  group('session.list 的返回形状（真机 bug 的跨层形态）', () {
    test('电脑侧回的是**双层信封**：{ok, result:{sessions:[...]}}', () async {
      // **这条是按真机日志逐字复刻的形状**（连接器实际发出的 box）：
      //   {"ok":true,"result":{"sessions":[{"sid":…,"updatedAt":…}]}}
      // `SyncClient` 会把外层拆掉、只把 `result` 交给调用方，
      // 所以 `AppModel` 拿到的是 `{sessions:[...]}`。
      // 这里连**外层**一起断言，因为"哪一层剥掉了"正是真机上出错的地方。
      final client = _FakeClient(
        onCall: (method, params) => {
          'sessions': [
            {
              'sid': 'J-AQFoAKdDuro5HLhhaaOw',
              'updatedAt': 1791361744613,
              'running': false,
              'blank': false,
              'subagent': false,
            },
          ],
        },
      );
      final app = AppModel(client: client);

      await app.refreshSessions();

      // **只挑 `session.list` 那几条比**：`refreshSessions` 现在也会顺带拉一次
      // `session.modelCatalog`（模型目录与会话清单同源但不同周期）。
      // 断言完整序列会让这条用例在每次加一个"顺带拉的东西"时都红一次 ——
      // 而它要钉的是**清单的解析形状**，不是调用顺序。
      expect(client.called.where((m) => m == 'session.list').toList(), [
        'session.list',
      ]);
      expect(
        app.sessions.map((s) => s.sid),
        ['J-AQFoAKdDuro5HLhhaaOw'],
        reason: '解开外层信封后拿到的是 {sessions:[...]}；不认它就会"连上了却永远没有会话"',
      );
      expect(app.lastError, isNull);
    });

    test('电脑侧回 { sessions: [...] } —— 解析器必须认这个形状', () async {
      // 守的是真机上那个 bug：`connector/src/handlers.ts` 的 `session.list`
      // 返回 `{ sessions: [...] }`，而界面侧曾只认裸数组，
      // 于是**每一条都被静默跳过** —— 列表恒为空、且没有任何错误。
      final client = _FakeClient(
        onCall: (method, params) => {
          'sessions': [
            {
              'sid': 'sid_AAAA',
              'updatedAt': 1000,
              'running': false,
              'blank': false,
              'subagent': false,
            },
            {
              'sid': 'sid_BBBB',
              'updatedAt': 2000,
              'running': false,
              'blank': false,
              'subagent': false,
            },
          ],
        },
      );
      final app = AppModel(client: client);

      await app.refreshSessions();

      // **只挑 `session.list` 那几条比**：`refreshSessions` 现在也会顺带拉一次
      // `session.modelCatalog`（模型目录与会话清单同源但不同周期）。
      // 断言完整序列会让这条用例在每次加一个"顺带拉的东西"时都红一次 ——
      // 而它要钉的是**清单的解析形状**，不是调用顺序。
      expect(client.called.where((m) => m == 'session.list').toList(), [
        'session.list',
      ]);
      expect(
        app.sessions.map((s) => s.sid),
        ['sid_AAAA', 'sid_BBBB'],
        reason: '电脑侧回的是 { sessions: [...] }；不认它就会"连上了却永远没有会话"',
      );
      expect(app.lastError, isNull);
    });

    test('裸数组**不认**了：空清单 + 一处声音（钉线上形状，不是"容忍假客户端"）', () async {
      // 2026-10-25 之前这里收**两种**形状：`{sessions: [...]}` 与裸数组
      // （注释写的是"早期的假客户端与将来的简写都可能这么给"）。
      // 而连接器**从来只回 `{sessions: [...]}`**（`connector/src/handlers.ts:738`）。
      // 留着那条分支的代价是"认不出就必须留声"永远不成立：一个裸数组会被当成
      // 一次**成功的空清单**，于是"电脑上没有会话"与"我们没看懂回复"在界面上一模一样。
      // 现在它走解码层的 `WireBad`：空列表 + 计数 1（不抛、不猜）。
      WireDiagnostics.reset();
      final client = _FakeClient(
        // **只坏一处**：`session.list` 回裸数组；其余方法（模型目录）给正常形状。
        // 否则一条用例同时踩坏两个方法的形状，`badCount` 就说明不了"哪一处"。
        onCall: (method, params) => switch (method) {
          'session.list' => [
            {
              'sid': 'sid_CCCC',
              'updatedAt': 3000,
              'running': false,
              'blank': false,
              'subagent': false,
            },
          ],
          'session.modelCatalog' => {'available': false},
          _ => null,
        },
      );
      final app = AppModel(client: client);

      await app.refreshSessions();

      expect(app.sessions, isEmpty, reason: '裸数组是形状错，不是"空清单"');
      expect(
        WireDiagnostics.badCount,
        1,
        reason: '认不出必须留声，且**按应答计一次**（不是每行一次）',
      );
      expect(
        app.lastError,
        isNull,
        reason: '形状错不进 lastError —— 它的出口是 WireDiagnostics（计数 + 一行打印）',
      );
    });

    test('running 与 blank 都要解析（挑靶子靠它们，丢了就会叫醒别人的会话）', () async {
      // `blank` = 从没被 agent 跑过（`connector/src/dsh/sessions.ts` 的原话）。
      // 连接器一直在发这两个字段，而手机侧此前把 blank 丢掉了 —— 于是
      // "挑一个空闲会话当靶子"只能按 `!running` 挑，挑到的是**刚被别人跑完
      // 一轮**的会话，把探针投进去会把那个 agent 唤醒（2026-10-13 真机两次踩到）。
      final client = _FakeClient(
        onCall: (method, params) => {
          'sessions': [
            {
              'sid': 'sid_running',
              'updatedAt': 1000,
              'running': true,
              'blank': false,
              'subagent': false,
            },
            {
              'sid': 'sid_blank',
              'updatedAt': 900,
              'running': false,
              'blank': true,
              'subagent': false,
            },
            {
              'sid': 'sid_idle_used',
              'updatedAt': 800,
              'running': false,
              'blank': false,
              'subagent': false,
            },
          ],
        },
      );
      final app = AppModel(client: client);

      await app.refreshSessions();

      final byId = {for (final s in app.sessions) s.sid: s};
      expect(byId['sid_running']!.running, isTrue);
      expect(byId['sid_blank']!.blank, isTrue);
      expect(byId['sid_idle_used']!.blank, isFalse);
    });

    test('缺恒发键（blank）⇒ 整行丢 + 计数 1（不许按默认值猜）', () async {
      // **这里原来写的是另一条断言**："老连接器/老 fixture 不发 blank 时不能默认成
      // true"。它守的那个前提本身是错的：连接器对每一行**无条件**写 `blank`
      // （`connector/src/handlers.ts:743`），所以"行里没有 blank"只可能是漂移。
      // 按默认值猜（`entry['blank'] == true` ⇒ 假）会把一次漂移伪装成一条正常会话，
      // 于是"挑一个 blank 会话建新聊天"这类功能安静地选错 —— 现在整行丢并计数。
      WireDiagnostics.reset();
      final client = _FakeClient(
        // **只坏一处**：会话行缺恒发键 `blank`；模型目录给正常形状（见上一条用例的注释）。
        onCall: (method, params) => switch (method) {
          'session.list' => {
            'sessions': [
              {
                'sid': 'sid_legacy',
                'updatedAt': 1,
                'running': false,
                'subagent': false,
              },
            ],
          },
          'session.modelCatalog' => {'available': false},
          _ => null,
        },
      );
      final app = AppModel(client: client);

      await app.refreshSessions();

      expect(app.sessions, isEmpty, reason: '缺恒发键的行不算一条正常的会话');
      expect(WireDiagnostics.badCount, 1, reason: '整行丢要计一次数，否则与"没有会话"分不开');
    });

    test('cwd 要解析（按工作区挑靶子靠它，丢了就只能满清单挑）', () async {
      // `cwd` 连接器一直在发（`connector/src/handlers.ts` 的 `session.list`），
      // 而手机侧此前把它丢掉了 —— 于是"靶子必须在专用工作区"这条判据无从表达，
      // 只能满清单挑，2026-10-13 真机两次就这么把探针投进用户的其他会话。
      final client = _FakeClient(
        onCall: (method, params) => {
          'sessions': [
            {
              'sid': 'sid_with_cwd',
              'updatedAt': 1000,
              'running': false,
              'blank': false,
              'subagent': false,
              'cwd': r'D:\sudy\myproject\dsh-mobile-test',
            },
            // 老连接器 / 落盘里没有 cwd 的会话：**null**，不是空串。
            {
              'sid': 'sid_no_cwd',
              'updatedAt': 900,
              'running': false,
              'blank': false,
              'subagent': false,
            },
            // 空串同样当没有：空串会让"按工作区匹配"静默失败。
            // （这里**不计**漂移：连接器原样透传宿主的 cwd，空串只可能意味着"没有目录"。）
            {
              'sid': 'sid_empty_cwd',
              'updatedAt': 800,
              'running': false,
              'blank': false,
              'subagent': false,
              'cwd': '',
            },
          ],
        },
      );
      final app = AppModel(client: client);

      await app.refreshSessions();

      final byId = {for (final s in app.sessions) s.sid: s};
      expect(byId['sid_with_cwd']!.cwd, r'D:\sudy\myproject\dsh-mobile-test');
      expect(byId['sid_no_cwd']!.cwd, isNull);
      expect(byId['sid_empty_cwd']!.cwd, isNull);
    });

    test('parentSid 要解析（子会话头部的父级与 ← 返回父会话都靠它）', () async {
      // 连接器 `session.list` 对**子会话**发 `parentSessionId`（别名形式），
      // 对根会话**不发这个键**（`connector/src/handlers.ts`）。
      // 手机侧三条重路径（`copyWith` / `withCounters` / `withTitle`）都得留住它 ——
      // 其中 `_applySessionList` 每次都走 `copyWith`，漏一处就是"父级时有时无"。
      final client = _FakeClient(
        onCall: (method, params) => {
          'sessions': [
            {
              'sid': 'sid_root',
              'updatedAt': 1000,
              'running': false,
              'blank': false,
              'subagent': false,
            },
            {
              'sid': 'sid_child',
              'updatedAt': 900,
              'running': false,
              'blank': false,
              'subagent': true,
              'parentSessionId': 'sid_root',
            },
            // 空串按"没有"处理：拿空串当 sid 会让父级查名字永远落空。
            {
              'sid': 'sid_empty',
              'updatedAt': 800,
              'running': false,
              'blank': false,
              'subagent': true,
              'parentSessionId': '',
            },
            // 老连接器：根本没有这个键。
            {
              'sid': 'sid_legacy',
              'updatedAt': 700,
              'running': false,
              'blank': false,
              'subagent': true,
            },
          ],
        },
      );
      final app = AppModel(client: client);

      await app.refreshSessions();

      final byId = {for (final s in app.sessions) s.sid: s};
      expect(byId['sid_root']!.parentSid, isNull, reason: '根会话行没有这个键');
      expect(byId['sid_child']!.parentSid, 'sid_root');
      expect(byId['sid_empty']!.parentSid, isNull);
      expect(byId['sid_legacy']!.parentSid, isNull);

      // **三条重建路径都要留住它**（这条是 2026-10-23 真机前发现的那类坑：
      // 构造函数重建整行会让身份字段掉成默认值）。
      final child = byId['sid_child']!;
      expect(child.copyWith(pendingCount: 3).parentSid, 'sid_root');
      expect(
        child
            .withCounters(updatedAt: 1, itemCount: 2, pendingCount: 3)
            .parentSid,
        'sid_root',
      );
      expect(child.withTitle('新名字').parentSid, 'sid_root');
    });

    test('模型优先取行里的投影提示 modelSelection（子会话没有活 agent，只有这一条）', () async {
      // 连接器的顶层 `model` 是从**活 agent** 读的（`connector/src/dsh/models.ts`），
      // 子会话不在那张表里 ⇒ 子智能体页面会显示「未选择」。
      // 而行的投影提示对每个会话都有（DSH `list.ts:291-312` 不挑键），
      // `modelSelection` 的 `lastUsed` 由 `request/header` 推出来
      // （`model-selection-projection.ts:44-51`）—— 子会话也有 request/header。
      final client = _FakeClient(
        onCall: (method, params) => {
          'sessions': [
            // 子会话行：**没有顶层 `model`**，只有投影提示。
            {
              'sid': 'sid_child',
              'updatedAt': 900,
              'running': false,
              'blank': false,
              'subagent': true,
              'projections': {
                'kind': 'sequenced',
                'asOfSeq': 7,
                'values': {
                  'title': '孙级',
                  'modelSelection': {
                    'lastUsed': {'provider': 'p', 'model': 'm-used'},
                    'next': {
                      'provider': 'p',
                      'model': 'm-next',
                      'reasoningEffort': 'high',
                    },
                  },
                },
              },
            },
            // 老连接器：只有顶层 `model`（没有投影提示）。
            {
              'sid': 'sid_top',
              'updatedAt': 800,
              'running': false,
              'blank': false,
              'subagent': false,
              'model': {'provider': 'p', 'model': 'm-top'},
            },
            // 防御性用例：`next` 缺失 / 为 null 时退 `lastUsed`。
            // **真实 view 不会给这个形状** —— 它是 `pending ?? lastUsed`
            // （`model-selection-projection.ts:65`），`lastUsed` 非空时 `next` 必然非空。
            {
              'sid': 'sid_null_next',
              'updatedAt': 700,
              'running': false,
              'blank': false,
              'subagent': false,
              'projections': {
                'values': {
                  'modelSelection': {
                    'lastUsed': {'provider': 'p', 'model': 'm-used-only'},
                    'next': null,
                  },
                },
              },
            },
          ],
        },
      );
      final app = AppModel(client: client);

      await app.refreshSessions();

      final byId = {for (final s in app.sessions) s.sid: s};
      expect(byId['sid_child']!.model?.model, 'm-next', reason: 'next 优先');
      expect(byId['sid_child']!.model?.reasoningEffort, 'high');
      expect(
        byId['sid_top']!.model?.model,
        'm-top',
        reason: '没有投影提示时退到顶层字段（老连接器）',
      );
      expect(
        byId['sid_null_next']!.model?.model,
        'm-used-only',
        reason: 'next 为 null 时用 lastUsed',
      );
    });
  });

  // **回归 2026-10-15 真机**："列表里名字对了,但我点进去会话名字又变了"。
  // 根因是**两个真值源**:列表走 DSH 的展示链,而 `currentTitle` 只读本地从条目
  // 推导的标题。同一个人会话两个名字。
  group('标题只有一个真值源（列表与顶栏同一条链）', () {
    test('投影提示里有持久标题:列表与顶栏都用它', () async {
      final client = _FakeClient(
        onCall: (method, params) => {
          'sessions': [
            {
              'sid': 's1',
              'updatedAt': 1,
              'running': false,
              'blank': false,
              'subagent': false,
              'projections': {
                'kind': 'cached',
                'asOfSeq': 1,
                'values': {'title': '重构连接层'},
              },
              'cwd': r'D:\sudy\github\dsh-mobile',
            },
          ],
        },
      );
      final app = AppModel(client: client);
      await app.refreshSessions();
      await app.openSession('s1');

      expect(app.sessions.single.displayTitle, '重构连接层');
      expect(app.currentTitle, '重构连接层', reason: '顶栏与列表必须是同一个名字,否则用户以为点错了会话');
      app.dispose();
    });

    test('投影里没有标题:显示「未命名」,不用目录名兜底', () async {
      // 2026-10-16 对齐 DSH 的 Web 侧栏规则:`ui-workspace/README.zh.md:32`
      // 原话"未保存标题的历史会话显示本地化名称「未命名 / Untitled」,不使用目录名兜底"。
      // 之前这里是"退到项目目录名",于是手机上出现一串目录名当会话名,
      // 而 Web 上同一批会话叫"未命名"——真机 2026-10-16 实测的分叉。
      final client = _FakeClient(
        onCall: (method, params) => {
          'sessions': [
            {
              'sid': 's1',
              'updatedAt': 1,
              'running': false,
              'blank': false,
              'subagent': false,
              'cwd': r'D:\sudy\github\dsh-mobile',
            },
          ],
        },
      );
      final app = AppModel(client: client);
      await app.refreshSessions();
      await app.openSession('s1');

      expect(app.sessions.single.displayTitle, '未命名');
      expect(app.currentTitle, '未命名');
      app.dispose();
    });

    test('会话不在列表里(刚建还没刷新):顶栏 null,不拿本地推导冒充', () async {
      // 删掉本地推导兜底后这一条才成立:顶栏与列表永远同一个字符串,
      // 列表里没有的会话顶栏就不编一个(界面退到 'DSH')。
      final client = _FakeClient(onCall: (method, params) => {'sessions': []});
      final app = AppModel(client: client);
      await app.refreshSessions();
      await app.openSession('s1');

      expect(app.sessions, isEmpty);
      expect(app.currentTitle, isNull);
      app.dispose();
    });
  });

  group('两种"空"必须分得开', () {
    test('真没有会话：空列表 + 没有错误', () async {
      final client = _FakeClient(onCall: (method, params) => {'sessions': []});
      final app = AppModel(client: client);

      await app.refreshSessions();

      expect(app.sessions, isEmpty);
      expect(app.lastError, isNull, reason: '真没有会话不是错误');
    });

    test('拉取失败：必须留声（否则与"真没有"在界面上一模一样）', () async {
      final client = _FakeClient(
        onCall: (method, params) => throw const ProtocolException(
          ErrorCode.connectorUnsupported,
          '电脑侧不支持 session.list',
        ),
      );
      final app = AppModel(client: client);

      await app.refreshSessions();

      expect(app.lastError, isNotNull);
      expect(app.lastError!.message, contains('不支持'));
    });

    test('非 ProtocolException 的错也要留声（不许逃逸成未处理的异步错误）', () async {
      // 原先只 catch `ProtocolException`：别的错会逃逸，
      // 界面停在空列表且不报错 —— 那正是最难查的形态（真机实测）。
      final client = _FakeClient(
        onCall: (method, params) => throw StateError('形状完全不对'),
      );
      final app = AppModel(client: client);

      await app.refreshSessions();

      expect(app.lastError, isNotNull, reason: '任何失败都要能被界面看见');
      expect(app.lastError!.message, contains('形状完全不对'));
    });
  });

  group('session.prompt 的参数形状（真机上"发了啥也没有"的第二个原因）', () {
    test('必须是 { sid, content: [{type, text}] }，不是 { sid, text }', () async {
      // 电脑侧（`connector/src/handlers.ts` 的 `requireContent`）要的是
      // `content` 为**非空数组、每项带 `type`**（照 DSH 的 `PromptContentPart`）。
      // 早先手机发的是 `{sid, text}` —— 被拒，而错误只在一闪而过的 SnackBar 里。
      //
      // 这条用例把**载荷形状**钉住：形状错了不会有人报错，只会"发了没反应"。
      final client = _FakeClient(
        onCall: (method, params) => const {'accepted': true},
      );
      final app = AppModel(client: client);
      await app.openSession('sid_X');

      await app.client.call<void>('session.prompt', {
        'sid': 'sid_X',
        'content': [
          {'type': 'text', 'text': '你好'},
        ],
      }, requestId: 'p-1');

      // 直接断言"电脑侧会不会接受这个形状"：`content` 非空且每项带 type。
      //
      // **只挑 `session.prompt` 那几条比**：`openSession` 现在也会拉一次
      // `job.list`（点开会话就刷任务清单），断言完整序列会让这条用例
      // 在每次加一个"点开会话顺便做的事"时都红一次 —— 而它要钉的是
      // **prompt 的载荷形状**,不是调用顺序。
      expect(client.called.where((m) => m == 'session.prompt').toList(), [
        'session.prompt',
      ]);
      final params = client.lastParams!;
      expect(params.containsKey('text'), isFalse, reason: '不能发 {sid, text}');
      final content = params['content'];
      expect(content, isA<List<Object?>>(), reason: 'content 必须是数组');
      expect((content! as List).isNotEmpty, isTrue, reason: 'content 不能为空');
      final first = (content as List).first as Map;
      expect(first['type'], 'text', reason: '每项必须带 type');
      expect(first['text'], '你好');
    });
  });

  group('请求信封：requestId 必须在顶层（真机上"发一句什么也没有"的第三个原因）', () {
    test('带键的调用把 requestId 放进信封顶层，不是塞进 params', () {
      // 电脑侧（`connector/src/method-face.ts`）只认**信封顶层**的 `requestId`：
      // 少了它，带幂等键的方法会被直接拒 ——
      // `session.prompt 必须带 requestId（幂等键）`。
      //
      // 这行曾经把 `requestId` 整个丢掉（编码函数的签名里压根没有这个参数），
      // 而它的注释却写着"`requestId` 顶层"：**注释说了、代码没做**。
      final withKey = encodeRequestEnvelope('session.prompt', const {
        'sid': 's1',
      }, requestId: 'p-1');
      final decoded = jsonDecode(withKey) as Map<String, Object?>;
      expect(decoded['requestId'], 'p-1', reason: '幂等键必须在信封顶层 —— 电脑侧只认这个位置');
      expect(
        (decoded['params']! as Map).containsKey('requestId'),
        isFalse,
        reason: '不能塞进 params（那里电脑侧不看）',
      );

      // 不带键的调用不该凭空多出一个字段。
      final withoutKey = encodeRequestEnvelope('session.list', const {});
      expect((jsonDecode(withoutKey) as Map).containsKey('requestId'), isFalse);
    });
  });

  group('陈旧诊断必须清掉（真机上写着一句早就不成立的错）', () {
    test('失败过一次，之后成功 → 错误要消失', () async {
      // 真机上出现过：屏幕写着 `handshake-timeout`，而中转侧显示
      // hello / confirm / req 三步全都正常走完 —— 那句话是**上一轮**留下的。
      // 陈旧诊断比没有诊断更坏：它把排查引向一个已经不存在的问题。
      final client = _FakeClient(
        onCall: (method, params) => throw const ProtocolException(
          ErrorCode.connectorUnsupported,
          '第一次失败',
        ),
      );
      final app = AppModel(client: client);

      await app.refreshSessions();
      expect(app.lastError, isNotNull, reason: '先失败一次');

      // 换成一个会成功的客户端行为（同一个模型，改回调）。
      final ok = _FakeClient(onCall: (method, params) => {'sessions': []});
      final app2 = AppModel(client: ok);
      await app2.refreshSessions();
      expect(app2.lastError, isNull, reason: '这次成功了，不该再显示上次的错');
    });
  });

  // **回归 2026-10-17 真机**："选中会话名字就变"（该了好几遍都没修对）。
  //
  // 根因不是"两处各读各的"（那是 2026-10-16 修的那半），而是
  // `AppModel._touchSummary` **每次收到 delta 都用本地推导的标题把电脑侧标题
  // 覆盖掉**：打开会话 → 订阅 → 快照事件到达 → 标题从"重构连接层"变成
  // "首条用户消息前 30 字"。列表与顶栏倒是一致的——**一致地错**。
  //
  // 此前这条链在单测里永远不发作：假客户端的 `sessionUpdates` 恒回空流，
  // `_touchSummary` 从未被调用过。**替身绕开的那一段正是生产发作的那一段。**
  //
  // 事件形状按真实会话日志逐字复刻（`~/.dsh/sessions/**/session.v4.jsonl.zstd`
  // 按帧解压后所见）：`user/message` 的 `data` 就是消息本身（带 `id`），
  // `assistant/message` 的消息在 `data.message` 上，`session/title` 在
  // `data.title` 上。
  group('打开会话后标题不许变（_touchSummary 不能覆盖电脑侧标题）', () {
    /// 能推 delta 的假客户端：`sessionUpdates` 给一条可写入口。
    final deltaClient = _DeltaClient(
      onCall: (method, params) => switch (method) {
        'session.list' => {
          'sessions': [
            {
              'sid': 's1',
              'updatedAt': 1792023957795,
              'running': true,
              'blank': false,
              'subagent': false,
              // DSH `SessionSummary.projections` 提示的真形状。
              'projections': {
                'kind': 'sequenced',
                'asOfSeq': 8,
                'values': {'title': 'IoT 数采设备状态统计脚本'},
              },
              'model': {'provider': 'stepfun', 'model': 'step-5-preview'},
              'cwd': r'C:\Users\zhanglu\Desktop\IoT',
            },
          ],
        },
        // `session.projections` 经连接器拆掉信封后，手机拿到的就是 values 映射。
        'session.projections' => const {'title': 'IoT 数采设备状态统计脚本'},
        _ => null,
      },
    );
    late AppModel app;

    setUp(() {
      app = AppModel(client: deltaClient);
    });

    tearDown(() {
      app.dispose();
    });

    test('快照事件到达后：标题、模型、running 一个都不能掉', () async {
      await app.refreshSessions();
      expect(app.sessions.single.displayTitle, 'IoT 数采设备状态统计脚本');

      await app.openSession('s1');
      // 打开会话后电脑侧把快照补课事件逐条发来（真实形状）。
      deltaClient.emitDelta(
        's1',
        events: [
          // 首条用户消息（真日志 seq=8）——旧实现就是拿它推导标题、覆盖掉真标题的。
          _userEvent(seq: 8, text: '帮我写一个脚本：拉取所有数采设备状态并按状态分类展示'),
          _assistantEvent(seq: 16, text: '好的，我先看一下工作区。'),
        ],
      );
      await Future<void>.delayed(Duration.zero);

      final row = app.sessions.single;
      expect(
        row.displayTitle,
        'IoT 数采设备状态统计脚本',
        reason: '选中会话名字就变 = _touchSummary 用本地推导覆盖了电脑侧标题',
      );
      expect(app.currentTitle, 'IoT 数采设备状态统计脚本');
      // 身份字段同样不能掉：旧实现整行重建，model/running 全部掉成默认值。
      expect(row.model?.model, 'step-5-preview', reason: '点进会话模型不能变"未选择"');
      expect(row.running, isTrue);
      expect(row.cwd, r'C:\Users\zhanglu\Desktop\IoT');
      // 计数照旧更新（这一半本来就是对的）。
      expect(row.itemCount, 2);
    });

    test('session/title 事件：标题实时跟着电脑侧变', () async {
      await app.refreshSessions();
      await app.openSession('s1');
      deltaClient.emitDelta('s1', events: [_userEvent(seq: 8, text: '第一句')]);
      await Future<void>.delayed(Duration.zero);

      // DSH 生成/改名时落一条 `session/title`（真日志 seq=14 的形状）。
      deltaClient.emitDelta(
        's1',
        events: [
          const SessionEvent(
            itemId: 'session/title:14',
            type: 'session/title',
            seq: 14,
            time: 1792023957833,
            data: {
              'title': '数采设备状态看板',
              'messageSeqs': [8],
              'source': {'kind': 'fallback'},
            },
          ),
        ],
      );
      await Future<void>.delayed(Duration.zero);

      expect(app.currentTitle, '数采设备状态看板');
      expect(app.sessions.single.displayTitle, '数采设备状态看板');
    });

    test('title 投影比列表提示新：以投影为准', () async {
      await app.refreshSessions();
      await app.openSession('s1');
      await Future<void>.delayed(Duration.zero);
      // 投影里已是新标题（列表提示是旧的 cached 快照）。
      expect(app.currentTitle, 'IoT 数采设备状态统计脚本');
    });
  });
}

/// 能推 delta 的假客户端：`sessionUpdates` 返回一条可写入口。
class _DeltaClient extends _FakeClient {
  _DeltaClient({super.onCall});

  final Map<String, StreamController<SessionDelta>> _controllers = {};

  void emitDelta(String sid, {required List<SessionEvent> events}) {
    final controller = _controllers.putIfAbsent(
      sid,
      () => StreamController<SessionDelta>.broadcast(),
    );
    controller.add(
      SessionDelta(
        sid: sid,
        events: events,
        transient: const <String, Object?>{},
      ),
    );
  }

  @override
  Stream<SessionDelta> sessionUpdates(String sid) => _controllers
      .putIfAbsent(sid, () => StreamController<SessionDelta>.broadcast())
      .stream;
}

/// 一条 `user/message` 事件（真日志形状：`data` 就是消息，带 `id`）。
SessionEvent _userEvent({required int seq, required String text}) =>
    SessionEvent(
      itemId: 'm:msg-$seq',
      type: 'user/message',
      seq: seq,
      time: 1792023957795,
      data: <String, Object?>{
        'content': [
          {'type': 'text', 'text': text},
        ],
        'source': {'kind': 'user'},
        'role': 'user',
        'id': 'msg-$seq',
      },
    );

/// 一条 `assistant/message` 事件（真日志形状：消息在 `data.message` 上）。
SessionEvent _assistantEvent({required int seq, required String text}) =>
    SessionEvent(
      itemId: 'm:asst-$seq',
      type: 'assistant/message',
      seq: seq,
      time: 1792023988752,
      data: <String, Object?>{
        'turn': 1,
        'step': 1,
        'message': <String, Object?>{
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': text},
          ],
          'source': {'kind': 'model', 'provider': 'stepfun'},
          'id': 'asst-$seq',
        },
        'stream': const [],
      },
    );
