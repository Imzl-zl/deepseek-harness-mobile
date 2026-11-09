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
import '../model/file_open.dart';
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
          Expanded(child: _breadcrumbs(context)),
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

  /// 面包屑：根 → … → 当前目录，每一段都能点回去。
  ///
  /// 桌面那棵"常驻目录树"在手机窄屏上放不下一整棵树；这条**可点的路径链**提供同一件事：
  /// 知道自己在哪、能跳回任意祖先。**不假装是树**（没有展开/收起，也不列兄弟目录）。
  ///
  /// 当前目录那一段禁用：点它没有意义（已经在里面）。
  Widget _breadcrumbs(BuildContext context) {
    final c = context.dshColors;
    final segments = _path.isEmpty ? const <String>[] : _path.split('/');
    final crumbs = <Widget>[
      TextButton(
        key: const ValueKey<String>('files-crumb-root'),
        onPressed: _path.isEmpty ? null : () => unawaited(_load('')),
        child: const Text('工作区根', style: TextStyle(fontSize: 12)),
      ),
    ];
    var accumulated = '';
    for (final segment in segments) {
      if (segment.isEmpty) continue;
      accumulated = accumulated.isEmpty ? segment : '$accumulated/$segment';
      final target = accumulated;
      crumbs.add(
        Text('›', style: TextStyle(fontSize: 12, color: c.labelTertiary)),
      );
      crumbs.add(
        TextButton(
          key: ValueKey<String>('files-crumb-$target'),
          onPressed: target == _path ? null : () => unawaited(_load(target)),
          child: Text(segment, style: const TextStyle(fontSize: 12)),
        ),
      );
    }
    // 长路径横向滚，不换行：面包屑一旦折成两行就会把目录清单往下挤。
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: crumbs),
    );
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

/// 预览正文 → 带行号的行（`number` 从 1 起）。
///
/// 编号是**文件行号**，不是 `model/diff.dart` 的 `DiffLine`：那是 diff 的双列
/// （旧/新两侧各一套行号），这里只有一列、只有"这一份文件的第几行"。
///
/// 末尾那个换行不算一行 —— 否则每一份以换行结尾的文件都会多出一个空号。
/// 分页是**追加**（`AppModel.loadMoreOpenedFile`），所以 1..N 始终对得上文件行号。
///
/// Note: 为什么单列、为什么用面包屑而不是目录树 —— 见
/// `.agents/notes/implemented/2026-11-09-files-page-line-numbers-breadcrumbs.md`
List<({int number, String text})> filePreviewLines(String text) {
  if (text.isEmpty) return const [];
  final lines = text.split('\n');
  if (lines.last.isEmpty) lines.removeLast();
  return [
    for (var i = 0; i < lines.length; i += 1) (number: i + 1, text: lines[i]),
  ];
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
///
/// ## 它不自己读文件
///
/// 打开走 `AppModel.openFile`（**四个入口唯一的那个动作**），内容与分页状态都在
/// 模型里（`OpenedFile`）；这一页只画三态。自己再维护一份 chunks 就是第二份真值 ——
/// 同一个文件在右抽屉里看一半、在文件页里又从头读，两处会各说各的。
class FilePreviewPage extends StatefulWidget {
  const FilePreviewPage({super.key, required this.app, required this.path});

  final AppModel app;
  final String path;

  @override
  State<FilePreviewPage> createState() => _FilePreviewPageState();
}

class _FilePreviewPageState extends State<FilePreviewPage> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.app.openFile(FileOpenRequest(path: widget.path)));
  }

  @override
  void dispose() {
    // 离开这一页 = 不再"正看着某个文件"（模型里只有一份这样的状态）。
    widget.app.closeFile();
    super.dispose();
  }

  /// 正文 + 行号。
  ///
  /// 行号是**装饰**：弱色、与正文同一个等宽体，`SelectableText.rich` 仍可整段选中复制。
  /// 宽度按最大的那个号补齐，所以 9 行与 10 行不会让正文错位。
  Widget _numberedText(BuildContext context, String text) {
    final c = context.dshColors;
    final lines = filePreviewLines(text);
    final width = lines.isEmpty ? 1 : lines.last.number.toString().length;
    return SelectableText.rich(
      TextSpan(
        children: [
          for (var i = 0; i < lines.length; i += 1) ...[
            TextSpan(
              text: '${lines[i].number.toString().padLeft(width)} ',
              style: TextStyle(color: c.labelCaption),
            ),
            TextSpan(text: lines[i].text),
            if (i != lines.length - 1) const TextSpan(text: '\n'),
          ],
        ],
      ),
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        height: 19 / 12,
        color: c.labelSecondary,
      ),
    );
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
          widget.path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, color: c.labelPrimary),
        ),
      ),
      // **必须听模型**：内容在打开完成之后才到，这一页自己不 setState。
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final opened = app.openedFile;
          final failure = app.fileFailure;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              if (failure != null) ...[
                // **不再加「读取失败：」前缀**：`app.fileFailure` 已经是
                // `model/file_failure.dart` 给出的**整句**（四类码各有自己的中文，
                // 表外码才带「读取失败：{宿主原话}」）。加前缀会把四类文案改成
                // 「读取失败：找不到这个文件」、把表外码变成双前缀 ——
                // 桌面 `failureLine()` 只画那一句（`failure-line.ts:24-35`）。
                _FileHint(text: failure, color: c.stateError),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => unawaited(
                    app.openFile(FileOpenRequest(path: widget.path)),
                  ),
                  child: const Text('重试'),
                ),
              ],
              if (opened != null && opened.lines > 0)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: c.layer1,
                    borderRadius: BorderRadius.circular(DshRadius.md),
                  ),
                  child: _numberedText(context, opened.text),
                ),
              const SizedBox(height: 10),
              if (opened != null && opened.lines > 0)
                _FileHint(
                  text: opened.eof
                      ? '共 ${opened.lines} 行（已到末尾）'
                      : '已读 ${opened.lines} 行',
                ),
              if (opened == null && failure == null)
                const _FileHint(text: '正在读取…'),
              if (opened != null && !opened.eof && failure == null)
                TextButton(
                  key: const ValueKey<String>('files-more'),
                  onPressed: app.fileLoading
                      ? null
                      : () => unawaited(app.loadMoreOpenedFile()),
                  child: Text(app.fileLoading ? '正在读取…' : '加载更多'),
                ),
            ],
          );
        },
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
