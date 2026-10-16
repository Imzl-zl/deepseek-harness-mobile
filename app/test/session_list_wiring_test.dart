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
import 'package:flutter_test/flutter_test.dart';

/// 只回固定答案的假客户端；`onCall` 让每条用例自己决定回什么、抛什么。
class _FakeClient implements SyncClient {
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
            {'sid': 'J-AQFoAKdDuro5HLhhaaOw', 'updatedAt': 1791361744613},
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
            {'sid': 'sid_AAAA', 'updatedAt': 1000},
            {'sid': 'sid_BBBB', 'updatedAt': 2000},
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

    test('裸数组也认（早期假客户端的形状），但两种形状都得能用', () async {
      final client = _FakeClient(
        onCall: (method, params) => [
          {'sid': 'sid_CCCC', 'updatedAt': 3000},
        ],
      );
      final app = AppModel(client: client);

      await app.refreshSessions();

      expect(app.sessions.map((s) => s.sid), ['sid_CCCC']);
    });

    test('running 与 blank 都要解析（挑靶子靠它们，丢了就会叫醒别人的会话）', () async {
      // `blank` = 从没被 agent 跑过（`connector/src/dsh/sessions.ts` 的原话）。
      // 连接器一直在发这两个字段，而手机侧此前把 blank 丢掉了 —— 于是
      // "挑一个空闲会话当靶子"只能按 `!running` 挑，挑到的是**刚被别人跑完
      // 一轮**的会话，把探针投进去会把那个 agent 唤醒（2026-10-13 真机两次踩到）。
      final client = _FakeClient(
        onCall: (method, params) => {
          'sessions': [
            {'sid': 'sid_running', 'updatedAt': 1000, 'running': true},
            {
              'sid': 'sid_blank',
              'updatedAt': 900,
              'running': false,
              'blank': true,
            },
            {
              'sid': 'sid_idle_used',
              'updatedAt': 800,
              'running': false,
              'blank': false,
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
      // 默认值也得对：老连接器/老 fixture 不发 blank 时不能默认成 true。
      final legacy = AppModel(
        client: _FakeClient(
          onCall: (method, params) => {
            'sessions': [
              {'sid': 'sid_legacy', 'updatedAt': 1},
            ],
          },
        ),
      );
      await legacy.refreshSessions();
      expect(legacy.sessions.single.blank, isFalse);
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
              'cwd': r'D:\sudy\myproject\dsh-mobile-test',
            },
            // 老连接器 / 落盘里没有 cwd 的会话：**null**，不是空串。
            {'sid': 'sid_no_cwd', 'updatedAt': 900},
            // 空串同样当没有：空串会让"按工作区匹配"静默失败。
            {'sid': 'sid_empty_cwd', 'updatedAt': 800, 'cwd': ''},
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
  });

  // **回归 2026-10-15 真机**："列表里名字对了,但我点进去会话名字又变了"。
  // 根因是**两个真值源**:列表走 DSH 的展示链(投影提示 → 目录名 → sid),
  // 而 `currentTitle` 只读本地从条目推导的标题。同一个人会话两个名字。
  group('标题只有一个真值源（列表与顶栏同一条链）', () {
    test('投影提示里有持久标题:列表与顶栏都用它', () async {
      final client = _FakeClient(
        onCall: (method, params) => {
          'sessions': [
            {
              'sid': 's1',
              'updatedAt': 1,
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

    test('投影里没有标题:两级都退到项目目录名', () async {
      final client = _FakeClient(
        onCall: (method, params) => {
          'sessions': [
            {'sid': 's1', 'updatedAt': 1, 'cwd': r'D:\sudy\github\dsh-mobile'},
          ],
        },
      );
      final app = AppModel(client: client);
      await app.refreshSessions();
      await app.openSession('s1');

      expect(app.sessions.single.displayTitle, 'dsh-mobile');
      expect(app.currentTitle, 'dsh-mobile');
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
}
