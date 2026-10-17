/// 设置页 —— 第一版四组：**通用 / 模型 / 连接方式 / 关于与连接**。
///
/// ## 为什么是这四组
///
/// `docs/settings-porting-notes.md` 的第一版分组有 5 组（账号 / 通用 / 模型 /
/// 内置插件 / Agent 预设 / 关于连接），其余组还没搬。**不摆占位行** ——
/// 一行点下去只弹"还没做"的假入口，比没有这一行更糟（用户会以为功能坏了）。
/// 本版落地的判据是**这一行点了真的有作用**：
///
/// - **通用**：四项手机本地偏好（DSH 的"纯 UI 偏好"，§7.1 已论证**有意
///   偏离**存手机本地）。其中"工作步骤展示 / 性能与用量"直接影响对话流与
///   统计条的呈现，"繁忙时发送"就是输入区那个二选一（同一状态两个入口，
///   与 DSH 桌面把它放设置页一致）。
/// - **模型**：只读。当前模型与 provider 目录来自电脑侧真值
///   （`session/modelCatalog` + `modelSelection` 投影），拉取失败的 provider
///   **列出来**（静默丢掉 = "key 没配"在手机上毫无痕迹）。
/// - **连接方式**：端点选择器（`AppModel.endpoints`，序即偏好）。
/// - **关于与连接**：App 版本 + 连接状态。
///
/// 快捷键（无物理键盘）、内置插件 / Agent 预设 / 账号（都要先扩连接器方法面）
/// **不进本版** —— 依据见 `docs/settings-porting-notes.md` §10。
///
/// Note: 为什么只落四组、以及三项通用偏好为何存手机本地（有意偏离 DSH）——
/// 见 .agents/notes/implemented/2026-10-17-settings-page-v1-four-groups.md
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/endpoint.dart';
import '../data/app_model.dart';
import '../model/chat_item.dart';
import '../model/model_catalog.dart';
import '../model/preferences.dart';
import '../model/send_mode.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import 'connection_summary_block.dart';
import 'dsh_app_bar.dart';
import 'dsh_sheet.dart';

/// App 版本（排错必需：手机侧这一行与电脑侧 DSH 版本互相印证）。
///
/// **没有 `package_info_plus`**：那是一个新依赖，而版本号对设置页只是
/// 一行文字。构建期由 `--dart-define` 注入；没注入时显示 "dev"——
/// 不猜一个版本号。
const String kAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'dev',
);

/// 设置页（从抽屉底栏「设置」 push 进来）。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.app});

  final AppModel app;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DshColors.bgBase,
      appBar: AppBar(
        backgroundColor: DshColors.sidebar,
        foregroundColor: DshColors.labelPrimary,
        // 图标照原型设置页的返回键（`chevronLeft`）—— 与顶栏同一套按钮，
        // 不引 Material 的默认返回箭头（那会多一套视觉）。
        leading: DshAppBarButton(
          icon: 'chevronLeft',
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text(
          '设置',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: DshColors.labelPrimary,
          ),
        ),
      ),
      // **整页听 `AppModel`**：端点表、拨号记录、连接状态、偏好都会变，
      // 不监听就等于列表永远停在首帧（与 `main.dart` 听抽屉同一条理由）。
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            // 与连接 sheet 顶部同一块：这一页也能一眼看到"走的哪条、为什么"。
            ConnectionSummaryBlock(
              connection: connectionSummary(
                state: app.connection,
                active: app.activeEndpoint,
                endpoints: app.endpoints,
                attemptOf: app.attemptOf,
              ),
            ),
            const _SectionTitle('通用'),
            _PrefRow(
              icon: 'checklist',
              label: '工作步骤展示',
              value: app.transcriptView.label,
              onTap: () => _pickEnum<TranscriptView>(
                context: context,
                title: '工作步骤展示',
                values: TranscriptView.values,
                labelOf: (v) => v.label,
                current: app.transcriptView,
                onPicked: app.setTranscriptView,
              ),
            ),
            _PrefRow(
              icon: 'gauge',
              label: '性能与用量',
              value: app.performanceUsage.label,
              onTap: () => _pickEnum<PerformanceUsage>(
                context: context,
                title: '性能与用量',
                values: PerformanceUsage.values,
                labelOf: (v) => v.label,
                current: app.performanceUsage,
                onPicked: app.setPerformanceUsage,
              ),
            ),
            _PrefRow(
              icon: 'queue',
              label: '繁忙时发送',
              value: app.sendMode.label,
              onTap: () => _pickEnum<SendMode>(
                context: context,
                title: '繁忙时的发送行为',
                values: SendMode.values,
                labelOf: (v) => v.label,
                current: app.sendMode,
                onPicked: app.setSendMode,
              ),
            ),
            const _PrefNote(
              '这三项只影响这台手机的呈现，不同步到电脑（DSH 桌面把它们存在'
              '电脑上，那是跨浏览器跟随；手机只有自己看，这是有意偏离）。',
            ),
            const _SectionTitle('模型'),
            _ModelSection(app: app),
            const _SectionTitle('连接方式'),
            const _EndpointNote(),
            if (app.endpoints.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                child: Text(
                  '还没有端点。配对成功后，这里会列出可拨的地址。',
                  style: TextStyle(
                    fontSize: 13,
                    color: DshColors.labelSecondary,
                  ),
                ),
              )
            else
              _EndpointCard(app: app),
            const _SectionTitle('关于与连接'),
            _PrefRow(
              icon: 'info',
              label: 'App 版本',
              value: kAppVersion,
              onTap: () => _copy(context, kAppVersion),
            ),
            _PrefRow(
              icon: 'globe',
              label: '连接状态',
              value: connectionLabel(app.connection),
              onTap: () {},
            ),
          ],
        ),
      ),
    );
  }

  /// 复制到剪贴板（版本号一行）。
  Future<void> _copy(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制')));
  }
}

