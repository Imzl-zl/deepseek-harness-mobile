/// 插件页：**清单 + 行级启停**（契约 §5.7 的 `plugin.list` / `plugin.setEnabled`）。
///
/// ## 为什么只有这两件
///
/// 插件在手机上**没有"逐插件页面"这回事**（`docs/plugin-and-jobs-notes.md` A.5：
/// 配置表单渲染器不存在，Schemastery 只发 `volatile` 字段），所以页面上能做的
/// 只有"看见有哪些插件、每一行开着还是关着"。
///
/// ## 安装 / 卸载：发起即返回 + 轮询
///
/// 它们动的是电脑侧 profile 的 `package.json` 与 `pnpm-lock`，**跑的是 pnpm** ——
/// 一次真实安装常超契约 §10 的 60 s 请求超时。所以形状是
/// `plugin.install` / `plugin.remove` 立刻回一个任务 id，页面每 [kPluginJobPoll]
/// 问一次 `plugin.installStatus`（读方法，不新开帧），进度来自宿主的
/// `plugin-manager/install-*` 事件（连接器已收成尾窗）。
///
/// **危险动作在手机上要一次明确确认**（安装跑脚本、卸载不可逆）——这是 UI 安全门，
/// 不是替宿主做决定。失败一律显示电脑侧的原话（`ManagementError.code` / pnpm 输出尾部）。
///
/// ## 三态与"能不能改"
///
/// - 老连接器（没有 `caps.plugins`）⇒ 一句话说清"这台电脑没有插件服务"，
///   **不发请求**（`AppModel.refreshPlugins` 自己早退）。
/// - 读失败 ⇒ 显示电脑侧给的原因 + 重试，不摆空列表冒充"一个插件都没有"。
/// - 每一行的开关**只在宿主给了 `patchId` 时才可点**（`PluginRow.canToggle`）：
///   不可点的行把原因写在下面（"只能在电脑上改"），而不是让用户点一个必然失败的开关。
///
/// 取舍与判据见 `.agents/notes/implemented/2026-10-24-plugin-list-and-toggle.md`。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_model.dart';
import '../model/plugins.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_theme.dart';
import 'dsh_app_bar.dart';

/// 页面入口：进页拉一次清单，之后听 `AppModel`（**页面自己不发请求**）。
class PluginsPageHost extends StatefulWidget {
  const PluginsPageHost({super.key, required this.app});

  final AppModel app;

  @override
  State<PluginsPageHost> createState() => _PluginsPageHostState();
}

/// 轮询间隔（**通道层参数**：我们这条管道问一次"跑到哪了"的节奏）。
const Duration kPluginJobPoll = Duration(seconds: 1);

class _PluginsPageHostState extends State<PluginsPageHost> {
  /// 最近一次启停的一句话（宿主的结论；失败时是电脑侧给的原因）。
  String? _notice;

  /// 当前这一次安装/卸载任务（`null` = 没有）。
  PluginJob? _job;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    // 没有能力位时 `refreshPlugins` 自己早退 —— 一次请求都不发。
    unawaited(widget.app.refreshPlugins());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// 起一个任务并按 [kPluginJobPoll] 轮询到它有结论。
  Future<void> _startJob(Future<String?> Function() start) async {
    final requestId = await start();
    if (!mounted) return;
    if (requestId == null) {
      setState(() => _notice = widget.app.lastError?.message ?? '发起失败');
      return;
    }
    setState(() => _notice = null);
    unawaited(_pollJob(requestId));
  }

  Future<void> _pollJob(String requestId) async {
    final job = await widget.app.pluginJobStatus(requestId);
    if (!mounted) return;
    setState(() => _job = job);
    if (job == null || !job.running) {
      _poll?.cancel();
      // 有结论就重读一次清单：安装/卸载之后"装了哪些、开着哪些"已经变了。
      if (job != null && job.done) unawaited(widget.app.refreshPlugins());
      return;
    }
    _poll?.cancel();
    _poll = Timer(kPluginJobPoll, () => unawaited(_pollJob(requestId)));
  }

  /// 安装对话框：**一次明确确认**（会跑 pnpm、可能几十秒到几分钟）。
  Future<void> _askInstall() async {
    // 输入框的 controller 归对话框自己所有（在它 `dispose` 里释放）——
    // 在这里 dispose 会落在路由还在退场的那一拍上（Flutter 会报"用了已释放的对象"）。
    final spec = await showDialog<String>(
      context: context,
      builder: (_) => const _InstallDialog(),
    );
    final value = (spec ?? '').trim();
    if (value.isEmpty) return;
    await _startJob(() => widget.app.installPlugin(value));
  }

