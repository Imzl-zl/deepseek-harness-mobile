/// 插件页：**按包分组的清单 + 行级启停 + 包级卸载**（契约 §5.7）。
///
/// ## 为什么按包分组，而不是"插件一段、包一段"
///
/// 卸载只按**包名**走（宿主 `removeBundle(name)`），而一个包可以带来多行 ——
/// "这个插件属于哪个可卸载的包"是用户点卸载之前唯一要回答的问题。
/// 分成两段列表时，那个答案要靠人自己去两个列表之间对照，卸载按钮也就落在了
/// 一个跟插件行毫无关系的地方（用户原话：「只能禁用、停用，没有删除？我想删除咋办」）。
///
/// 分组用的是**宿主给的对应关系**：`plugin.listBundles` 的 `rows[].entryId`
/// （`BundleInfo.rows`，`plugin-manager/src/types.ts:61-70`）。按 `moduleName` 猜
/// 就是第二份判据。没有归属的插件行单独一段（内建模板配的行不来自任何包）。
///
/// ## 卸载按钮**不按 `removable` 隐藏**
///
/// `removable` 只是宿主的一句预告，真正的判定在 `removeBundle` 里
/// （`plugin-manager/src/index.ts:1039` 抛 `not-removable`）。手机上的那一下是
/// **用户的决定**：他自己装的东西，卸出问题也是他自己收拾。所以按钮一直在，
/// 被拒时把电脑侧的原话显示出来（`ManagementError.code` 已经是人话）。
/// 取舍见 `.agents/notes/implemented/2026-11-01-plugin-page-owns-the-delete.md`。
///
/// ## 安装 / 卸载：发起即返回 + 轮询
///
/// 它们动的是电脑侧 profile 的 `package.json` 与 `pnpm-lock`，**跑的是 pnpm** ——
/// 一次真实安装常超契约 §10 的 60 s 请求超时。所以形状是
/// `plugin.install` / `plugin.remove` 立刻回一个任务 id，页面每 [kPluginJobPoll]
/// 问一次 `plugin.installStatus`。进度卡钉在页面顶部（不随列表滚走），
/// **有一句话结论的地方在屏幕中央**（[DshCenterNotice]）——
/// 列表可以滚，用户此刻在看哪儿说不准。
///
/// ## 三态与"能不能改"
///
/// - 老连接器（没有 `caps.plugins`）⇒ 一句话说清"这台电脑没有插件服务"，
///   **不发请求**（`AppModel.refreshPlugins` 自己早退）。
/// - 读失败 ⇒ 显示电脑侧给的原因 + 重试，不摆空列表冒充"一个插件都没有"。
/// - 每一行的开关**只在宿主给了 `patchId` 时才可点**（`PluginRow.canToggle`）：
///   不可点的行把原因写在下面（"只能在电脑上改"），而不是让用户点一个必然失败的开关。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_model.dart';
import '../model/plugins.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';
import 'dsh_app_bar.dart';
import 'dsh_center_notice.dart';

/// 页面入口：进页拉一次清单，之后听 `AppModel`（**页面自己不发读请求**）。
class PluginsPageHost extends StatefulWidget {
  const PluginsPageHost({super.key, required this.app});

  final AppModel app;

  @override
  State<PluginsPageHost> createState() => _PluginsPageHostState();
}

/// 轮询间隔（**通道层参数**：我们这条管道问一次"跑到哪了"的节奏）。
const Duration kPluginJobPoll = Duration(seconds: 1);

