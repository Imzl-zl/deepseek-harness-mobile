/// 右抽屉「文件」区的面板体：改动清单 / 已打开的文件 / 空态。
///
/// ## 它是从 `chat_page.dart` 搬出来的，不是新写的
///
/// 原位置在 `chat_page.dart` 的 `_countsOf`（现 `diffCountsOf`）与 `_TrajectoryTab` 之间，
/// 约 470 行：文件面板与改动卡共享的那两个数字标记、四个面板 widget、空态。搬的理由只有一个 ——
/// `ui/chat_page.dart` 的行数是**棘轮门禁**（`app/tools/verify-size.mjs`：只降不升），
/// 而上一轮两次想加组件都被它拦下。**真正的收窄不是拆组件，是把一整块面板搬走。**
///
/// 判据是"只搬、不改行为"：搬完 `flutter test` 一条用例都没改，`_ChangedFilesCard`
/// 那两条判据（`app.changesFailureOf` / `changesAvailable`）原样带过来。
/// 改名只发生在 `_foo` → `Foo` 这一层 —— 跨库引用不了私有名，那是搬移的机械代价。
///
/// 决策与代价见 `.agents/notes/implemented/2026-11-12-chat-page-files-pane-move.md`。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_model.dart';
import '../model/changes.dart';
import '../model/file_diff.dart';
import '../model/file_open.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';
import 'dsh_code_highlight.dart';
import 'dsh_diff.dart';
import 'dsh_markdown.dart';
import 'dsh_toast.dart';

/// `+N` / `-M`，或宿主的两个"没有行数"标记（`changes.binary` / `changes.oversized`）。
///
/// 卡片与侧栏**同一份**（两处各写一遍必然漂成"卡片说 +9、侧栏说 +0"）。
Widget diffCountsOf(
  BuildContext context, {
  required int added,
  required int deleted,
  required bool binary,
  required bool oversized,
}) {
  final c = context.dshColors;
  if (binary || oversized) {
    return Text(
      binary ? '二进制' : '过大',
      style: TextStyle(fontSize: 11, color: c.labelCaption),
    );
  }
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        '+$added',
        style: TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          color: c.codeDiffAdd,
        ),
      ),
      const SizedBox(width: 4),
      Text(
        '-$deleted',
        style: TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          color: c.codeDiffDel,
        ),
      ),
    ],
  );
}

/// 文件面板的空态（差异 / 文件两个 tab 共用）。
///
/// **2026-10-15 删掉假 diff**：原来是 `sampleDiff` / `sampleFileLines`
/// 两份写死的样例，而调用方**无条件**传给 `DshDiff` / `DshCodeLines` ——
/// 于是真连上了打开文件抽屉，也会看到一段本项目 `chat_page.dart` 的假 diff，
/// **没有任何"示例"标记**。这是假数据里最坏的一处：它冒充真数据。
///
/// 真数据通路：`deliverables` 投影（diff）+ `workspace-files` 的
/// `read` / `list`（文件树与内容）。接上之前说"还没接"，不造假的。
/// 右侧「文件」面板里**真的改动清单**。
///
/// 数据来自工具调用（`AppModel.changedFiles`，判据照 DSH 的 `mutationPath`），
/// 不是编的。两个页签同一份数据：`文件` 看路径，`差异` 看路径 + 行数增量
/// （增量来自 `tool/result` 的 `metadata.diffs`，见 `ToolCallItem.diffStat`）。
///
/// **没有行数增量的行不显示 `+0 −0`**：那会把"不知道增了多少"说成"没变"。
/// 侧栏「差异 / 文件」两份视图，数据是**桌面那一轮改动记录**（`file.changes`）。
///
/// 与改动卡同一份记录、同一套 `diffCountsOf`：两处数字口径不可能不同。
/// 「差异」行点开逐行差异（`file.diff`，坐标 `seq`+下标），「文件」行点开内容预览。
class ChangesPane extends StatefulWidget {
  const ChangesPane({
    super.key,
    required this.app,
    required this.seq,
    required this.tab,
  });

  final AppModel app;

  /// `workspace/changes` 事件的 seq（查询坐标）。
  final int seq;

  /// `0` = 差异；`1` = 文件。
  final int tab;

  @override
  State<ChangesPane> createState() => ChangesPaneState();
}

