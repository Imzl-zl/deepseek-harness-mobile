/// `@` 候选：**触发判据与宿主同一条**、插入的是纯文本、三态各说各的。
///
/// ## 这一组守什么
///
/// 1. 触发判据三条（`model/mention.dart` 的 `atTriggerOf`）：
///    行首 / 空白之后 ⇒ 出；正文中间、跨行 ⇒ 不出。判据照 DSH 的
///    `TEXT_REF_RE = /(^|\s)([/@])([\w-]+)/g`（`decorations.ts:24-26`）。
/// 2. 插入文本：文件 `@path`、目录补一个 `/`、会话**用宿主给的 `mention` 一个字符都不改**；
///    并且**只替换那一个 token**（前面的正文原样留着）。
/// 3. 界面三态：列表 / 空 / **失败显示电脑侧给的原因**（不是空列表）；
///    老连接器（`caps.references` 缺席）⇒ 面板整块不显示。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/mention.dart';
import 'package:dsh_mobile/model/permission.dart';
import 'package:dsh_mobile/model/send_mode.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/dsh_composer.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 只回答 `repo.info` 的替身（能力位可定制）。
class _RepoClient extends FakeSyncClient {
  _RepoClient({required this.references});

  /// `caps.references` 的值；`null` = 老连接器不报这个键。
  final bool? references;

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'repo.info') {
      return <String, Object?>{
            'protocol': 1,
            'caps': <String, Object?>{
              if (references != null) 'references': references,
            },
          }
          as T;
    }
    return <String, Object?>{} as T;
  }
}

/// 一台真形状的电脑：`refs.files` / `refs.sessions` 按查询串回候选。
///
/// `openSession` 要一条真的订阅流（它是"打开一个会话"的正规入口），
/// 所以这里把连接层那几样给成最小的合法实现。
class _RefsClient extends FakeSyncClient {
  _RefsClient();

  /// 发出去的查询串（去抖的判据：一次按键只查一次）。
  final List<String> queries = [];

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
    if (method == 'repo.info') {
      return <String, Object?>{
            'protocol': 1,
            'caps': <String, Object?>{'references': true},
          }
          as T;
    }
    if (method == 'refs.files' || method == 'refs.sessions') {
      queries.add('$method:${params['query']}');
      if (method == 'refs.files') {
        return <String, Object?>{
              'files': [
                {'path': 'src/', 'kind': 'directory'},
                {'path': 'src/index.ts', 'kind': 'file'},
              ],
            }
            as T;
      }
      return <String, Object?>{
            'sessions': [
              {
                'sid': 'sid_a',
                'title': '重构输入栏',
                'mention': '@[重构输入栏](dsh-session:ImRzaC1zZXNzaW9uLTki)',
              },
            ],
          }
          as T;
    }
    return <String, Object?>{} as T;
  }
}

Widget host(
  TextEditingController controller, {
  bool mentionsEnabled = true,
  Future<MentionQueryResult> Function(String query)? onQueryMentions,
}) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(
    body: DshComposer(
      controller: controller,
      attachments: const [],
      modelName: 'auto',
      reasoningLabel: null,
      access: const PermissionChip(icon: 'shield', label: '工作区', warn: false),
      sendMode: SendMode.queue,
      sending: false,
      mentionsEnabled: mentionsEnabled,
      onQueryMentions: onQueryMentions,
      onSend: () {},
      onAttach: () {},
      onPickModel: () {},
      onPickAccess: () {},
      onRemoveAttachment: (_) {},
    ),
  ),
);

/// 打一段文本并等过 150 ms 去抖 + 一次应答。
Future<void> type(
  WidgetTester tester,
  TextEditingController input,
  String text,
) async {
  input.text = text;
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
}

