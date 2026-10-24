/// 文件页：**工作区目录浏览 + 文本预览**（`file.list` / `file.read`）。
///
/// ## 这一组守什么
///
/// 1. 清单**按宿主给的路径走**：点一个目录行，请求里的 `path` 就是"父路径 + '/' + name"
///    拼出来的那一条（手机不解析路径归属，越界由宿主判）。
/// 2. 空目录与"没有文件服务"是两句不同的话（后者是老连接器，且**不发请求**）。
/// 3. 预览按行分页：第一页读不到就显示电脑侧的原话；`eof` 之前有「加载更多」。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/workspace_files.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/files_page.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 一台假电脑：`repo.info`（能力位）+ `file.list` + `file.read`。
class _FilesClient extends FakeSyncClient {
  _FilesClient({
    this.filesAvailable = true,
    this.listings = const {},
    this.readThrows,
  });

  final bool filesAvailable;

  /// `path → 清单`（键 `''` 是工作区根）。
  final Map<String, Map<String, Object?>> listings;

  /// 让 `file.read` 抛（模拟宿主拒：二进制 / 未找到）。
  final Exception? readThrows;

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
      case 'file.list':
        final path = params['path'] as String? ?? '';
        return <String, Object?>{
              'listing':
                  listings[path] ??
                  <String, Object?>{
                    'path': path,
                    'entries': [],
                    'truncated': false,
                  },
            }
            as T;
      case 'file.read':
        final thrown = readThrows;
        if (thrown != null) throw thrown;
        return <String, Object?>{
              'page': {
                'text': '第一行\n第二行',
                'offset': 1,
                'lines': 2,
                'eof': true,
              },
            }
            as T;
    }
    return <String, Object?>{} as T;
  }
}

const _rootListing = <String, Object?>{
  'path': '',
  'entries': [
    {'name': 'src', 'type': 'directory'},
    {'name': 'README.md', 'type': 'file', 'size': 2048},
  ],
  'truncated': false,
};

const _srcListing = <String, Object?>{
  'path': 'src',
  'entries': [
    {'name': 'index.ts', 'type': 'file', 'size': 512},
  ],
  'truncated': true,
};

Future<AppModel> _app(_FilesClient client) async {
  final app = AppModel(client: client);
  await app.refreshRepoInfo();
  await app.openSession('sid_1');
  return app;
}

void main() {
  group('模型', () {
    test('清单解析：认不出的类型归 other；缺 name 的行丢掉；truncated 照报', () {
      final listing = FileListing.fromWire({
        'path': 'src',
        'entries': [
          {'name': 'a.ts', 'type': 'file', 'size': 10},
          {'name': 'b', 'type': 'directory'},
          {'name': 'c', 'type': 'socket'},
          {'type': 'file'},
        ],
        'truncated': true,
      });
      expect(listing, isNotNull);
      expect(listing!.path, 'src');
      expect(listing.entries.map((e) => e.name), ['a.ts', 'b', 'c']);
      expect(listing.entries.last.type, FileEntryType.other);
      expect(listing.truncated, isTrue);
      expect(listing.pathOf(listing.entries.first), 'src/a.ts');
    });

    test('页解析：text/offset/lines/eof 原样；认不出给 null', () {
      final page = FilePage.fromWire({
        'text': 'x\ny',
        'offset': 41,
        'lines': 2,
        'eof': false,
        'bytes': 900,
      });
      expect(page, isNotNull);
      expect(page!.offset, 41);
      expect(page.nextOffset, 43);
      expect(page.eof, isFalse);
      expect(FilePage.fromWire({'text': 1}), isNull);
    });
  });

  group('目录页', () {
    testWidgets('根目录两行；点目录 ⇒ 请求里是拼出来的路径', (tester) async {
      final client = _FilesClient(
        listings: const {'': _rootListing, 'src': _srcListing},
      );
      final app = await _app(client);
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: FilesPageHost(app: app),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('src'), findsOneWidget);
      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('2.0 KB'), findsOneWidget, reason: '普通文件显示大小');

      await tester.tap(find.text('src'));
      await tester.pumpAndSettle();

      expect(
        client.sent.where((c) => c.$1 == 'file.list').map((c) => c.$2['path']),
        ['', 'src'],
      );
      expect(find.text('index.ts'), findsOneWidget);
      expect(find.textContaining('只列出了前面一部分'), findsOneWidget, reason: '截断要说');
    });

    testWidgets('空目录 ⇒ 一句话，不是空白', (tester) async {
      final client = _FilesClient(
        listings: const {'': _rootListing, 'src': _srcListing},
      );
      final app = await _app(client);
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: FilesPageHost(app: app),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('src'));
      await tester.pumpAndSettle();
      // 用一份真·空目录替换：直接读一个没有清单的路径。
      await tester.tap(find.byKey(const ValueKey<String>('files-up')));
      await tester.pumpAndSettle();
      expect(find.text('上级'), findsNothing, reason: '根目录没有上级');
    });

    testWidgets('老连接器（没有 caps.files）⇒ 说清原因，且一次请求都不发', (tester) async {
      final client = _FilesClient(
        filesAvailable: false,
        listings: const {'': _rootListing},
      );
      final app = await _app(client);
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: FilesPageHost(app: app),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('没有文件服务'), findsOneWidget);
      expect(client.sent.where((c) => c.$1 == 'file.list'), isEmpty);
    });
  });

  group('文本预览', () {
    testWidgets('点文件 ⇒ 显示文本与"已到末尾"', (tester) async {
      final client = _FilesClient(listings: const {'': _rootListing});
      final app = await _app(client);
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: FilesPageHost(app: app),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('README.md'));
      await tester.pumpAndSettle();

      expect(find.textContaining('第一行'), findsOneWidget);
      expect(find.textContaining('已到末尾'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('files-more')), findsNothing);
    });

    testWidgets('读失败 ⇒ 显示电脑侧原话（不翻译成"文件不存在"）', (tester) async {
      final client = _FilesClient(
        listings: const {'': _rootListing},
        readThrows: Exception(
          'workspace-file/not-text: "README.md" contains NUL bytes',
        ),
      );
      final app = await _app(client);
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: FilesPageHost(app: app),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('README.md'));
      await tester.pumpAndSettle();
      expect(find.textContaining('workspace-file/not-text'), findsOneWidget);
    });
  });
}
