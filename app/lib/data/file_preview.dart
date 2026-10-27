/// 文件预览：打开 / 分页 / 逐行差异的**状态与读取**。
///
/// ## 为什么单独成类
///
/// 三个入口（正文提及、改动卡行、侧栏差异行）加文件页，四个调用点共用同一个
/// `openFile`，而它带着 6 个状态位（请求 / 序号 / 内容 / 三个 loading+failure）。
/// 收窄计划把它整簇搬出来（`.agents/notes/proposed/2026-10-27-appmodel-narrowing.md`
/// 第二簇的最后一个）。
///
/// ## 边界
///
/// - 能力位与"连上了吗"由装配方给（[filesAvailable] / [changesAvailable] /
///   [repoInfoKnown]）：这一层不认识 `repo.info` 的解析；
/// - 失败原因**不自己编**：交给 [recordError] 记进 `AppModel.lastError`，
///   这里只读 [lastErrorMessage]（与搬移前逐字一致）；
/// - 通知走 [onChange]，`_disposed` 守卫在装配方。
library;

import '../core/sync_client.dart';
import '../model/file_diff.dart';
import '../model/file_open.dart';
import '../model/workspace_files.dart' show FilePage;
import '../wire/rpc/changes.dart' as wire;
import '../wire/rpc/file.dart' as wire;

class FilePreview {
  FilePreview({
    required this.client,
    required this.sidOf,
    required this.filesAvailable,
    required this.changesAvailable,
    required this.repoInfoKnown,
    required this.recordError,
    required this.lastErrorMessage,
    required this.onChange,
  });

  final SyncClient client;

  /// 当前会话（`file.read` / `file.diff` 的 scope 由宿主按它解析）。
  final String? Function() sidOf;

  final bool Function() filesAvailable;
  final bool Function() changesAvailable;
  final bool Function() repoInfoKnown;

  /// 记错（进 `AppModel.lastError`，界面据此显示原因）。
  final void Function(String what, Object error) recordError;

  /// 最近一次错误的消息（失败原因的**唯一来源**）。
  final String? Function() lastErrorMessage;

  final void Function() onChange;

  FileOpenRequest? get request => _request;
  FileOpenRequest? _request;

  /// 请求序号：**每次打开都 +1**（同一个路径连点两次也要再开一次，
  /// 所以不能拿请求值本身当判据 —— 它按值相等）。
  int get ticket => _ticket;
  int _ticket = 0;

  OpenedFile? get openedFile => _opened;
  OpenedFile? _opened;

  bool get loading => _loading;
  bool _loading = false;

  String? get failure => _failure;
  String? _failure;

  FileDiff? get diff => _diff;
  FileDiff? _diff;

  bool get diffLoading => _diffLoading;
  bool _diffLoading = false;

  String? get diffFailure => _diffFailure;
  String? _diffFailure;

  /// 读一页文本（`offset` / `limit` 不传就用宿主的页默认）。
  ///
  /// 二进制文件由宿主拒（`workspace-file/not-text`），原因同样进 `lastError`。
  Future<FilePage?> readPage(String path, {int? offset, int? limit}) async {
    if (!filesAvailable()) return null;
    final sid = sidOf();
    if (sid == null) {
      recordError('读取文件失败', StateError('还没有选中的会话'));
      return null;
    }
    try {
      // 形状（`{page}` 信封 + 本体）在 `wire/rpc/file.dart`。
      final page = await wire.loadFilePage(
        client,
        sid: sid,
        path: path,
        offset: offset,
        limit: limit,
      );
      if (page == null) {
        recordError('读取文件失败', StateError('电脑侧的文件应答形状认不出'));
        return null;
      }
      return page;
    } catch (error) {
      recordError('读取文件失败', error);
      return null;
    }
  }

  /// 打开一个文件。**所有入口只走它**（正文提及 / 改动卡行 / 侧栏差异行 / 文件页）。
  ///
  /// 路径**原样**交给 `file.read`：scope 由宿主按会话解析（`model/file_open.dart`）。
  /// 只读第一页；"加载更多"走 [loadMore]。
  Future<void> open(FileOpenRequest next) async {
    _ticket += 1;
    _request = next;
    _opened = null;
    _diff = null;
    _failure = null;
    _diffFailure = null;
    _diffLoading = false;
    // **没有能力位就不发请求**：老连接器上 `file.read` 不存在，发出去只会拿一个
    // `connector/unsupported`，而它会被画成"读取失败"。
    if (next.mode == FileOpenMode.diff) {
      // 差异面与文件面**同一个能力位**（宿主 `workspaceChanges` 在不在）。
      if (!changesAvailable()) {
        _diffFailure = repoInfoKnown()
            ? '这台电脑没有改动记录：连接器版本较旧，或没装 workspace-changes。'
            : '还没连上电脑：连上后再看改动。';
        onChange();
        return;
      }
      final seq = next.seq;
      final index = next.index;
      if (seq == null || index == null) {
        // 坐标不全会请求到"另一个文件的 diff"——那是比报错更坏的结果。
        _diffFailure = '缺少这一轮的坐标（seq / index），打不开逐行差异。';
        onChange();
        return;
      }
      _diffLoading = true;
      onChange();
      try {
        final result = await wire.loadFileDiff(
          client,
          sid: sidOf()!,
          seq: seq,
          index: index,
        );
        _diff = result;
      } catch (error) {
        recordError('读取改动失败', error);
        _diffFailure = lastErrorMessage() ?? '读取改动失败';
      } finally {
        _diffLoading = false;
        onChange();
      }
      return;
    }
    if (!filesAvailable()) {
      _failure = repoInfoKnown()
          ? '这台电脑没有文件服务：连接器版本较旧，或没装 workspace-files。'
          : '还没连上电脑：连上后再看文件。';
      onChange();
      return;
    }
    _loading = true;
    onChange();
    final page = await readPage(next.path);
    _loading = false;
    if (page == null) {
      _failure = lastErrorMessage() ?? '读取文件失败';
    } else {
      _opened = OpenedFile(
        request: next,
        text: page.text,
        lines: page.lines,
        eof: page.eof,
        nextOffset: page.nextOffset,
        bytes: page.bytes,
      );
    }
    onChange();
  }

  /// 接着读下一页（`eof` 之后是空操作）。
  Future<void> loadMore() async {
    final current = _opened;
    if (current == null || current.eof || _loading) return;
    _loading = true;
    onChange();
    final page = await readPage(
      current.request.path,
      offset: current.nextOffset,
    );
    _loading = false;
    if (page == null) {
      _failure = lastErrorMessage() ?? '读取文件失败';
    } else {
      _opened = current.appended(
        text: page.text,
        lines: page.lines,
        eof: page.eof,
        nextOffset: page.nextOffset,
        bytes: page.bytes,
      );
    }
    onChange();
  }

  /// 收起当前打开的文件（侧栏回到改动清单 / 文件页返回列表）。
  void close() {
    if (_request == null && _opened == null && _failure == null) return;
    _request = null;
    _opened = null;
    _diff = null;
    _failure = null;
    _diffFailure = null;
    _loading = false;
    _diffLoading = false;
    onChange();
  }
}