void main() {
  group('触发判据（与宿主 TEXT_REF_RE 同一件事）', () {
    test('行首或空白之后 ⇒ 出面板，查询串是 `@` 之后那一段', () {
      expect(atQueryOf('@'), '');
      expect(atQueryOf('@src/in'), 'src/in');
      expect(atQueryOf('看看 @sr'), 'sr');
      expect(atTriggerOf('看看 @sr')?.at, 3);
    });

    test('正文中间的 `@` 不是引用（`x@name` 永不匹配）', () {
      expect(atQueryOf('a@b'), isNull);
      expect(atQueryOf('mail: me@example.com'), isNull);
    });

    test('token 到空白 / 换行就结束 ⇒ 不查', () {
      expect(atQueryOf('@src '), isNull);
      expect(atQueryOf('@src/index.ts 然后呢'), isNull);
      expect(atQueryOf('@src\nnext'), isNull);
    });
  });

  group('插入文本', () {
    test('文件 `@path`、目录补一个 `/`', () {
      final file = AtCandidate.fromFileRow({
        'path': 'src/index.ts',
        'kind': 'file',
      })!;
      final directory = AtCandidate.fromFileRow({
        'path': 'src/',
        'kind': 'directory',
      })!;
      expect(file.insertion, '@src/index.ts');
      expect(directory.insertion, '@src/');
      // 已经带斜杠的路径不再补第二个
      final bare = AtCandidate.fromFileRow({
        'path': 'src',
        'kind': 'directory',
      })!;
      expect(bare.insertion, '@src/');
    });

    test('会话用宿主给的 `mention` 原样；且只替换那一个 token', () {
      const mention = '@[重构输入栏](dsh-session:ImRzaC1zZXNzaW9uLTki)';
      final session = AtCandidate.fromSessionRow({
        'sid': 'sid_a',
        'title': '重构输入栏',
        'mention': mention,
      })!;
      expect(session.insertion, mention, reason: '宿主拼的引用语法一个字符都不改');
      expect(
        insertAtMention('先看 @重构', session),
        '先看 $mention',
        reason: '前面的正文原样留着，只换那个 token',
      );
      expect(
        insertAtMention('@sr', session),
        mention,
        reason: '整段就是一个 token 时，结果就是那段引用本身',
      );
    });
  });

  group('界面三态', () {
    testWidgets('打 `@` ⇒ 一对候选（文件/目录 + 会话）', (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(
        host(
          input,
          onQueryMentions: (query) async {
            final candidates = AtCandidates(
              files: [
                AtCandidate.fromFileRow({'path': 'src/', 'kind': 'directory'})!,
                AtCandidate.fromFileRow({
                  'path': 'src/index.ts',
                  'kind': 'file',
                })!,
              ],
              sessions: [
                AtCandidate.fromSessionRow({
                  'sid': 'sid_a',
                  'title': '重构输入栏',
                  'mention': '@[重构输入栏](dsh-session:x)',
                })!,
              ],
            );
            return MentionQueryResult(candidates: candidates);
          },
        ),
      );
      await type(tester, input, '@sr');

      expect(
        find.byKey(const ValueKey<String>('at-directory-src/')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('at-file-src/index.ts')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('at-session-重构输入栏')),
        findsOneWidget,
      );
    });

    testWidgets('电脑侧说没有匹配 ⇒ 空态那句话（不是空白一片）', (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(
        host(
          input,
          onQueryMentions: (_) async =>
              const MentionQueryResult(candidates: AtCandidates()),
        ),
      );
      await type(tester, input, '@zzz');
      expect(find.byKey(const ValueKey<String>('at-empty')), findsOneWidget);
      expect(find.text('没有匹配的文件或会话'), findsOneWidget);
    });

    testWidgets('失败 ⇒ 显示电脑侧给的原因（**不是空列表**）', (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(
        host(
          input,
          onQueryMentions: (_) async =>
              const MentionQueryResult(error: '这个会话在电脑上没有对应的活动 agent'),
        ),
      );
      await type(tester, input, '@src');
      expect(find.byKey(const ValueKey<String>('at-failure')), findsOneWidget);
      expect(find.text('这个会话在电脑上没有对应的活动 agent'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('at-empty')), findsNothing);
    });

    testWidgets('老连接器（没有 caps.references）⇒ 面板整块不显示', (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      var asked = 0;
      await tester.pumpWidget(
        host(
          input,
          mentionsEnabled: false,
          onQueryMentions: (query) async {
            asked += 1;
            return const MentionQueryResult(candidates: AtCandidates());
          },
        ),
      );
      await type(tester, input, '@sr');
      expect(find.byKey(const ValueKey<String>('at-empty')), findsNothing);
      expect(asked, 0, reason: '没有能力位就不该发查询 —— 一次都不该发');
    });

    testWidgets('点一枚 ⇒ 输入框变成那段纯文本，面板随即消失', (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(
        host(
          input,
          onQueryMentions: (_) async => MentionQueryResult(
            candidates: AtCandidates(
              files: [
                AtCandidate.fromFileRow({
                  'path': 'src/index.ts',
                  'kind': 'file',
                })!,
              ],
            ),
          ),
        ),
      );
      await type(tester, input, '看 @src');
      await tester.tap(
        find.byKey(const ValueKey<String>('at-file-src/index.ts')),
      );
      await tester.pump();

      expect(input.text, '看 @src/index.ts');
      expect(
        find.byKey(const ValueKey<String>('at-file-src/index.ts')),
        findsNothing,
      );
    });
  });

  group('能力位与查询都从电脑侧来', () {
    test('caps.references 为 true ⇒ mentionsAvailable', () async {
      final app = AppModel(client: _RepoClient(references: true));
      addTearDown(app.dispose);
      expect(app.mentionsAvailable, isFalse, reason: '还没读到 repo.info 时不该声称有能力');
      await app.refreshRepoInfo();
      expect(app.mentionsAvailable, isTrue);
    });

    test('老连接器不报 caps.references ⇒ false（手机不显示面板）', () async {
      final app = AppModel(client: _RepoClient(references: null));
      addTearDown(app.dispose);
      await app.refreshRepoInfo();
      expect(app.mentionsAvailable, isFalse);
    });

    test('没有选中会话 ⇒ 如实说，一个请求都不发', () async {
      final client = _RefsClient();
      final app = AppModel(client: client);
      addTearDown(app.dispose);
      final result = await app.queryMentions('src');
      expect(result.error, isNotNull);
      expect(client.queries, isEmpty);
    });

    test('两个方法各发一次（同一个查询串），应答各自解析成行', () async {
      final client = _RefsClient();
      final app = AppModel(client: client);
      addTearDown(app.dispose);
      await app.openSession('sid_1');
      final result = await app.queryMentions('src');
      expect(client.queries, ['refs.files:src', 'refs.sessions:src']);
      final candidates = result.candidates!;
      expect(candidates.files.map((row) => row.path), ['src/', 'src/index.ts']);
      expect(candidates.sessions.single.title, '重构输入栏');
      expect(
        candidates.sessions.single.mention,
        '@[重构输入栏](dsh-session:ImRzaC1zZXNzaW9uLTki)',
      );
    });
  });
}
