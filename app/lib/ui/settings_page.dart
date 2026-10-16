/// 设置页 —— 本期只做「**连接方式**」（端点选择器）。
///
/// Note: 为什么只有这一组、为什么状态全部读真实拨号记录、为什么 relay 也全量
/// 显示 —— 见 `.agents/notes/implemented/2026-10-16-endpoint-chooser-ui.md`。
///
/// ## 为什么先只有这一组
///
/// `docs/settings-porting-notes.md` 的第一版分组有 5 组（账号 / 通用 / 模型 /
/// 插件 / 预设 / 关于连接），其余组还没搬。**不摆占位行** —— 一行点下去
/// 只弹"还没做"的假入口，比没有这一行更糟（用户会以为功能坏了）。
/// 连接方式先落地是因为它的模型层早已就绪（`AppModel.endpoints` /
/// `preferEndpoint`、`EndpointTransport.connect()` 按序拨号），差的只是界面。
///
/// ## 端点行的读法
///
/// - **顺序即偏好**：排在第一位的先拨，拨不通自动顺延
///   （`core/endpoint_transport.dart` 刻意不降权，直连恢复后回得去）；
/// - 行 = `[图标 + 直连/中转 + 地址(+自报名) + 状态] [首选(恒占位)]`，
///   照 `docs/design-and-tech-plan.md` §7.9 的选择类列表行结构；
/// - **点一行 = 把它设为首选**（`AppModel.preferEndpoint`，只改序不删条目），
///   下次重连生效 —— 不踹掉正在用的连接；
/// - 状态全部来自**真实拨号记录**（`AppModel.attemptOf`，传输层每试一个
///   端点报一次）：没有记录就说"还没试过"，不猜、不主动探测。
library;

import 'package:flutter/material.dart';

import '../core/endpoint.dart';
import '../data/app_model.dart';
import '../model/chat_item.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import 'connection_summary_block.dart';
import 'dsh_app_bar.dart';

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
      // **整页听 `AppModel`**：端点表、拨号记录、连接状态都会变，
      // 不监听就等于列表永远停在首帧（与 `main.dart` 听抽屉同一条理由）。
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) => _EndpointSection(app: app),
      ),
    );
  }
}

class _EndpointSection extends StatelessWidget {
  const _EndpointSection({required this.app});

  final AppModel app;

  @override
  Widget build(BuildContext context) {
    final endpoints = app.endpoints;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        // 与连接 sheet 顶部同一块：这一页也能一眼看到"走的哪条、为什么"。
        ConnectionSummaryBlock(
          connection: connectionSummary(
            state: app.connection,
            active: app.activeEndpoint,
            endpoints: endpoints,
            attemptOf: app.attemptOf,
          ),
        ),
        const SizedBox(height: 8),
        const _SectionTitle('连接方式'),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Text(
            '排在第一位的先拨，拨不通自动顺延；点一行把它设为首选，下次重连生效。'
            '端点只是地址、不含凭据 —— 换端点不重扫码。',
            style: TextStyle(fontSize: 12, color: DshColors.labelTertiary),
          ),
        ),
        if (endpoints.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 12),
            child: Text(
              '还没有端点。配对成功后，这里会列出可拨的地址。',
              style: TextStyle(fontSize: 13, color: DshColors.labelSecondary),
            ),
          )
        else
          _EndpointCard(app: app),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 2),
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