class ChangesPaneState extends State<ChangesPane> {
  @override
  void initState() {
    super.initState();
    // 下一帧再拉：`loadChangesSummary` 会同步通知祖先（同 `_ChangedFilesCard`）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureLoaded();
    });
  }

  void _ensureLoaded() {
    final app = widget.app;
    if (app.changesStateOf(widget.seq).loaded) return;
    if (app.changesLoading(widget.seq)) return;
    if (app.changesFailureOf(widget.seq) != null) return;
    unawaited(app.loadChangesSummary(widget.seq));
  }

  void _openRow(AppModel app, ChangedFile file, int index) {
    if (widget.tab == 0) {
      unawaited(
        app.openFile(
          FileOpenRequest(
            path: file.path,
            mode: FileOpenMode.diff,
            seq: widget.seq,
            index: index,
          ),
        ),
      );
      return;
    }
    unawaited(app.openFile(FileOpenRequest(path: file.path)));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final app = widget.app;
        final failure = app.changesFailureOf(widget.seq);
        if (failure != null) {
          return ListView(
            padding: const EdgeInsets.all(14),
            children: [
              Text(
                '改动记录读取失败：$failure',
                style: TextStyle(fontSize: 12, color: c.stateError),
              ),
              TextButton(
                onPressed: () => unawaited(app.loadChangesSummary(widget.seq)),
                child: const Text('重试'),
              ),
            ],
          );
        }
        final state = app.changesStateOf(widget.seq);
        if (!state.loaded) {
          return Center(
            child: Text(
              '正在读取改动…',
              style: TextStyle(fontSize: 12, color: c.labelTertiary),
            ),
          );
        }
        final summary = state.summary;
        if (summary == null) {
          return EmptyFilePane(kind: widget.tab == 0 ? 'diff' : 'file');
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: summary.files.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 0.5, thickness: 0.5, color: c.borderL3),
                itemBuilder: (context, index) {
                  final file = summary.files[index];
                  // 行是手写的 `InkWell`：它只装点击动作、不装按钮角色，
                  // 朗读器念完文件名与 `+N −M` 就停。角色由这里报；
                  // 行内文字仍是子节点（**不合并**，理由同 `settings_row.dart`）。
                  return Semantics(
                    key: ValueKey<String>('changed-file-$index'),
                    button: true,
                    child: InkWell(
                      onTap: () => _openRow(app, file, index),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            DshIcon(
                              'deliverDoc',
                              size: 14,
                              color: c.labelTertiary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                file.display,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.35,
                                  fontFamily: 'monospace',
                                  color: c.labelPrimary,
                                ),
                              ),
                            ),
                            if (widget.tab == 0) ...[
                              const SizedBox(width: 8),
                              diffCountsOf(
                                context,
                                added: file.added,
                                deleted: file.deleted,
                                binary: file.binary,
                                oversized: file.oversized,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (summary.truncated)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Text(
                  '还有 ${summary.total - summary.files.length} 个文件没列出（超过电脑侧上限）',
                  style: TextStyle(fontSize: 11, color: c.labelCaption),
                ),
              ),
          ],
        );
      },
    );
  }
}

class ChangedFileList extends StatelessWidget {
  const ChangedFileList({
    super.key,
    required this.rows,
    required this.showStat,
  });

  final List<({String path, ({int added, int removed})? stat})> rows;

