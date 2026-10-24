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

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/mention.dart';
import 'package:dsh_mobile/model/permission.dart';
import 'package:dsh_mobile/model/send_mode.dart';
import 'package:dsh_mobile/theme/dsh_icons.dart';
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

      // key 带**下标**：候选标签不唯一（真机 40 个同名会话把 `kind+label` 撞成红屏）。
      expect(
        find.byKey(const ValueKey<String>('at-0-directory-src/')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('at-1-file-src/index.ts')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('at-2-session-重构输入栏')),
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

    testWidgets('同名候选不撞 key（真机 40 个同名会话整屏红的那个回归）', (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(
        host(
          input,
          onQueryMentions: (_) async => MentionQueryResult(
            candidates: AtCandidates(
              // 宿主的候选**允许重名**（同一批里两个会话可以都叫这个名字）。
              sessions: [
                AtCandidate.fromSessionRow({
                  'sid': 'sid_a',
                  'title': 'List numbers 1 to 40',
                  'mention': '@[List numbers 1 to 40](dsh-session:YQ)',
                })!,
                AtCandidate.fromSessionRow({
                  'sid': 'sid_b',
                  'title': 'List numbers 1 to 40',
                  'mention': '@[List numbers 1 to 40](dsh-session:Yg)',
                })!,
              ],
            ),
          ),
        ),
      );
      await type(tester, input, '@List');

      expect(
        find.byKey(const ValueKey<String>('at-0-session-List numbers 1 to 40')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('at-1-session-List numbers 1 to 40')),
        findsOneWidget,
      );
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
        find.byKey(const ValueKey<String>('at-0-file-src/index.ts')),
      );
      await tester.pump();

      expect(input.text, '看 @src/index.ts');
      expect(
        find.byKey(const ValueKey<String>('at-0-file-src/index.ts')),
        findsNothing,
      );
    });
  });

  group('面板是列表行（照宿主 MenuView，不是居中胶囊）', () {
    /// 一台"会按查询串换答案"的电脑：根层给 `src` / `src/index.ts`，
    /// `src/` 那一层给 `src/lib.ts`。
    Future<MentionQueryResult> Function(String) refsByQuery(
      List<String> asked,
    ) => (query) async {
      asked.add(query);
      if (query.startsWith('src/')) {
        return MentionQueryResult(
          candidates: AtCandidates(
            files: [
              AtCandidate.fromFileRow({'path': 'src/lib.ts', 'kind': 'file'})!,
            ],
          ),
        );
      }
      return MentionQueryResult(
        candidates: AtCandidates(
          files: [
            AtCandidate.fromFileRow({'path': 'src', 'kind': 'directory'})!,
            AtCandidate.fromFileRow({'path': 'src/index.ts', 'kind': 'file'})!,
          ],
        ),
      );
    };

    testWidgets('分组标题、行左对齐、名字只取最后一段、说明是父目录', (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(
        host(
          input,
          onQueryMentions: (query) async => MentionQueryResult(
            candidates: AtCandidates(
              files: [
                AtCandidate.fromFileRow({'path': 'src', 'kind': 'directory'})!,
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
            ),
          ),
        ),
      );
      await type(tester, input, '@sr');

      // **分组标题**：宿主 zh 词典的原话（`section.files` / `section.sessions`）。
      expect(find.text(kSectionFiles), findsOneWidget);
      expect(find.text(kSectionSessions), findsOneWidget);

      final panel = tester.getRect(
        find.byKey(const ValueKey<String>('at-panel')),
      );
      // **贴在输入卡上方、与卡片同宽**（DSH 的菜单是 `position:absolute;
      // bottom:calc(100% + 4px); left:0; right:0`，`MenuView.module.css:1-8`）。
      final card = tester.getRect(
        find.descendant(
          of: find.byType(DshComposer),
          matching: find.byType(TextField),
        ),
      );
      expect(panel.bottom, lessThanOrEqualTo(card.top), reason: '面板在输入框上方');
      expect(
        panel.width,
        closeTo(tester.getSize(find.byType(DshComposer)).width - 16, 0.5),
        reason: '面板与卡片同宽（卡片在 8px 的内边距里）',
      );
      final dirRow = tester.getRect(
        find.byKey(const ValueKey<String>('at-0-directory-src')),
      );
      // 行是**左对齐的一列**（居中的胶囊会落在中间）。
      expect(dirRow.left, lessThan(panel.center.dx));
      expect(
        dirRow.width,
        greaterThan(panel.width - 20),
        reason: '行撑满面板（列表行，不是胶囊）',
      );
      expect(
        dirRow.height,
        greaterThanOrEqualTo(34),
        reason: '`.item` 的 min-height 是 34',
      );

      // 名字只取最后一段；目录带一个尾斜杠、文件不带（宿主 `fileCandidate`）。
      expect(find.text('src/'), findsOneWidget);
      expect(find.text('index.ts'), findsOneWidget);
      // 说明 = 父目录；工作区根那一行没有父目录 ⇒ 不摆说明。
      expect(find.text('src'), findsOneWidget, reason: '文件行的说明是它的父目录');
      // 目录行末尾有 chevron，文件行没有。
      Finder chevronIn(String key) => find.descendant(
        of: find.byKey(ValueKey<String>(key)),
        matching: find.byWidgetPredicate(
          (widget) => widget is DshIcon && widget.name == 'chevronRight',
        ),
      );
      expect(chevronIn('at-0-directory-src'), findsOneWidget);
      expect(chevronIn('at-1-file-src/index.ts'), findsNothing);
    });

    testWidgets('点目录行的 chevron = drill：输入框变 `@src/`，**面板不关**，面包屑出现', (
      tester,
    ) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      final asked = <String>[];
      await tester.pumpWidget(host(input, onQueryMentions: refsByQuery(asked)));
      await type(tester, input, '@sr');
      expect(find.byKey(const ValueKey<String>('crumb-0')), findsNothing);

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey<String>('at-0-directory-src')),
          matching: find.byWidgetPredicate(
            (widget) => widget is DshIcon && widget.name == 'chevronRight',
          ),
        ),
      );
      await tester.pump(); // drill 之后的查询是**立刻**发的，不用等去抖
      await tester.pump();

      expect(input.text, '@src/');
      expect(
        find.byKey(const ValueKey<String>('at-panel')),
        findsOneWidget,
        reason: 'drill 的语义是"进去"而不是"选定"，面板必须还在',
      );
      // 面包屑只在 drill 之后出现：工作区 / src。
      expect(find.text(kCrumbRoot), findsOneWidget);
      expect(find.text('src'), findsWidgets);
      // 新的一层有自己的一行。
      expect(
        find.byKey(const ValueKey<String>('at-0-file-src/lib.ts')),
        findsOneWidget,
      );
      expect(asked.last, 'src/', reason: 'drill 之后按新查询再问一次');
    });

    testWidgets('**手打** `@src/` 不出面包屑（只有 drill 才欠一条回去的路）', (tester) async {
      // 宿主原话（`ui-reference/src/client/index.ts:193-198`）：手打的路径自带上下文，
      // 而 drill 把用户正在读的文本换成了更深的一段。所以判据是 `drilled`，
      // 不是"查询串里有没有 `/`"——只按 `/` 判会让每条长路径上面多出一条面包屑。
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(
        host(input, onQueryMentions: refsByQuery(<String>[])),
      );
      await type(tester, input, '@src/');

      expect(find.byKey(const ValueKey<String>('at-panel')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('crumb-0')), findsNothing);
      expect(find.text(kCrumbRoot), findsNothing);
    });

    testWidgets('点面包屑的「工作区」回根层（查询串变空 ⇒ 面包屑自己消失）', (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(
        host(input, onQueryMentions: refsByQuery(<String>[])),
      );
      await type(tester, input, '@sr');
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey<String>('at-0-directory-src')),
          matching: find.byWidgetPredicate(
            (widget) => widget is DshIcon && widget.name == 'chevronRight',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(input.text, '@src/');

      await tester.tap(find.text(kCrumbRoot));
      await tester.pump();
      await tester.pump();

      expect(input.text, '@');
      expect(
        find.byKey(const ValueKey<String>('crumb-0')),
        findsNothing,
        reason: '查询串里没有 `/` 就没有"上一层"（宿主 `crumbsFor` 第二条）',
      );
    });

    testWidgets('点目录行**行体** = 落定：插入 `@src/` 并关面板（不是 drill）', (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(
        host(input, onQueryMentions: refsByQuery(<String>[])),
      );
      await type(tester, input, '@sr');

      await tester.tap(
        find.byKey(const ValueKey<String>('at-0-directory-src')),
      );
      await tester.pump();

      expect(input.text, '@src/');
      expect(find.byKey(const ValueKey<String>('at-panel')), findsNothing);
      expect(find.byKey(const ValueKey<String>('crumb-0')), findsNothing);
    });

    testWidgets('文件行没有 chevron；点它插入 `@path` 并关面板', (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(
        host(input, onQueryMentions: refsByQuery(<String>[])),
      );
      await type(tester, input, '@sr');

      await tester.tap(
        find.byKey(const ValueKey<String>('at-1-file-src/index.ts')),
      );
      await tester.pump();
      expect(input.text, '@src/index.ts');
      expect(find.byKey(const ValueKey<String>('at-panel')), findsNothing);
    });

    testWidgets('pending 先给两行骨架（不是一句"正在找…"）', (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      final never = Completer<MentionQueryResult>();
      await tester.pumpWidget(
        host(input, onQueryMentions: (_) => never.future),
      );
      input.text = '@sr';
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byKey(const ValueKey<String>('at-panel')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('at-loading')), findsNothing);
      expect(find.text('正在找…'), findsNothing);
      // 骨架 = 两根灰条（宽 32% / 48%），没有名字可读。
      expect(find.byKey(const ValueKey<String>('at-empty')), findsNothing);
      addTearDown(() => never.complete(const MentionQueryResult()));
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
