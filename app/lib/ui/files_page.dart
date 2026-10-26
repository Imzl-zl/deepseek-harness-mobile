/// 文件页：**工作区目录浏览 + 文本预览**（契约 §5.7 的 `file.list` / `file.read`）。
///
/// ## 它接的是哪两个方法
///
/// 宿主的 `workspaceFiles.list` / `read`（`packages/api/workspace-files/src/index.ts:233-247`、
/// `:303-329`），scope 由连接的 `workspaceFileScope` lookup 按会话解析 —— 手机只给 `sid`
/// 与一条相对工作区的路径。
///
/// **只做"看"**：目录清单 + UTF-8 文本按行分页。`readBytes`（原样字节撞单帧预算）与
/// `changes`（另一条订阅面）不接；二进制文件由宿主拒（`workspace-file/not-text`），
/// 那句原话直接显示。
///
/// ## 路径从哪来
///
/// 宿主的清单里 `path` 是"相对工作区、根是空串"，子项的路径是 `父路径 + '/' + name`
/// （`types.ts:110-115` 的注释同一句）。手机**不解析归属**：点哪一行就把它拼成路径交给
/// 宿主，越界（`..`、绝对路径）由宿主判。
///
/// 取舍见 `.agents/notes/implemented/2026-10-24-workspace-file-browser.md`。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_model.dart';
import '../model/workspace_files.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';
import 'dsh_app_bar.dart';

/// 页面入口：进页拉一次根目录，之后自己管当前目录。
class FilesPageHost extends StatefulWidget {
  const FilesPageHost({super.key, required this.app});

  final AppModel app;

  @override
  State<FilesPageHost> createState() => _FilesPageHostState();
}

class _FilesPageHostState extends State<FilesPageHost> {
  /// 当前目录（相对工作区；`''` = 根）。
  String _path = '';
  FileListing? _listing;
  String? _failure;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    // 没有能力位就**连试都不试**（页面直接说"这台电脑没有文件服务"）。
    if (widget.app.filesAvailable) unawaited(_load(''));
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    final listing = await widget.app.listFiles(path);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (listing == null) {
        // **失败保留原来的清单吗？不。** 停在一个已经不存在的目录上比空态更难懂；
        // 失败态会把电脑侧的原话摆出来，用户知道该退回去。
        _failure = widget.app.lastError?.message ?? '读取目录失败';
        return;
      }
      _failure = null;
      _path = listing.path;
      _listing = listing;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final app = widget.app;
    return Scaffold(
      backgroundColor: c.bgBase,
      appBar: AppBar(
        backgroundColor: c.sidebar,
        foregroundColor: c.labelPrimary,
        leading: DshAppBarButton(
          icon: 'chevronLeft',
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          '文件',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: c.labelPrimary,
          ),
        ),
        actions: [
          if (app.filesAvailable)
            DshAppBarButton(
              icon: 'refresh',
              tooltip: '重新读取',
              onPressed: () => unawaited(_load(_path)),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: _body(context, app),
      ),
    );
  }

  List<Widget> _body(BuildContext context, AppModel app) {
    final c = context.dshColors;
    if (!app.filesAvailable) {
      // **离线 ≠ 没能力**：没读到 `repo.info` 时 `caps.files` 只是默认 false，
      // 说成"没有文件服务"会把用户引向"换连接器版本"，而下一步其实只是重连
      // （2026-10-26 真机踩到）。
      return [
        _FileHint(
          text: app.repoInfoKnown
              ? '这台电脑没有文件服务：连接器版本较旧，或没装 workspace-files。'
              : '还没连上电脑：连上后再看文件。',
        ),
      ];
    }
    final failure = _failure;
    if (failure != null) {
      return [
        _FileHint(text: '读取失败：$failure', color: c.stateError),
        const SizedBox(height: 8),
        const _FileHint(text: '点右上角刷新重试。'),
      ];
    }
    if (_loading && _listing == null) return const [_FileHint(text: '正在读取…')];
    final listing = _listing;
    if (listing == null) return const [_FileHint(text: '还没有读到目录。')];

    return [
      // 位置 + 上级（根目录时没有上级）。
      Row(
        children: [
          if (_path.isNotEmpty)
            TextButton(
              key: const ValueKey<String>('files-up'),
              onPressed: () => unawaited(_load(_parentOf(_path))),
              child: const Text('上级'),
            ),
          Expanded(
            child: Text(
              _path.isEmpty ? '工作区根' : _path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: c.labelCaption),
            ),
          ),
        ],
      ),
      if (listing.entries.isEmpty)
        const _FileHint(text: '这个目录是空的。')
      else
        for (final entry in listing.entries)
          _FileRow(entry: entry, onTap: () => _open(listing, entry)),
      if (listing.truncated) ...[
        const SizedBox(height: 8),
        // **截断要说**：宿主的条目上限砍掉了后面的项，假装列全是另一种撒谎。
        const _FileHint(text: '这个目录的条目超过这台电脑的上限，只列出了前面一部分。'),
      ],
    ];
  }

  void _open(FileListing listing, FileEntryRow entry) {
    final path = listing.pathOf(entry);
    if (entry.isDirectory) {
      unawaited(_load(path));
      return;
    }
    // 非普通文件（socket / 设备…）不提供预览：宿主 `read` 也会拒。
    if (entry.type != FileEntryType.file) return;
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => FilePreviewPage(app: widget.app, path: path),
        ),
      ),
    );
  }
}