/// 选一个枚举值（底部 sheet，行结构照 §7.9）。
Future<void> _pickEnum<T>({
  required BuildContext context,
  required String title,
  required List<T> values,
  required String Function(T) labelOf,
  required T current,
  required Future<void> Function(T) onPicked,
}) async {
  final picked = await showDshSheet<T>(
    context: context,
    title: title,
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final value in values)
          DshPickerRow(
            name: labelOf(value),
            selected: value == current,
            onTap: () => Navigator.of(context).pop(value),
          ),
      ],
    ),
  );
  if (picked != null) await onPicked(picked);
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 2),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: DshColors.labelSecondary,
        ),
      ),
    );
  }
}

/// 一行偏好（`[图标 + 名称] [当前值]`）。
class _PrefRow extends StatelessWidget {
  const _PrefRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: DshIcon(icon, size: 18, color: DshColors.labelSecondary),
      title: Text(
        label,
        style: const TextStyle(fontSize: 14, color: DshColors.labelPrimary),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 13, color: DshColors.labelCaption),
          ),
          const SizedBox(width: 4),
          const DshIcon(
            'chevronRight',
            size: 14,
            color: DshColors.labelTertiary,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// 偏好组下方的一行小字（说清这一组的边界）。
class _PrefNote extends StatelessWidget {
  const _PrefNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          height: 17 / 11,
          color: DshColors.labelTertiary,
        ),
      ),
    );
  }
}

/// 模型组：只读展示电脑侧真值 + 拉取失败的 provider。
class _ModelSection extends StatelessWidget {
  const _ModelSection({required this.app});

  final AppModel app;

  @override
  Widget build(BuildContext context) {
    final catalog = app.modelCatalog;
    final current = app.currentModel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PrefRow(
          icon: 'sparkle',
          label: '当前模型',
          value: current == null
              ? '未选择'
              : '${catalog?.displayNameOf(provider: current.provider, model: current.model) ?? current.label} · ${current.provider}',
          onTap: () {},
        ),
        if (catalog != null)
          _PrefRow(
            icon: 'listPen',
            label: '可用模型',
            value:
                '${catalog.allEntries.length} 个 · '
                '${catalog.groups.length} 个 provider',
            onTap: () {},
          ),
        // **拉取失败的 provider 必须列出来**：静默丢掉 = "key 没配"在手机上
        // 毫无痕迹，而用户看到的是"我的 provider 不见了"。
        for (final failure
            in catalog?.failures ?? const <ModelCatalogFailure>[])
          _PrefRow(
            icon: 'warningTriangle',
            label: '${failure.name} 拉取失败',
            value: failure.message,
            onTap: () {},
          ),
        const _PrefNote(
          '提供商与密钥的增删改在电脑上做（DSH 的模型设置页）。'
          '密钥值不回传手机，这一版也不从手机改。',
        ),
      ],
    );
  }
}

