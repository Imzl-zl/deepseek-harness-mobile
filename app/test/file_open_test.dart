/// 「打开一个文件」这一个动作（`lib/model/file_open.dart` + `AppModel.openFile`）。
///
/// ## 这一组守什么
///
/// 1. **只有一个入口**：四次打开都走 `openFile`，请求里的路径**原样**过线
///    （scope 由宿主按会话解析，手机不拼 cwd —— 见 `model/file_open.dart` 文件头）；
/// 2. **没有能力位就不发请求**（老连接器 / 没连上，两句话不同）；
/// 3. **失败照报电脑侧原话**，不翻译、不返回空内容冒充"空文件"；
/// 4. `diff` 模式在批 C 之前**如实说没接**，不把两段现在的文本编成 diff；
/// 5. 正文提及的词表是**这一轮**的改动路径（DSH 的 `producedFileMentions`
///    词表就限在这一轮，`ui-deliverables/src/client/turn-deliverables.ts:269-296`）。
library;

import 'dart:convert';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/projection.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/model/file_open.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 一台假电脑：`repo.info`（能力位）+ `file.read`（按 offset 分页）。
class _OpenClient extends FakeSyncClient {
  _OpenClient({this.filesAvailable = true, this.pages = const {}});

  final bool filesAvailable;

  /// `offset → 页`（键 `null` 是第一页）。
  final Map<int?, Map<String, Object?>> pages;

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
        return <String, Object?>{
              'protocol': 1,
              'caps': <String, Object?>{if (filesAvailable) 'files': true},
            }
            as T;
      case 'file.read':
        final offset = params['offset'] as int?;
        return <String, Object?>{
              'page':
                  pages[offset] ??
                  <String, Object?>{
                    'text': '',
                    'offset': offset ?? 1,
                    'lines': 0,
                    'eof': true,
                  },
            }
            as T;
    }
    return <String, Object?>{} as T;
  }
}

Future<AppModel> _app(_OpenClient client, {bool known = true}) async {
  final app = AppModel(client: client);
  if (known) await app.refreshRepoInfo();
  await app.openSession('sid_1');
  return app;
}

/// 一条 `tool/call`（真日志形状：`arguments` 是 JSON **字符串**）。
ChatItem _writeCall({
  required int seq,
  required int turn,
  required String callId,
  required String path,
}) => projectEvent(
  type: 'tool/call',
  seq: seq,
  turn: turn,
  data: <String, Object?>{
    'turn': turn,
    'step': 1,
    'callId': callId,
    'name': 'write',
    'arguments': jsonEncode(<String, Object?>{
      'file_path': path,
      'content': 'x',
    }),
  },
).item!;

/// 一条带正文的 `assistant/message`。
ChatItem _assistant({
  required int seq,
  required int turn,
  required String id,
  required String text,
}) => projectEvent(
  type: 'assistant/message',
  seq: seq,
  turn: turn,
  data: <String, Object?>{
    'turn': turn,
    'step': 1,
    'message': <String, Object?>{
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': text},
      ],
      'source': {'kind': 'model'},
      'id': id,
    },
  },
).item!;