  /// `true` = 「差异」页签（显示行数增量）。
  final bool showStat;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: rows.length,
      separatorBuilder: (_, _) =>
          Divider(height: 0.5, thickness: 0.5, color: c.borderL3),
      itemBuilder: (context, index) {
        final row = rows[index];
        final stat = row.stat;
        return Semantics(
          key: ValueKey<String>('changed-path-${row.path}'),
          button: true,
          child: InkWell(
            // **点一行复制它的路径**（2026-10-20）。
            //
            // 这个动作先前被删掉过：那时面板里根本没有路径可复制，三个按钮
            // 只会弹「还没做」。留下的话写在删它的注释里 ——
            // 「等文件面板接上真的 deliverables 再一起做 —— 那时"复制路径"
            // 才有路径可复制」。现在条件满足了：清单是真的（来自工具调用），
            // 所以这个动作也是真的。
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: row.path));
              if (!context.mounted) return;
              DshToast.show(context, '已复制 ${row.path}');
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  DshIcon('deliverDoc', size: 14, color: c.labelTertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      row.path,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        fontFamily: 'monospace',
                        color: c.labelPrimary,
                      ),
                    ),
                  ),
                  if (showStat && stat != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      '+${stat.added}',
                      style: TextStyle(fontSize: 11, color: c.codeDiffAdd),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '−${stat.removed}',
                      style: TextStyle(fontSize: 11, color: c.codeDiffDel),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 右抽屉里"正在看的那一份文件"。
///
/// 数据全部来自 `AppModel`（`openFile` 是唯一入口）：这里只画三态 ——
/// 读失败（电脑侧原话）/ 正在读 / 已读到。**没有"加载中"之外的假内容**：
/// 空正文就是空正文，不是"文件不存在"。
class OpenedFileBody extends StatelessWidget {
  const OpenedFileBody({super.key, required this.app});

  final AppModel app;

  @override
  Widget build(BuildContext context) {
    // **自己听模型**：抽屉是独立路由，外层重建到不了它（与子智能体 sheet 同一条），
    // 而"读完了"是一次异步到达 —— 不自己听就永远停在「正在读取…」。
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => _content(context),
    );
  }

  Widget _content(BuildContext context) {
    final c = context.dshColors;
    final request = app.fileOpenRequest;
    final isDiff = request?.mode == FileOpenMode.diff;
    final opened = app.openedFile;
    final failure = isDiff ? app.diffFailure : app.fileFailure;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 关掉这份文件的入口（回到改动清单）。面板的标题栏那枚收起钮收的是
        // 整个抽屉，与"收起这个文件"不是一件事。
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
            child: TextButton.icon(
              key: const ValueKey<String>('file-open-back'),
              onPressed: app.closeFile,
              icon: DshIcon('chevronLeft', size: 14, color: c.labelSecondary),
              label: const Text('返回改动'),
            ),
          ),
        ),
        Expanded(
          child: isDiff
              ? _diffBody(context, failure, request!)
              : failure != null
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    failure,
                    style: TextStyle(fontSize: 12, color: c.stateError),
                  ),
                )
              : opened == null
              ? Center(
                  child: Text(
                    '正在读取…',
                    style: TextStyle(fontSize: 12, color: c.labelTertiary),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: c.layer1,
                          borderRadius: BorderRadius.circular(DshRadius.md),
                        ),
                        // **Markdown 按 Markdown 渲染**（桌面
                        // `ui-sidebar-documentpreview/src/client/markdown/index.ts:17`
                        // 把 md/markdown 交给 Markdown viewer）；其余仍按代码字体
                        // —— 它们是给模型看的原文，换字体只会更难扫。
                        child: isMarkdownPath(opened.request.path)
                            ? DshMarkdown(opened.text)
                            : _openedCodeBody(context, opened),
                      ),
                      const SizedBox(height: 10),
                      if (opened.lines > 0)
                        Text(
                          opened.eof
                              ? '共 ${opened.lines} 行（已到末尾）'
                              : '已读 ${opened.lines} 行',
                          style: TextStyle(fontSize: 11, color: c.labelCaption),
                        ),
                      if (!opened.eof && !app.fileLoading)
                        TextButton(
                          key: const ValueKey<String>('file-open-more'),
                          onPressed: () => unawaited(app.loadMoreOpenedFile()),
                          child: const Text('加载更多'),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  /// 文本 / 代码正文：**认得出的后缀就上语法高亮**（`dsh_code_highlight.dart`），
  /// 认不出就按等宽纯文本 —— 与 Markdown 那档同一条原则：能做的本地做，不做假。
  Widget _openedCodeBody(BuildContext context, OpenedFile opened) {
    final c = context.dshColors;
    final style = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      height: 19 / 12,
      color: c.labelSecondary,
    );
    final span = highlightCode(
      opened.text,
      languageForPath(opened.request.path),
      base: style,
      dark: Theme.of(context).brightness == Brightness.dark,
    );
    return span == null
        ? SelectableText(opened.text, style: style)
        : SelectableText.rich(span);
  }

  /// 逐行差异（`file.diff`）的五种结局，文案与桌面同一份词典
  /// （`ui-deliverables/src/client/locales.ts:58-67`）。
  Widget _diffBody(
    BuildContext context,
    String? failure,
    FileOpenRequest request,
  ) {
    final c = context.dshColors;
    if (failure != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '无法读取改动：$failure',
              style: TextStyle(fontSize: 12, color: c.stateError),
            ),
            TextButton(
              onPressed: () => unawaited(app.openFile(request)),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (app.diffLoading) return _diffNote(context, '正在读取改动…');
    final diff = app.openedDiff;
    // 电脑侧没有这条记录（会话已释放 / 没记录过）—— 与桌面 `diff.missing` 同一句话。
    if (diff == null) return _diffNote(context, '这轮改动的内容已不可用');
    if (diff.isBinary) return _diffNote(context, '二进制文件，无法显示改动');
    if (diff.isOversized) return _diffNote(context, '文件过大，无法显示改动');
    final notes = <String>[
      if (!diff.before) '本轮新建的文件',
      if (!diff.after) '本轮删除的文件',
      if (diff.before && diff.after && diff.hunks.isEmpty) '两侧内容相同',
      if (diff.coarse) '逐行对比超时，按整个文件替换显示',
      if (diff.truncated != null)
        '只显示前 ${diff.truncated!.shownLines} 行（共 ${diff.truncated!.totalLines} 行）',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final note in notes)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(
              note,
              style: TextStyle(fontSize: 11, color: c.labelCaption),
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: DshDiff(diffLinesOfHunks(diff.hunks)),
          ),
        ),
      ],
    );
  }

  Widget _diffNote(BuildContext context, String text) {
    final c = context.dshColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: c.labelTertiary),
        ),
      ),
    );
  }
}

class EmptyFilePane extends StatelessWidget {
  const EmptyFilePane({super.key, required this.kind});

  /// `diff` / `file`。
  final String kind;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final isDiff = kind == 'diff';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DshIcon(
              isDiff ? 'deliverDoc' : 'folderClose',
              size: 40,
              color: c.labelTertiary,
            ),
            const SizedBox(height: 16),
            Text(
              isDiff ? '还没有改动' : '还没有文件内容',
              style: TextStyle(fontSize: 15, color: c.labelSecondary),
            ),
            const SizedBox(height: 8),
            Text(
              isDiff
                  ? '电脑侧这一轮改了什么，会在这里列成差异。\n'
                        '数据来自会话投影 deliverables。'
                  : '在电脑上选中一个文件，这里显示它的内容。\n'
                        '数据来自 workspace-files 的 read / list。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: c.labelTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