/// 连接方式组上方的一行小字。
class _EndpointNote extends StatelessWidget {
  const _EndpointNote();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Text(
        '排在第一位的先拨，拨不通自动顺延；点一行把它设为首选，下次重连生效。'
        '端点只是地址、不含凭据 —— 换端点不重扫码。',
        style: TextStyle(fontSize: 12, color: DshColors.labelTertiary),
      ),
    );
  }
}

class _EndpointCard extends StatelessWidget {
  const _EndpointCard({required this.app});

  final AppModel app;

  @override
  Widget build(BuildContext context) {
    final endpoints = app.endpoints;
    return Container(
      decoration: BoxDecoration(
        color: DshColors.layer1,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          for (var i = 0; i < endpoints.length; i += 1) ...[
            if (i > 0) Divider(height: 1, color: DshColors.border()),
            _EndpointRow(app: app, endpoint: endpoints[i]),
          ],
        ],
      ),
    );
  }
}

class _EndpointRow extends StatelessWidget {
  const _EndpointRow({required this.app, required this.endpoint});

  final AppModel app;

  final Endpoint endpoint;

  @override
  Widget build(BuildContext context) {
    // 「当前连接」只在**真的在服务态**时给：拨通记录是跨连接保留的，
    // 重连中把上一条连接的赢家标成"当前"会和顶栏/连接 sheet 的说法打架
    //（那边此时说的是"重连中…"）。同一个事实只有一套说法。
    final isActive =
        app.connection == ConnectionStateView.serving &&
        app.activeEndpoint?.id == endpoint.id;
    final isFirst = app.endpoints.first.id == endpoint.id;
    final (status, statusColor) = _statusOf(isActive);

    return InkWell(
      onTap: () => _onTap(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            DshIcon(
              endpoint.kind == EndpointKind.direct ? 'link' : 'globe',
              size: 18,
              color: DshColors.labelSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    endpointKindLabel(endpoint.kind),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: DshColors.labelPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _addressLine(),
                    maxLines: 2,
                    style: const TextStyle(
                      fontSize: 12,
                      color: DshColors.labelSecondary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    status,
                    style: TextStyle(fontSize: 12, color: statusColor),
                  ),
                ],
              ),
            ),
            // **恒占位的勾位**（§7.9）：首选徽标与空位同宽 ——
            // 否则"选中才渲染"会让整行文字在置顶瞬间横移。
            SizedBox(
              width: 40,
              child: isFirst
                  ? const Center(
                      child: Text(
                        '首选',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: DshColors.accentBlue,
                        ),
                      ),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  /// 地址行：url + 连接器自报的名字（网卡名等，没有就不显示）。
  String _addressLine() {
    final label = endpoint.label;
    return label.isEmpty ? endpoint.url : '${endpoint.url} · $label';
  }

  /// 状态文案与颜色。**全部来自真实拨号记录**，没有记录就说"还没试过"。
  (String, Color) _statusOf(bool isActive) {
    if (isActive) return ('当前连接', DshColors.stateSuccess);
    final attempt = app.attemptOf(endpoint);
    if (attempt == null) return ('还没试过', DshColors.labelCaption);
    if (attempt.ok) return ('拨通过', DshColors.labelTertiary);
    final reason = attempt.reason?.isNotEmpty == true
        ? '：${attempt.reason}'
        : '';
    return ('拨不通$reason', DshColors.error);
  }

  Future<void> _onTap(BuildContext context) async {
    if (app.endpoints.first.id == endpoint.id) {
      _toast(context, '「${endpointKindLabel(endpoint.kind)}」已经是首选项');
      return;
    }
    await app.preferEndpoint(endpoint);
    if (!context.mounted) return;
    _toast(context, '已把「${endpointKindLabel(endpoint.kind)}」设为首选，下次重连生效');
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
