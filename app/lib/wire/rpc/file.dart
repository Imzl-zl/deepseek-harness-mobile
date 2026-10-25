/// **工作区文件面**（`file.*`，只读）的唯一入口。
///
/// 形状出处 `connector/src/handlers.ts`：
///
/// | 方法 | 应答 |
/// |---|---|
/// | `file.list` `:1295-1302` | `{listing: {...}}`（目录清单）|
/// | `file.read` `:1303-1318` | `{page: {...}}`（UTF-8 文本按行分页）|
///
/// **`listing` / `page` 是信封里的一层**：本体（条目字段、分页字段）由
/// `model/workspace_files.dart` 的 `FileListing.fromWire` / `FilePage.fromWire` 解析
/// —— 那是"值解析住 `model/`"的同一条（与 `parseTokenUsage` 一致）。
/// 这里只负责：**信封在不在**、**那一层是不是对象**。认不出 ⇒ [WireBad] + 计数，
/// 调用方如实报"电脑侧的应答形状认不出"（旧实现在这里 `StateError`，现在多了计数）。
///
/// 二进制文件由宿主拒（`workspace-file/not-text`）—— 那是错误码，不是形状，走 `lastError`。
///
/// Note: 布局与批次见 `.agents/notes/proposed/2026-10-25-wire-rpc-layer-layout.md`。
library;

import '../../core/sync_client.dart';
import '../../model/workspace_files.dart' show FileListing, FilePage;
import '../fields.dart';
import '../reading.dart';

/// 消费方一次拿齐"三态内核 + 字段内核 + 文件面解码"。
export '../fields.dart';
export '../reading.dart';

const String _kList = 'file.list';
const String _kRead = 'file.read';

/// 列一个目录（`path` 空串 = 工作区根）。
Future<FileListing?> loadFileListing(
  SyncClient client, {
  required String sid,
  required String path,
}) async {
  final result = await client.call<Object?>(_kList, {'sid': sid, 'path': path});
  return valueOrReport(readFileListing(result), _kList);
}

/// 读一页文本（`offset` / `limit` 缺省用宿主的页默认）。
Future<FilePage?> loadFilePage(
  SyncClient client, {
  required String sid,
  required String path,
  int? offset,
  int? limit,
}) async {
  final result = await client.call<Object?>(_kRead, {
    'sid': sid,
    'path': path,
    // ignore: use_null_aware_elements
    if (offset != null) 'offset': offset,
    // ignore: use_null_aware_elements
    if (limit != null) 'limit': limit,
  });
  return valueOrReport(readFilePage(result), _kRead);
}

/// `file.list` 的应答 `{listing}`。
WireReading<FileListing> readFileListing(Object? result) =>
    readObject(_kList, result, (fields) {
      final listing = FileListing.fromWire(fields.requireMap('listing'));
      if (listing == null) {
        throw const WireFieldError('listing 认不出（file.list）');
      }
      return listing;
    });

/// `file.read` 的应答 `{page}`。
WireReading<FilePage> readFilePage(Object? result) =>
    readObject(_kRead, result, (fields) {
      final page = FilePage.fromWire(fields.requireMap('page'));
      if (page == null) {
        throw const WireFieldError('page 认不出（file.read）');
      }
      return page;
    });