/// 上级目录（`a/b/c` → `a/b`，`a` → 根）。
String _parentOf(String path) {
  final at = path.lastIndexOf('/');
  return at <= 0 ? '' : path.substring(0, at);
}

/// 目录里的一行。
class _FileRow extends StatelessWidget {
  const _FileRow({required this.entry, required this.onTap});

  final FileEntryRow entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final dim = entry.type != FileEntryType.file && !entry.isDirectory;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: c.layer1,
        borderRadius: BorderRadius.circular(DshRadius.md),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // 非普通文件不给点（点了也没有可看的内容）。
        onTap: dim ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              DshIcon(
                entry.isDirectory ? 'folderClose' : 'deliverDoc',
                size: 14,
                color: c.labelCaption,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: c.labelPrimary),
                ),
              ),
              if (entry.size > 0)
                Text(
                  _sizeOf(entry.size),
                  style: TextStyle(fontSize: 11, color: c.labelCaption),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 字节数：≥1 MiB 用 MB、≥1 KiB 用 KB、再小给字节（与图片上限那句话同一套口径）。
  static String _sizeOf(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }
}

/// 文本预览：**按行分页**读，`eof` 之前可以"加载更多"。
class FilePreviewPage extends StatefulWidget {
  const FilePreviewPage({super.key, required this.app, required this.path});

  final AppModel app;
  final String path;

  @override
  State<FilePreviewPage> createState() => _FilePreviewPageState();
}

class _FilePreviewPageState extends State<FilePreviewPage> {
  final List<String> _chunks = [];
  String? _failure;
  bool _loading = false;
  bool _eof = true;
  int _nextOffset = 1;
  int _lines = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    final page = await widget.app.readFile(
      widget.path,
      offset: _chunks.isEmpty ? null : _nextOffset,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (page == null) {
        _failure = widget.app.lastError?.message ?? '读取文件失败';
        return;
      }
      // **空页也要落一处**：一页空行（`lines > 0` 但 `text` 为空）与"越过末行"
      // （`lines == 0`）是两件事，前者有内容、后者没有。
      if (page.lines > 0) _chunks.add(page.text);
      _lines += page.lines;
      _eof = page.eof;
      _nextOffset = page.nextOffset;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Scaffold(
      backgroundColor: c.bgBase,
      appBar: AppBar(
        backgroundColor: c.sidebar,
        foregroundColor: c.labelPrimary,
        leading: DshAppBarButton(
          icon: 'chevronLeft',
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          widget.path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, color: c.labelPrimary),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          if (_failure != null) ...[
            _FileHint(text: '读取失败：$_failure', color: c.stateError),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
          if (_chunks.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.layer1,
                borderRadius: BorderRadius.circular(DshRadius.md),
              ),
              child: SelectableText(
                _chunks.join('\n'),
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 19 / 12,
                  color: c.labelSecondary,
                ),
              ),
            ),
          const SizedBox(height: 10),
          if (_lines > 0)
            _FileHint(text: _eof ? '共 $_lines 行（已到末尾）' : '已读 $_lines 行'),
          if (!_eof && _failure == null)
            TextButton(
              key: const ValueKey<String>('files-more'),
              onPressed: _loading ? null : _load,
              child: Text(_loading ? '正在读取…' : '加载更多'),
            ),
        ],
      ),
    );
  }
}

/// 一句话提示（老连接器 / 加载中 / 读失败 / 空目录）。
class _FileHint extends StatelessWidget {
  const _FileHint({required this.text, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: color ?? c.labelSecondary),
      ),
    );
  }
}
