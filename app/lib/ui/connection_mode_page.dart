/// 「连接方式」页 —— 这台手机走哪条 + 此刻有哪几条地址。
///
/// ## 为什么是独立一页
///
/// 连接面板一级只留 4–6 行（见 `connection_actions_sheet.dart`）。"策略三档 +
/// 地址列表"是要读和比较的内容，塞回浮层就把它变回 11 行。
///
/// ## 三个维度在这里分开（2026-11-13）
///
/// - **策略**（顶部三档）= 长期意图，落 `device.route_policy`；
///   配对与连接共用它，改完下一次拨号立刻生效。
/// - **地址行**（点一条）= 本次覆盖（`useEndpointNow`），失败回自动并说明原因。
/// - **排序 / 删除**留在设置页端点卡 —— 低频管理，不属于"现在走哪条"。
///
/// 小字只在这个地址**上次没通**时出现一行原因；常驻说明一律不写。
/// 取舍见 `.agents/notes/proposed/2026-11-13-connection-ux-redesign.md`。
library;

import 'package:flutter/material.dart';

import '../core/endpoint.dart';
import '../data/app_model.dart';
import '../model/chat_item.dart' show endpointKindLabel;
import '../model/route_policy.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import 'connection_summary_block.dart' show addEndpointOnly, connectEndpointNow;

/// 打开这一页（全屏推到栈上）。连接面板与设置页共用。
Future<void> openConnectionModePage(BuildContext context, AppModel app) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ConnectionModePage(app: app)),
    );

class ConnectionModePage extends StatelessWidget {
  const ConnectionModePage({super.key, required this.app});

  final AppModel app;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Scaffold(
      backgroundColor: c.bgBase,
      appBar: AppBar(title: const Text('连接方式'), backgroundColor: c.layer1),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            const _SectionTitle('这台手机走哪条路'),
            for (final policy in RoutePolicy.values)
              _ChoiceRow(
                title: policy.label,
                selected: app.routePolicy == policy,
                onTap: () => app.setRoutePolicy(policy),
              ),
            const _SectionTitle('可用地址'),
            if (app.endpoints.isEmpty)
              const _Note('还没有地址：配对新手机后会自动出现。')
            else
              for (final endpoint in app.endpoints)
                _AddressRow(
                  endpoint: endpoint,
                  active: app.activeEndpoint?.id == endpoint.id,
                  // 只在**上次真的失败**时给一行原因（异常才占位置）。
                  lastFailure: app.attemptOf(endpoint)?.ok == false
                      ? app.attemptOf(endpoint)?.reason
                      : null,
                  onTap: () => connectEndpointNow(context, app, endpoint),
                ),
            _AddRow(onTap: () => addEndpointOnly(context, app)),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: c.labelSecondary,
        ),
      ),
    );
  }
}

/// 一档策略：整行可点，右侧只有"选中"这一个标记。
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.title,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(fontSize: 14, color: c.labelPrimary),
                ),
              ),
              if (selected) DshIcon('check', size: 16, color: c.accentBlue),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一条地址：点了就用它连（当前那条打勾且不再可点）。
class _AddressRow extends StatelessWidget {
  const _AddressRow({
    required this.endpoint,
    required this.active,
    required this.lastFailure,
    required this.onTap,
  });

  final Endpoint endpoint;
  final bool active;
  final String? lastFailure;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Semantics(
      selected: active,
      button: !active,
      child: InkWell(
        onTap: active ? null : onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: DshIcon(
                  endpoint.kind == EndpointKind.direct ? 'link' : 'globe',
                  size: 18,
                  color: c.labelSecondary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      endpointKindLabel(endpoint.kind),
                      style: TextStyle(fontSize: 14, color: c.labelPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      endpoint.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: c.labelCaption),
                    ),
                    if (lastFailure != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        '上次没通：$lastFailure',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: c.error),
                      ),
                    ],
                  ],
                ),
              ),
              if (active)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: DshIcon('check', size: 16, color: c.accentBlue),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 列表末尾的「添加地址」：手动填一条，只加进表、不自动拨。
class _AddRow extends StatelessWidget {
  const _AddRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
        child: Row(
          children: [
            DshIcon('plus', size: 16, color: c.labelSecondary),
            const SizedBox(width: 10),
            Text('添加地址', style: TextStyle(fontSize: 14, color: c.labelPrimary)),
          ],
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Text(text, style: TextStyle(fontSize: 12, color: c.labelTertiary)),
    );
  }
}
