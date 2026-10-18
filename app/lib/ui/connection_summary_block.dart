/// 「当前连接」块 —— 连接 sheet 与设置页**共用同一个形状**。
///
/// 三行信息：走哪条（[ConnectionSummary.line]）+ 为什么没走首选
/// （[ConnectionSummary.note]，只在回落时出现）。
///
/// ## 它是**入口**，不只是呈示（2026-10-18 改）
///
/// 用户的原话是"当前连接点击弹框选择连接方式直接连接就挺好啊，最好再有一个
/// 重连图标可以点；干嘛非要在队列上点？"——这条把两个动作**归位**：
///
/// - **切换连哪条**（会立刻断当前连接）：从这里进 → 弹框选一条 → 直接连；
/// - **重连**（不断偏好，只是重新拨一次）：右侧那个刷新图标。
///
/// 而下面的端点列表回到它本来的角色：**看和管**（排序 / 删除 / 手填），
/// 点一下不再触发重拨。理由：队列是"顺序与清单"，把"立刻重连"这种有副作用的
/// 动作放在逐行点击上，会在管理偏好时不断打断当前连接。
library;

import 'package:flutter/material.dart';

import '../core/endpoint.dart';
import '../data/app_model.dart';
import '../model/chat_item.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import 'dsh_sheet.dart';

/// 「换个连接方式」：选一条端点并**立刻用它连**。
///
/// 两处入口共用（设置页顶部块 / 顶栏状态点的连接 sheet）—— 用户的原话是
/// "页面的右上角的点最好也可以点击切换方式重连"，所以两边必须是**同一个**选择框。
///
/// 列表按当前队列顺序排；正在用的那条打勾、点它无效（那是重连，不是换）。
Future<void> pickEndpointToConnect(BuildContext context, AppModel app) async {
  if (app.endpoints.isEmpty) return;
  final messenger = ScaffoldMessenger.of(context);
  final picked = await showDshSheet<Endpoint>(
    context: context,
    title: '选择连接方式',
    body: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final endpoint in app.endpoints)
          DshPickerRow(
            name: endpointKindLabel(endpoint.kind),
            tags: [
              endpoint.url,
              if (endpoint.label.isNotEmpty) endpoint.label,
              if (app.activeEndpoint?.id == endpoint.id) '当前连接',
            ],
            selected: app.activeEndpoint?.id == endpoint.id,
            icon: endpoint.kind == EndpointKind.direct ? 'link' : 'globe',
            enabled: app.activeEndpoint?.id != endpoint.id,
            onTap: () => Navigator.of(context).pop(endpoint),
          ),
      ],
    ),
  );
  if (picked == null) return;

  final label = endpointKindLabel(picked.kind);
  // **先给"正在试"的反馈再 await**：握手要几百毫秒，静默会让人觉得没点上。
  messenger.showSnackBar(SnackBar(content: Text('正在用「$label」连接…')));
  final ok = await app.useEndpointNow(picked);
  final reason = app.endpointRequestResult?.reason;
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        ok
            ? '已连上「$label」'
            : reason == null || reason.isEmpty
            ? '这条没连上，已回到自动选择'
            : '这条没连上（$reason），已回到自动选择',
      ),
    ),
  );
}

/// **重新拨一次**：不改偏好、不换端点。
Future<void> reconnectNow(BuildContext context, AppModel app) async {
  final reconnect = app.onReconnect;
  if (reconnect == null) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('正在重连…')));
  await reconnect();
  messenger.showSnackBar(const SnackBar(content: Text('已重新发起连接')));
}

class ConnectionSummaryBlock extends StatelessWidget {
  const ConnectionSummaryBlock({
    super.key,
    required this.connection,
    this.onTap,
    this.onReconnect,
    this.reconnecting = false,
  });

  final ConnectionSummary connection;

  /// 点整块 → 弹框选一条并直接连。`null` = 只呈示（连接 sheet 用）。
  final VoidCallback? onTap;

  /// 重新拨一次当前连接。`null` = 不给这个按钮。
  final VoidCallback? onReconnect;

  /// 正在重连（图标转圈、按钮禁用）。
  final bool reconnecting;

  @override
  Widget build(BuildContext context) {
    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 1),
          child: DshIcon('link', size: 16, color: DshColors.labelSecondary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                connection.line,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: DshColors.labelPrimary,
                ),
              ),
              if (connection.note case final note?) ...[
                const SizedBox(height: 4),
                Text(
                  note,
                  style: const TextStyle(
                    fontSize: 12,
                    color: DshColors.labelSecondary,
                  ),
                ),
              ],
              if (onTap != null) ...[
                const SizedBox(height: 4),
                const Text(
                  '点这里换一条 · 右边是重连',
                  style: TextStyle(
                    fontSize: 11,
                    color: DshColors.labelTertiary,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (onReconnect != null)
          // **独立的点击区域**：整块已经是一个按钮（换一条），重连必须是另一个
          // 不相交的命中区，否则点重连会先触发"换一条"的弹框。
          IconButton(
            tooltip: '重连',
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(),
            onPressed: reconnecting ? null : onReconnect,
            icon: reconnecting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: DshColors.labelSecondary,
                    ),
                  )
                : const DshIcon(
                    'refresh',
                    size: 16,
                    color: DshColors.labelSecondary,
                  ),
          ),
      ],
    );

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: DshColors.layer2,
        borderRadius: BorderRadius.circular(12),
      ),
      child: onTap == null
          ? content
          : InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
              child: content,
            ),
    );
  }
}
