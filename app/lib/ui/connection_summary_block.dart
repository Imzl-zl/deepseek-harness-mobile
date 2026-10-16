/// 「当前连接」块 —— 连接 sheet 与设置页**共用同一个形状**。
///
/// 两行：走哪条（[ConnectionSummary.line]）+ 为什么没走首选
/// （[ConnectionSummary.note]，只在回落时出现）。
///
/// **它不可点**：这是事实的呈示，不是入口。改偏好的入口在设置页的端点列表
/// （那边列得出全部端点）；连接 sheet 因此也把它放在顶部当"一眼能看"的那一行
///（连接方式选择器第 1 步：不用进设置就知道走的哪条）。
library;

import 'package:flutter/material.dart';

import '../model/chat_item.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';

class ConnectionSummaryBlock extends StatelessWidget {
  const ConnectionSummaryBlock({super.key, required this.connection});

  final ConnectionSummary connection;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: DshColors.layer2,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const DshIcon('link', size: 16, color: DshColors.labelSecondary),
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}
