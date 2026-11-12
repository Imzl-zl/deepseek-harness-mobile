/// 会话流里的**改动卡**（桌面 `ui-deliverables/src/client/ChangedFiles.tsx`）。
///
/// ## 它是从 `chat_page.dart` 搬出来的，不是新写的
///
/// 原位置在 `chat_page.dart` 的 `_ChangedFilesCard` / `_ChangedFilesCardState`
/// （约 227 行，紧随 `_TurnView` 之后）。搬的理由只有一个 —— `ui/chat_page.dart` 的行数是
/// **棘轮门禁**（`app/tools/verify-size.mjs`：只降不升），而"拆组件"不减页面那一行。
/// **真正的收窄不是拆组件，是把一整块面搬走。**
///
/// 判据是"只搬、不改行为"：搬完 `flutter test` 一条用例都没改（`changes_card_test` 的
/// 五条判据原样通过）。改名只发生在 `_foo` → `Foo` 这一层 —— 跨库引用不了私有名。
///
/// ## 为什么单独一个文件，而不是并进 `ui/files_pane.dart`
///
/// 它们读同一份 `file.changes`、共用 `diffCountsOf`，看起来同族；但**物理位置不同**：
/// 这张卡是**会话流里的条目**（参与消息列表、轮组与事件投影），文件面板是**右抽屉里的一块**。
/// 上一批的笔记已经按这条理由拒过一次（`2026-11-12-chat-page-files-pane-move.md`），
/// 这次搬走它也不改变那个事实：两个文件各自回答"这块面长什么样"。
/// 并进 `files_pane.dart` 还会把那个文件顶到 800 行默认上限之上。
///
/// ## 数据是电脑的记录，手机只画
///
/// 标题用**完整**文件数（宿主的 `total`，含被 `maxFiles` 截掉的），行用宿主给的
/// `display`，"二进制 / 过大"是宿主的两个标记（`workspace-changes/src/types.ts:14-21`）。
/// 手机不拿工具调用自己推 `+N −M` —— 那会与桌面不同源。
///
/// ## 交互
///
/// 行点击与标题点击都只走 `AppModel.openFile`（唯一打开动作）；标题点第一个文件
/// （逐行差异要等 `file.diff`，方案笔记批 C）。
///
/// ## 三态
///
/// 没读到 ⇒ **不画**（桌面也是拿到记录才出现）；电脑侧没有这条记录（`summary:null`）
/// ⇒ 不画；读失败 ⇒ 把电脑侧原话摆出来 + 重试（不静默）。
///
/// 决策与代价见 `.agents/notes/implemented/2026-11-12-chat-page-second-cut.md`。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_model.dart';
import '../model/changes.dart';
import '../model/file_open.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';
import 'files_pane.dart' show diffCountsOf;

class ChangedFilesCard extends StatefulWidget {
  const ChangedFilesCard({super.key, required this.app, required this.seq});

  /// 会话模型；`null` = 不画（预览 / 测试里没有模型时）。
  final AppModel? app;

  /// `workspace/changes` 事件的序号 —— 向电脑要记录的唯一坐标。
  final int seq;

  @override
  State<ChangedFilesCard> createState() => ChangedFilesCardState();
}

class ChangedFilesCardState extends State<ChangedFilesCard> {
  /// 桌面默认只露四行（`ChangedFiles.tsx:18` 的 `COLLAPSED_ROWS`）。
  static const int _collapsedRows = 4;

  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    // **下一帧再拉**：`loadChangesSummary` 会同步 `notifyListeners`，而在 initState 里
    // 通知祖先（`main.dart` 的 ListenableBuilder）等于在 build 期间标脏 —— Flutter
    // 会直接断言。等这一帧过去就没有这个窗口。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureLoaded();
    });
  }

  void _ensureLoaded() {
    final app = widget.app;
    if (app == null || !app.changesAvailable) return;
    if (app.changesLoading(widget.seq)) return;
    if (app.changesStateOf(widget.seq).loaded) return;
    if (app.changesFailureOf(widget.seq) != null) return;
    unawaited(app.loadChangesSummary(widget.seq));
  }

  void _open(AppModel app, String path) {
    unawaited(app.openFile(FileOpenRequest(path: path)));
  }

  /// 打开这一轮里第 [index] 个文件的**逐行差异**（坐标 = 事件 seq + 下标）。
  void _openDiff(AppModel app, String path, int index) {
    unawaited(
      app.openFile(
        FileOpenRequest(
          path: path,
          mode: FileOpenMode.diff,
          seq: widget.seq,
          index: index,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    if (app == null || !app.changesAvailable) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final failure = app.changesFailureOf(widget.seq);
        if (failure != null) return _failure(context, app, failure);
        final state = app.changesStateOf(widget.seq);
        // 没读到 / 电脑侧没有记录：不画（不是失败）。
        if (!state.loaded || state.summary == null) {
          return const SizedBox.shrink();
        }
        return _card(context, app, state.summary!);
      },
    );
  }

  Widget _failure(BuildContext context, AppModel app, String failure) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          DshIcon('warningTriangle', size: 14, color: c.stateError),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '改动记录读取失败：$failure',
              style: TextStyle(fontSize: 12, color: c.stateError),
            ),
          ),
          TextButton(
            onPressed: () => unawaited(app.loadChangesSummary(widget.seq)),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, AppModel app, ChangesSummary summary) {
    final c = context.dshColors;
    final single = summary.total == 1 && summary.files.isNotEmpty
        ? summary.files.first
        : null;
    final rows = _expanded
        ? summary.files
        : summary.files.take(_collapsedRows).toList(growable: false);
    final foldable = summary.files.length > _collapsedRows;
    final title = single == null
        ? '已编辑 ${summary.total} 个文件'
        : '已编辑 ${fileNameOf(single.path)}';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: c.layer1,
        borderRadius: BorderRadius.circular(DshRadius.md),
        border: Border.all(color: c.layer2),
      ),
      clipBehavior: Clip.antiAlias,
      // `InkWell` 要 `Material` 祖先才画水波（`SidePane` 里同一处注释）。
      child: Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              // 标题点开**逐行差异**（桌面点卡头开的是本轮 review 的第一个文件）。
              onTap: summary.files.isEmpty
                  ? null
                  : () => _openDiff(app, summary.files.first.path, 0),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Row(
                  children: [
                    DshIcon('deliverDoc', size: 16, color: c.labelSecondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: c.labelPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    diffCountsOf(
                      context,
                      added: summary.added,
                      deleted: summary.deleted,
                      binary: single?.binary ?? false,
                      oversized: single?.oversized ?? false,
                    ),
                  ],
                ),
              ),
            ),
            for (final file in rows) _row(context, app, file),
            if (summary.truncated)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
                child: Text(
                  // **截断要说**：宿主的 `maxFiles` 砍掉了后面的文件。
                  '还有 ${summary.total - summary.files.length} 个文件没列出（超过电脑侧上限）',
                  style: TextStyle(fontSize: 11, color: c.labelCaption),
                ),
              ),
            if (foldable)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
                  child: TextButton(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    child: Text(
                      _expanded ? '收起' : '全部 ${summary.files.length} 个文件',
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, AppModel app, ChangedFile file) {
    final c = context.dshColors;
    return InkWell(
      onTap: () => _open(app, file.path),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
        child: Row(
          children: [
            Expanded(
              child: Text(
                file.display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: c.labelPrimary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            diffCountsOf(
              context,
              added: file.added,
              deleted: file.deleted,
              binary: file.binary,
              oversized: file.oversized,
            ),
          ],
        ),
      ),
    );
  }
}