class _PluginsPageHostState extends State<PluginsPageHost> {
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
    // 居中提示是 overlay 级的静态状态：页面拆了必须收掉，否则它会在别的页面上飘。
    DshCenterNotice.dismiss();
    super.dispose();
  }

  /// 起一个任务并按 [kPluginJobPoll] 轮询到它有结论。
  Future<void> _startJob(Future<String?> Function() start) async {
    final requestId = await start();
    if (!mounted) return;
    if (requestId == null) {
      _notify(widget.app.lastError?.message ?? '发起失败', error: true);
      return;
    }
    setState(() => _job = null);
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

  /// 卸载确认（不可逆；**需要 `installed`，不看 `removable`** —— 见文件头）。
  Future<void> _askRemove(PluginBundle bundle) async {
    final c = context.dshColors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: c.layer1,
        title: const Text('卸载这个包？'),
        content: Text(
          '${bundle.name}\n\n'
          '电脑侧会跑 pnpm remove 并重载 profile。卸载不可逆（要装回来得重新安装）。'
          '${bundle.removable ? '' : '\n\n电脑侧把这一包标成不可卸载 —— 点了会回它的原话。'}',
          style: const TextStyle(fontSize: 12, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey<String>('plugin-remove-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('卸载', style: TextStyle(color: c.stateError)),
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
    _notify(switch (status) {
      'cancelled' => '已取消（文件已还原）',
      'too-late' => '太晚了：电脑侧已经进入应用阶段',
      'not-running' => '这次任务已经不在跑了',
      null => widget.app.lastError?.message ?? '取消失败',
      _ => '电脑侧回了未知状态：$status',
    }, error: status != 'cancelled');
  }

  Future<void> _toggle(PluginRow row, bool enabled) async {
    final outcome = await widget.app.setPluginEnabled(row.entryId, enabled);
    if (!mounted) return;
    if (outcome == null) {
      _notify(widget.app.lastError?.message ?? '启停失败', error: true);
      return;
    }
    // `applied` 的结论 row.notice 是空串：开关本身就在用户手指下面，不用再弹。
    if (outcome.notice.isEmpty) return;
    _notify(outcome.notice, error: outcome.application == 'failed');
  }

  /// 一句话结论 —— **屏幕中央**（列表可以滚，用户在看哪儿说不准）。
  void _notify(String message, {bool error = false}) =>
      DshCenterNotice.show(context, message, error: error);

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
          final job = _job;
          return Column(
            children: [
              // 进度卡**钉在顶部**：它会自己变（阶段 / 日志），不该被滚走。
              if (job != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: _JobCard(
                    job: job,
                    onCancel: job.running
                        ? () => unawaited(_cancelJob(job.requestId))
                        : null,
                    onDismiss: () => setState(() => _job = null),
                  ),
                ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: _body(context, widget.app),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _body(BuildContext context, AppModel app) {
    final c = context.dshColors;
    if (!app.pluginsAvailable) {
      return const [
        _Empty(
          icon: 'pluginPinwheel',
          title: '这台电脑没有插件服务',
          body: '连接器版本较旧，或者这台电脑没装 plugin-manager。',
        ),
      ];
    }
    final failure = app.pluginsFailure;
    if (failure != null) {
      return [
        _Empty(
          icon: 'warningTriangle',
          title: '读取失败',
          body: failure,
          color: c.stateError,
          action: TextButton(
            onPressed: () => unawaited(app.refreshPlugins()),
            child: const Text('重试'),
          ),
        ),
      ];
    }
    if (!app.pluginsLoaded) {
      return [
        _Empty(
          icon: 'pluginPinwheel',
          title: app.pluginsLoading ? '正在读取…' : '还没有读到插件清单',
          body: '点右上角刷新重试。',
        ),
      ];
    }
    final bundles = app.pluginBundles;
    final plugins = app.plugins;
    if (bundles.isEmpty && plugins.isEmpty) {
      return const [
        _Empty(
          icon: 'pluginPinwheel',
          title: '这台电脑没有可管理的插件。',
          body: '装上插件后，这里按包列出它们的每一行。',
        ),
      ];
    }

    // **归属用宿主给的对应关系**：包声明的行 → 承载它的 entry。
    final ownerOf = <String, String>{};
    for (final bundle in bundles) {
      for (final row in bundle.rows) {
        if (row.entryId.isNotEmpty) ownerOf[row.entryId] = bundle.name;
      }
    }
    final rowsOf = <String, List<PluginRow>>{};
    final orphans = <PluginRow>[];
    for (final row in plugins) {
      final owner = ownerOf[row.entryId];
      if (owner == null) {
        orphans.add(row);
      } else {
        rowsOf.putIfAbsent(owner, () => <PluginRow>[]).add(row);
      }
    }

    return [
      if (bundles.isNotEmpty) ...[
        _SectionLabel('${plugins.length} 个插件 · ${bundles.length} 个包'),
        for (final bundle in bundles)
          _BundleCard(
            bundle: bundle,
            rows: rowsOf[bundle.name] ?? const <PluginRow>[],
            onToggle: (row, enabled) => unawaited(_toggle(row, enabled)),
            // **装着的包都有卸载**（不看 `removable`）：没装的本来就没得卸。
            onRemove: bundle.installed
                ? () => unawaited(_askRemove(bundle))
                : null,
          ),
      ],
      if (orphans.isNotEmpty) ...[
        const _SectionLabel('其他插件'),
        for (final row in orphans)
          _PluginCard(
            row: row,
            onToggle: (enabled) => unawaited(_toggle(row, enabled)),
          ),
      ],
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
    final c = context.dshColors;
    return AlertDialog(
      backgroundColor: c.layer1,
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
            '电脑侧会跑 pnpm（可能要几分钟）。装不上时电脑侧的原话会显示出来。',
            style: TextStyle(fontSize: 12, height: 1.5),
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

/// 一段的标题（数量 / "其他插件"）。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: c.labelSecondary,
        ),
      ),
    );
  }
}

/// 一个包的一张卡：包名 / 版本 / 状态 → 它的插件行 → 卸载。
class _BundleCard extends StatelessWidget {
  const _BundleCard({
    required this.bundle,
    required this.rows,
    required this.onToggle,
    required this.onRemove,
  });

  final PluginBundle bundle;

  /// 这个包此刻在跑的插件行（空 = 包没启用，或它的行都被禁用了）。
  final List<PluginRow> rows;

  final void Function(PluginRow row, bool enabled) onToggle;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final (statusText, statusColor) = bundle.installed
        ? bundle.enabled
              ? ('已启用', c.stateSuccess)
              : ('已停用', c.labelCaption)
        : ('未安装', c.labelTertiary);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: c.layer1,
        borderRadius: BorderRadius.circular(DshRadius.lg),
        border: Border.all(color: c.border()),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              bundle.shortName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: c.labelPrimary,
                              ),
                            ),
                          ),
                          if (bundle.version.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            _Chip(text: 'v${bundle.version}'),
                          ],
                        ],
                      ),
                      // 完整包名只在**与短名不同**时画第二行 —— 没有 scope 的包
                      // 本来就是同一个词，再画一遍是同一件事两个位置。
                      if (bundle.shortName != bundle.name)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            bundle.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: c.labelCaption,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _StatusChip(text: statusText, color: statusColor),
              ],
            ),
          ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Text(
                bundle.enabled ? '这个包没有在跑的插件行。' : '启用这个包之后，它带来的插件行会出现在这里。',
                style: TextStyle(fontSize: 12, color: c.labelTertiary),
              ),
            )
          else
            for (final row in rows) ...[
              Divider(height: 1, indent: 14, endIndent: 14, color: c.border()),
              _PluginLine(
                row: row,
                onToggle: (enabled) => onToggle(row, enabled),
              ),
            ],
          if (onRemove != null)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
                child: TextButton.icon(
                  key: ValueKey<String>('plugin-remove-${bundle.name}'),
                  onPressed: onRemove,
                  icon: DshIcon('trash', size: 16, color: c.stateError),
                  label: Text(
                    '卸载',
                    style: TextStyle(fontSize: 13, color: c.stateError),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 不属于任何包的插件行（内建模板配的那些）单独一张卡。
class _PluginCard extends StatelessWidget {
  const _PluginCard({required this.row, required this.onToggle});

  final PluginRow row;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: c.layer1,
        borderRadius: BorderRadius.circular(DshRadius.lg),
        border: Border.all(color: c.border()),
      ),
      child: _PluginLine(row: row, onToggle: onToggle),
    );
  }
}

