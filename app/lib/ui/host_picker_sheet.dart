/// 切换电脑（一台手机配多台电脑）的唯一入口形状。
///
/// ## 它回答什么
///
/// "我还能连哪几台、现在连的是哪台"。列表来自凭据层按 `hostId` 分槽的**派生读**
/// （`PairingStore.hosts()`）—— 不另存一份"已配对电脑清单"，那是同一个事实的第二处表达。
///
/// ## 三条约束
///
/// 1. **行 = `[名称 / 其下标签组] [勾位(恒占位)]`**（根 `AGENTS.md` 的选择类列表规则）：
///    名称是电脑自报的名字（读不到就用 `hostId` 短码），短码与"当前"放第二行标签组，
///    **不做与名称同行的第三列**。
/// 2. **点一行 = 切过去**：切换是用户动作（方案决策 6 / 9），这里不自动挑、不预选。
/// 3. **"当前"那一行照常可点**（点了等于重连一次），不做"点了没反应"的假交互 ——
///    用户想重连时最自然的动作就是点自己那台。
library;

import 'package:flutter/material.dart';

import '../platform/pairing_store.dart';
import '../theme/dsh_colors.dart';
import 'dsh_sheet.dart';

/// 弹出电脑列表；返回被选中的 `hostId`（取消返回 `null`）。
///
/// [currentHostId] 只用于标出"当前"那一行（`null` = 还没配对）。
Future<String?> pickPairedHost(
  BuildContext context, {
  required List<PairedHost> hosts,
  required String? currentHostId,
}) {
  return showDshSheet<String>(
    context: context,
    title: '切换电脑',
    body: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final host in hosts)
          DshPickerRow(
            name: host.label,
            // 第二行：短码（同名靠它分）+ 状态。名字可改可重名，短码不会。
            tags: [
              host.shortCode,
              if (host.hostId == currentHostId) '当前' else '已配对',
            ],
            selected: host.hostId == currentHostId,
            onTap: () => Navigator.of(context).pop(host.hostId),
          ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '切换会立刻断开当前那台，界面只显示新那台的会话；它被别的设备占着时会停在"未连接（被占用）"。',
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              color: context.dshColors.labelSecondary,
            ),
          ),
        ),
      ],
    ),
  );
}
