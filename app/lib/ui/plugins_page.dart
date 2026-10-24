/// 插件页：**清单 + 行级启停**（契约 §5.7 的 `plugin.list` / `plugin.setEnabled`）。
///
/// ## 为什么只有这两件
///
/// 插件在手机上**没有"逐插件页面"这回事**（`docs/plugin-and-jobs-notes.md` A.5：
/// 配置表单渲染器不存在，Schemastery 只发 `volatile` 字段），所以页面上能做的
/// 只有"看见有哪些插件、每一行开着还是关着"。
///
/// 安装 / 卸载 / 升级**不做**：它们动的是电脑侧 profile 的 `package.json` 与
/// `pnpm-lock`，失败面在手机上既看不见也修不了（连接器也不挂那两个方法）。
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

class _PluginsPageHostState extends State<PluginsPageHost> {
  /// 最近一次启停的一句话（宿主的结论；失败时是电脑侧给的原因）。
  String? _notice;

  @override
  void initState() {
    super.initState();
    // 没有能力位时 `refreshPlugins` 自己早退 —— 一次请求都不发。
    unawaited(widget.app.refreshPlugins());
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
          if (widget.app.pluginsAvailable)
            DshAppBarButton(
              icon: 'refresh',
              tooltip: '重新读取',
              onPressed: () => unawaited(widget.app.refreshPlugins()),
            ),
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
      return const [_Hint(text: '这台电脑没有可管理的插件。')];
    }
    return [
      for (final row in app.plugins)
        _PluginRowTile(row: row, onToggle: (enabled) => _toggle(row, enabled)),
      const SizedBox(height: 12),
      const _Hint(text: '安装 / 卸载 / 升级请在电脑上做：它们改的是 profile 的依赖与锁文件。'),
    ];
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