  /// 卸载确认（不可逆；`removable` 由宿主说，见包清单）。
  Future<void> _askRemove(PluginBundle bundle) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('卸载这个包？'),
        content: Text(
          '${bundle.name}\n\n电脑侧会跑 pnpm remove 并重载 profile。'
          '卸载不可逆（要装回来得重新安装）。',
          style: const TextStyle(fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey<String>('plugin-remove-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _startJob(() => widget.app.removePluginBundle(bundle.name));
  }

  /// 取消（宿主三档原样回：`cancelled` / `too-late` / `not-running`）。
  Future<void> _cancelJob(String requestId) async {
    final status = await widget.app.cancelPluginInstall(requestId);
    if (!mounted) return;
    setState(() {
      _notice = switch (status) {
        'cancelled' => '已取消（文件已还原）',
        'too-late' => '太晚了：电脑侧已经进入应用阶段',
        'not-running' => '这次任务已经不在跑了',
        null => widget.app.lastError?.message ?? '取消失败',
        _ => '电脑侧回了未知状态：$status',
      };
    });
  }

  Future<void> _toggle(PluginRow row, bool enabled) async {
    final outcome = await widget.app.setPluginEnabled(row.entryId, enabled);
    if (!mounted) return;
    setState(() {
      _notice = outcome == null
          ? (widget.app.lastError?.message ?? '启停失败')
          : outcome.notice;
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
          '插件',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: c.labelPrimary,
          ),
        ),
        actions: [
          if (widget.app.pluginsAvailable) ...[
            DshAppBarButton(
              icon: 'plus',
              tooltip: '安装插件',
              onPressed: () => unawaited(_askInstall()),
            ),
            DshAppBarButton(
              icon: 'refresh',
              tooltip: '重新读取',
              onPressed: () => unawaited(widget.app.refreshPlugins()),
            ),
          ],
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.app,
        builder: (context, _) {
          final app = widget.app;
          final notice = _notice;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              if (notice != null && notice.isNotEmpty) ...[
                _NoticeCard(text: notice),
                const SizedBox(height: 12),
              ],
              if (_job case final job?) ...[
                _JobCard(
                  job: job,
                  onCancel: job.running
                      ? () => unawaited(_cancelJob(job.requestId))
                      : null,
                  onDismiss: () => setState(() => _job = null),
                ),
                const SizedBox(height: 12),
              ],
              ..._body(context, app),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _body(BuildContext context, AppModel app) {
    final c = context.dshColors;
    if (!app.pluginsAvailable) {
      return const [_Hint(text: '这台电脑没有插件服务：连接器版本较旧，或没装 plugin-manager。')];
    }
    final failure = app.pluginsFailure;
    if (failure != null) {
      return [
        _Hint(text: '读取失败：$failure', color: c.stateError),
        const SizedBox(height: 8),
        const _Hint(text: '点右上角刷新重试。'),
      ];
    }
    if (!app.pluginsLoaded) {
      return [_Hint(text: app.pluginsLoading ? '正在读取…' : '还没有读到插件清单。')];
    }
    if (app.plugins.isEmpty) {
      return [
        const _Hint(text: '这台电脑没有可管理的插件。'),
        ..._bundleSection(context, app),
      ];
    }
    return [
      const _SectionLabel('插件'),
      for (final row in app.plugins)
        _PluginRowTile(row: row, onToggle: (enabled) => _toggle(row, enabled)),
      ..._bundleSection(context, app),
    ];
  }

  /// 包（卸载按包名走；`removable` 由宿主说）。
  List<Widget> _bundleSection(BuildContext context, AppModel app) {
    final bundles = app.pluginBundles;
    if (bundles.isEmpty) return const [];
    return [
      const SizedBox(height: 16),
      const _SectionLabel('包（卸载按包名）'),
      for (final bundle in bundles)
        _BundleRow(
          bundle: bundle,
          onRemove: bundle.removable && bundle.installed
              ? () => unawaited(_askRemove(bundle))
              : null,
        ),
    ];
  }
}

/// 安装对话框（自己持有输入框 controller，自己释放）。
class _InstallDialog extends StatefulWidget {
  const _InstallDialog();

  @override
  State<_InstallDialog> createState() => _InstallDialogState();
}

class _InstallDialogState extends State<_InstallDialog> {
  final TextEditingController _spec = TextEditingController();

  @override
  void dispose() {
    _spec.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('安装插件'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _spec,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '包名或来源',
              hintText: '@scope/pkg 或 包名@1.2.3',
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '只收包名 / 版本 / git 地址；**不能是电脑上的本地路径**（那条只能在电脑上做）。\n'
            '电脑侧会跑 pnpm（可能要几分钟）。装不上时电脑侧的原话会显示在下面。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          key: const ValueKey<String>('plugin-install-confirm'),
          onPressed: () => Navigator.of(context).pop(_spec.text),
          child: const Text('安装'),
        ),
      ],
    );
  }
}

/// 一段的标题（插件 / 包）。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: TextStyle(fontSize: 12, color: c.labelCaption)),
    );
  }
}

