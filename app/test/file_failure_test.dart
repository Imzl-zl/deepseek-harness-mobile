/// 文件打不开时**该说什么**（按码换文案，不打印宿主英文原文）。
///
/// 判据出处：DSH `ui-sidebar-documentpreview/src/client/failure-line.ts:24-35`
/// 与 `locales.ts:27-31`（码 → 文案 → 动作）。
///
/// 连接器原先没有这四个码（`connector/src/protocol/errors.ts` 的 `ERROR_TABLE`），
/// `ProtocolError` 会把不认识的宿主码归成 `internal`（`:112`），于是手机只能显示
/// 宿主的英文原话 —— 真机上看到的就是「读取失败：英文原文」。
library;

import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/data/file_preview.dart';
import 'package:dsh_mobile/model/file_failure.dart';
import 'package:dsh_mobile/model/file_open.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

class _ThrowingClient extends FakeSyncClient {
  _ThrowingClient(this.error);

  final ProtocolException error;

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => throw error;
}

/// 一个**只关心失败文案**的 `FilePreview`：能力位全开、不通知。
FilePreview _preview(
  FakeSyncClient client, {
  required String? Function() message,
  required ErrorCode? Function() code,
}) => FilePreview(
  client: client,
  sidOf: () => 's1',
  filesAvailable: () => true,
  changesAvailable: () => false,
  repoInfoKnown: () => true,
  recordError: (_, _) {},
  lastErrorMessage: message,
  lastErrorCode: code,
  onChange: () {},
);

void main() {
  group('fileFailureText', () {
    test('四类"读得懂但打不开"说中文结论（照 DSH 文案）', () {
      expect(
        fileFailureText(ErrorCode.workspaceFileNotText, 'not a text file'),
        '该格式文件暂时无法预览',
      );
      expect(
        fileFailureText(ErrorCode.workspaceFileTooLarge, 'too large'),
        '单页内容超过上限，无法读取',
      );
      expect(
        fileFailureText(ErrorCode.workspaceFileNotFound, 'ENOENT'),
        '找不到这个文件',
      );
      expect(
        fileFailureText(ErrorCode.workspaceFileNotRegularFile, 'EISDIR'),
        '该路径不是普通文件，没有可显示的内容',
      );
    });

    test('其它码保留宿主原话（桌面也是 `读取失败：{message}`）', () {
      expect(fileFailureText(ErrorCode.gatewayInternal, 'boom'), '读取失败：boom');
      expect(fileFailureText(ErrorCode.gatewayInternal, ''), '读取文件失败');
      expect(fileFailureText(null, 'raw'), 'raw');
      expect(fileFailureText(null, null), '读取文件失败');
    });
  });

  test('预览接口真的用上这条映射：not-text 的文件不再显示英文原文', () async {
    final client = _ThrowingClient(
      const ProtocolException(
        ErrorCode.workspaceFileNotText,
        'not a text file',
      ),
    );
    final preview = _preview(
      client,
      message: () => 'not a text file',
      code: () => ErrorCode.workspaceFileNotText,
    );

    await preview.open(const FileOpenRequest(path: 'lib/main.dart'));

    expect(preview.failure, '该格式文件暂时无法预览');
    expect(preview.openedFile, isNull);
  });

  test('其它错误仍显示宿主原话（不吞掉我们家自己的缺陷）', () async {
    final client = _ThrowingClient(
      const ProtocolException(ErrorCode.gatewayBadRequest, 'bad params'),
    );
    final preview = _preview(
      client,
      message: () => 'bad params',
      code: () => ErrorCode.gatewayBadRequest,
    );

    await preview.open(const FileOpenRequest(path: 'a.txt'));

    expect(preview.failure, '读取失败：bad params');
  });
}