void main() {
  group('openFile（预览）', () {
    test('请求原样过线，内容与分页状态落账', () async {
      final client = _OpenClient(
        pages: {
          null: {'text': '第一行\n第二行', 'offset': 1, 'lines': 2, 'eof': false},
        },
      );
      final app = await _app(client);
      addTearDown(app.dispose);

      await app.openFile(const FileOpenRequest(path: 'src/a.ts'));

      expect(
        client.sent.where((c) => c.$1 == 'file.read').map((c) => c.$2),
        [
          {'sid': 'sid_1', 'path': 'src/a.ts'},
        ],
        reason: '手机不拼 cwd：路径原样交给 file.read（scope 在宿主）',
      );
      expect(app.fileOpenRequest, const FileOpenRequest(path: 'src/a.ts'));
      expect(app.fileOpenTicket, 1);
      expect(app.fileLoading, isFalse);
      expect(app.fileFailure, isNull);
      expect(app.openedFile, isNotNull);
      expect(app.openedFile!.text, '第一行\n第二行');
      expect(app.openedFile!.lines, 2);
      expect(app.openedFile!.eof, isFalse);
      expect(app.openedFile!.nextOffset, 3);
    });

    test('同一个路径再点一次也再开一次（请求序号递增，界面能再反应）', () async {
      final client = _OpenClient(
        pages: {
          null: {'text': 'x', 'offset': 1, 'lines': 1, 'eof': true},
        },
      );
      final app = await _app(client);
      addTearDown(app.dispose);

      const request = FileOpenRequest(path: 'README.md');
      await app.openFile(request);
      final first = app.fileOpenTicket;
      await app.openFile(request);
      expect(app.fileOpenTicket, first + 1);
      expect(client.sent.where((c) => c.$1 == 'file.read'), hasLength(2));
    });

    test('读失败：内容为 null，原因照报电脑侧原话', () async {
      // 让 read 抛：宿主拒二进制时的原话。
      final throwing = _ThrowingReadClient();
      final app2 = AppModel(client: throwing);
      addTearDown(app2.dispose);
      await app2.refreshRepoInfo();
      await app2.openSession('sid_1');

      await app2.openFile(const FileOpenRequest(path: 'bin.dat'));

      expect(app2.openedFile, isNull);
      expect(app2.fileFailure, contains('workspace-file/not-text'));
      expect(app2.fileOpenTicket, 1);
    });

    test('没有 caps.files：一次 file.read 都不发，说清"没有文件服务"', () async {
      final client = _OpenClient(filesAvailable: false);
      final app = await _app(client);
      addTearDown(app.dispose);

      await app.openFile(const FileOpenRequest(path: 'src/a.ts'));

      expect(client.sent.where((c) => c.$1 == 'file.read'), isEmpty);
      expect(app.fileFailure, contains('没有文件服务'));
      expect(app.fileOpenRequest, isNotNull, reason: '请求仍要留下：界面要能在侧栏里说这句话');
    });

    test('没读到 repo.info：说"还没连上"，不说"没有文件服务"', () async {
      final client = _OpenClient();
      final app = await _app(client, known: false);
      addTearDown(app.dispose);

      await app.openFile(const FileOpenRequest(path: 'src/a.ts'));

      expect(client.sent.where((c) => c.$1 == 'file.read'), isEmpty);
      expect(app.fileFailure, contains('还没连上'));
      expect(app.fileFailure, isNot(contains('没有文件服务')));
    });

    test('diff 模式如实说"还没接"：不发请求，更不拿现在的文本编一份', () async {
      final client = _OpenClient(
        pages: {
          null: {'text': 'x', 'offset': 1, 'lines': 1, 'eof': true},
        },
      );
      final app = await _app(client);
      addTearDown(app.dispose);

      await app.openFile(
        const FileOpenRequest(path: 'src/a.ts', mode: FileOpenMode.diff),
      );

      expect(client.sent.where((c) => c.$1 == 'file.read'), isEmpty);
      expect(app.fileFailure, contains('file.diff'));
      expect(app.openedFile, isNull);
    });

    test('加载更多：用下一页的 offset 追加正文，eof 之后不再请求', () async {
      final client = _OpenClient(
        pages: {
          null: {'text': '第1行\n第2行', 'offset': 1, 'lines': 2, 'eof': false},
          3: {'text': '第3行', 'offset': 3, 'lines': 1, 'eof': true},
        },
      );
      final app = await _app(client);
      addTearDown(app.dispose);

      await app.openFile(const FileOpenRequest(path: 'src/a.ts'));
      await app.loadMoreOpenedFile();

      expect(app.openedFile!.text, '第1行\n第2行\n第3行');
      expect(app.openedFile!.lines, 3);
      expect(app.openedFile!.eof, isTrue);
      final before = client.sent.where((c) => c.$1 == 'file.read').length;
      await app.loadMoreOpenedFile();
      expect(
        client.sent.where((c) => c.$1 == 'file.read'),
        hasLength(before),
        reason: 'eof 之后不该再请求',
      );
    });

    test('closeFile 清空三样状态', () async {
      final client = _OpenClient(
        pages: {
          null: {'text': 'x', 'offset': 1, 'lines': 1, 'eof': true},
        },
      );
      final app = await _app(client);
      addTearDown(app.dispose);
      await app.openFile(const FileOpenRequest(path: 'README.md'));

      app.closeFile();

      expect(app.fileOpenRequest, isNull);
      expect(app.openedFile, isNull);
      expect(app.fileFailure, isNull);
    });
  });

  group('正文提及的词表（按轮）', () {
    Future<AppModel> seeded(List<ChatItem> items) async {
      final client = _OpenClient();
      final app = AppModel(client: client);
      addTearDown(app.dispose);
      app.seedForTest(sid: 'sid_1', title: 't', updatedAt: 1, items: items);
      await app.openSession('sid_1');
      return app;
    }

    test('同一轮里 write 过的路径 ⇒ 提及；别的轮的同一 token ⇒ 惰性', () async {
      final items = <ChatItem>[
        _writeCall(seq: 2, turn: 1, callId: 'c1', path: 'src/a.ts'),
        _assistant(seq: 3, turn: 1, id: 'm1', text: '改了 `src/a.ts`。'),
        _assistant(seq: 4, turn: 2, id: 'm2', text: '又提到 `src/a.ts`。'),
      ];
      final app = await seeded(items);

      final first = app.items.whereType<MessageItem>().firstWhere(
        (i) => i.itemId == 'm:m1',
      );
      final second = app.items.whereType<MessageItem>().firstWhere(
        (i) => i.itemId == 'm:m2',
      );
      expect(app.fileMentionsOf(first), {'src/a.ts': 'src/a.ts'});
      expect(
        app.fileMentionsOf(second),
        isNull,
        reason: '词表是**这一轮**的产出（DSH 的 producedFileMentions 同一条）',
      );
    });

    test('basename 歧义 ⇒ 不做成链接（不猜）', () async {
      final items = <ChatItem>[
        _writeCall(seq: 2, turn: 1, callId: 'c1', path: 'src/a.ts'),
        _writeCall(seq: 3, turn: 1, callId: 'c2', path: 'server/a.ts'),
        _assistant(seq: 4, turn: 1, id: 'm1', text: '看 `a.ts`。'),
      ];
      final app = await seeded(items);

      final message = app.items.whereType<MessageItem>().first;
      expect(app.fileMentionsOf(message), isNull);
    });
  });
}

/// `file.read` 直接抛的假电脑（宿主拒二进制时的形状）。
class _ThrowingReadClient extends FakeSyncClient {
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
            'caps': <String, Object?>{'files': true},
          }
          as T;
    }
    if (method == 'file.read') {
      throw Exception('workspace-file/not-text: "bin.dat" contains NUL bytes');
    }
    return <String, Object?>{} as T;
  }
}