/// 一个包：名字 + 版本 + 卸载（宿主说 `removable` 才可点）。
class _BundleRow extends StatelessWidget {
  const _BundleRow({required this.bundle, required this.onRemove});

  final PluginBundle bundle;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: c.layer1,
        borderRadius: BorderRadius.circular(DshRadius.md),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bundle.shortName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: c.labelPrimary),
                ),
                Text(
                  [
                    bundle.name,
                    if (bundle.version.isNotEmpty) 'v${bundle.version}',
                    if (!bundle.removable) '宿主要求在电脑上处理',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: c.labelCaption),
                ),
              ],
            ),
          ),
          if (onRemove != null)
            TextButton(
              key: ValueKey<String>('plugin-remove-${bundle.name}'),
              onPressed: onRemove,
              child: const Text('卸载'),
            ),
        ],
      ),
    );
  }
}

/// 一次安装/卸载的进度卡：一句话结论 + 阶段 + pnpm 输出尾部（可滚动）。
class _JobCard extends StatelessWidget {
  const _JobCard({
    required this.job,
    required this.onCancel,
    required this.onDismiss,
  });

  final PluginJob job;
  final VoidCallback? onCancel;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final log = job.log.join('\n');
    return Container(
      key: const ValueKey<String>('plugin-job'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.layer2,
        borderRadius: BorderRadius.circular(DshRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (job.running)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (job.running) const SizedBox(width: 8),
              Expanded(
                child: Text(
                  job.headline,
                  style: TextStyle(fontSize: 12.5, color: c.labelPrimary),
                ),
              ),
              if (job.running && onCancel != null)
                TextButton(onPressed: onCancel, child: const Text('取消'))
              else
                TextButton(onPressed: onDismiss, child: const Text('关闭')),
            ],
          ),
          if (job.bundle.isNotEmpty)
            Text(
              '${job.bundle}${job.version.isEmpty ? '' : ' v${job.version}'}',
              style: TextStyle(fontSize: 11, color: c.labelCaption),
            ),
          if (log.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 140),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: c.bgBase,
                borderRadius: BorderRadius.circular(DshRadius.sm),
              ),
              child: SingleChildScrollView(
                child: Text(
                  log,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10.5,
                    height: 15 / 10.5,
                    color: c.labelSecondary,
                  ),
                ),
              ),
            ),
            if (job.logTruncated)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '只显示输出的最后一段（完整日志在电脑上）。',
                  style: TextStyle(fontSize: 10.5, color: c.labelCaption),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// 一行插件：展示名 + 模块名（+ 不可改的原因）+ 开关。
class _PluginRowTile extends StatelessWidget {
  const _PluginRowTile({required this.row, required this.onToggle});

  final PluginRow row;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: c.layer1,
        borderRadius: BorderRadius.circular(DshRadius.lg),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, color: c.labelPrimary),
                ),
                // 模块名只在**与展示名不同**时画第二行 —— 没有 `meta.title` 的行
                // 本来就用模块名当标题，再画一遍是同一句话两个位置。
                if (row.moduleName.isNotEmpty &&
                    row.moduleName != row.displayName)
                  Text(
                    row.moduleName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: c.labelCaption),
                  ),
                if (!row.canToggle && row.readOnlyHint.isNotEmpty)
                  Text(
                    row.readOnlyHint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: c.labelTertiary),
                  ),
              ],
            ),
          ),
          Switch(
            key: ValueKey<String>('plugin-switch-${row.entryId}'),
            value: row.enabled,
            // **不可改的行给 `null`**（禁用态）：点一个必然失败的开关比没有更糟。
            onChanged: row.canToggle ? onToggle : null,
          ),
        ],
      ),
    );
  }
}

/// 启停之后的一句话（宿主的结论）。
class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.layer2,
        borderRadius: BorderRadius.circular(DshRadius.md),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: c.labelSecondary),
      ),
    );
  }
}

/// 一句话提示（老连接器 / 加载中 / 读失败 / 空清单）。
class _Hint extends StatelessWidget {
  const _Hint({required this.text, this.color});

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