/// 一行插件：状态点 + 展示名（+ 模块名 / 只读原因）+ 开关。
class _PluginLine extends StatelessWidget {
  const _PluginLine({required this.row, required this.onToggle});

  final PluginRow row;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: Row(
        children: [
          _PhaseDot(phase: row.fiberPhase, enabled: row.enabled),
          const SizedBox(width: 10),
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
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      row.moduleName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: c.labelCaption),
                    ),
                  ),
                if (!row.canToggle && row.readOnlyHint.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      row.readOnlyHint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: c.labelTertiary),
                    ),
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

/// 运行时状态点（宿主的 `fiberPhase`）：在跑 / 出错 / 过渡 / 已停。
class _PhaseDot extends StatelessWidget {
  const _PhaseDot({required this.phase, required this.enabled});

  final String phase;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final color = !enabled
        ? c.stateIdle
        : switch (phase) {
            'active' => c.stateSuccess,
            'failed' => c.stateError,
            'pending' || 'loading' || 'unloading' => c.stateWarn,
            _ => c.stateIdle,
          };
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// 小胶囊（版本 / 状态）。
class _Chip extends StatelessWidget {
  const _Chip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: c.layer2,
        borderRadius: BorderRadius.circular(DshRadius.xs),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: c.labelCaption)),
    );
  }
}

/// 带颜色的状态胶囊（已启用 / 已停用 / 未安装）。
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(DshRadius.xs),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w500,
        ),
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
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: c.layer2,
        borderRadius: BorderRadius.circular(DshRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (job.running) ...[
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
              ],
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

/// 一句话 + 可选的出口（老连接器 / 读取中 / 读失败 / 空清单）。
class _Empty extends StatelessWidget {
  const _Empty({
    required this.icon,
    required this.title,
    this.body,
    this.color,
    this.action,
  });

  final String icon;
  final String title;
  final String? body;
  final Color? color;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final body = this.body;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: c.layer1,
        borderRadius: BorderRadius.circular(DshRadius.lg),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: DshIcon(icon, size: 18, color: color ?? c.labelSecondary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontSize: 13.5, color: c.labelPrimary),
                ),
                if (body != null && body.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      body,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.45,
                        color: c.labelSecondary,
                      ),
                    ),
                  ),
                if (action != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: action,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
