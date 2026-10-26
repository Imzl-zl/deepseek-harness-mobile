import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';

/// 即时提示的两种语气。**没有"成功"这一档**：成功且状态已经看得见时不该弹。
enum DshToastKind { info, error }

/// 全 app 唯一的即时提示（替代各处直接 `ScaffoldMessenger.showSnackBar`）。
///
/// ## 规则
///
/// - **结果在屏幕上直接看得见的不弹**：切模型成功（模型名与推理档就在输入栏上）。
/// - **看不见结果的要弹**：切换端点、重新连接、队列编辑、已复制、已添加 ——
///   执行完屏幕不会自己告诉你"刚才那下成了没有"。
/// - **失败 / 需要解释的一律弹**，用 [DshToastKind.error]，带错误图标、停留更久。
///
/// ## 样式
///
/// 用主题 surface（`layer2`）+ 圆角 + 浮起，不再用 Flutter 默认的深色横条：
/// 默认样式在浅色主题里是一条突兀的黑条，和 DSH 的观感完全不一致。
abstract final class DshToast {
  static void show(
    BuildContext context,
    String message, {
    DshToastKind kind = DshToastKind.info,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final c = context.dshColors;
    final error = kind == DshToastKind.error;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          duration: Duration(seconds: error ? 5 : 2),
          backgroundColor: c.layer2,
          elevation: 6,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DshRadius.md),
            side: BorderSide(color: error ? c.stateError : c.layer3),
          ),
          content: Row(
            children: [
              if (error) ...[
                DshIcon('warningTriangle', size: 16, color: c.stateError),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: c.labelPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
  }
}
