/// 「当前连接」块 —— 连接 sheet 与设置页**共用同一个形状**。
///
/// 三行信息：走哪条（[ConnectionSummary.line]）+ 为什么没走首选
/// （[ConnectionSummary.note]，只在回落时出现）。
///
/// ## 它现在是**呈示**，入口在「连接方式」页（2026-11-13）
///
/// 选哪条地址、改策略都在 `connection_mode_page.dart`。这块以前自己弹一个
/// 选择框，于是"选地址"有两处实现、策略又住在设置页第二组 —— 三处分头长。
/// 现在它只显示事实 + 一个重连图标（`onReconnect`）。
library;

import 'package:flutter/material.dart';

import '../core/endpoint.dart';
import '../data/app_model.dart';
import '../model/chat_item.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import 'add_endpoint_dialog.dart';
import 'dsh_toast.dart';

/// 用一条端点**立刻连**（本次覆盖；失败回自动并说明原因）。
///
/// 连接 sheet 的列表、设置页端点行、连接方式页共用这一份反馈 ——
/// 三处各写一遍 toast 文案就是"同一个事实多处表达"。
Future<void> connectEndpointNow(
  BuildContext context,
  AppModel app,
  Endpoint endpoint,
) async {
  final label = endpointKindLabel(endpoint.kind);
  // **先给"正在试"的反馈再 await**：握手要几百毫秒，静默会让人觉得没点上。
  DshToast.show(context, '正在用「$label」连接…');
  final ok = await app.useEndpointNow(endpoint);
  if (!context.mounted) return;
  if (ok) {
    // 切端点后"现在走哪条"只在设置块里看得到，不在当前屏 —— 成功要回执。
    DshToast.show(context, '已连上「$label」');
    return;
  }
  final reason = app.endpointRequestResult?.reason;
  DshToast.show(
    context,
    reason == null || reason.isEmpty
        ? '这条没连上，已回到自动选择'
        : '这条没连上（$reason），已回到自动选择',
    kind: DshToastKind.error,
  );
}

/// **只加一条地址，不自动拨**（换了网络、旧地址全拨不通时的那条出路）。
///
/// 与设置页「添加端点」共用同一个对话框、同一句承诺：加进表之后由用户自己选它连接
/// （`connection_mode_page.dart` 的地址行）。配对凭据与地址无关，所以**不需要重新扫码**。
Future<void> addEndpointOnly(BuildContext context, AppModel app) async {
  final added = await showAddEndpointDialog(context);
  if (added == null || !context.mounted) return;
  // 勾了"公网明文"的确认就先记下来（否则下一次换票会被地址边界拒）。
  if (added.allowPlaintextPublic) {
    await app.setAllowPlaintextPublic(true);
    if (!context.mounted) return;
  }
  await app.addManualEndpoint(added.endpoint);
  if (!context.mounted) return;
  DshToast.show(context, '已添加 ${added.endpoint.url}（在「换个连接方式」里选它连接）');
}

/// **重新拨一次**：不改偏好、不换端点。
///
/// 走 [AppModel.reconnectLink] 而不是直接 `onReconnect`：用户按过「断开连接」
/// 之后，这里同时是**恢复**动作（清掉"我要离线"那条意图），否则拨了也还是断的。
Future<void> reconnectNow(BuildContext context, AppModel app) async {
  final reconnect = app.onReconnect;
  if (reconnect == null) return;
  DshToast.show(context, '正在重连…');
  await app.reconnectLink();
  if (!context.mounted) return;
  // 状态点要等握手才有变化，"点了没点上"这一拍需要回执。
  DshToast.show(context, '已重新发起连接');
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
    final c = context.dshColors;
    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: DshIcon('link', size: 16, color: c.labelSecondary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                connection.line,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: c.labelPrimary,
                ),
              ),
              if (connection.note case final note?) ...[
                const SizedBox(height: 4),
                Text(
                  note,
                  style: TextStyle(fontSize: 12, color: c.labelSecondary),
                ),
              ],
              // **不写"点这里换一条"**：这块整体可点、右边那个图标就是重连，
              // 一眼就能试出来的一句话不值得每屏都占一行小字。
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
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: c.labelSecondary,
                    ),
                  )
                : DshIcon('refresh', size: 16, color: c.labelSecondary),
          ),
      ],
    );

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: c.layer2,
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
