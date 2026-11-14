/// 模型菜单的**主体**（`ui/chat_page.dart` 的 `_showModelSheet` 只负责开 sheet）。
///
/// ## 为什么单独一个文件
///
/// 这段是"按 provider 分组列模型 + 末尾一行 Agent Teams 开关"，本身不需要 `ChatPageState`
/// 的任何状态 —— 它要的只有 `AppModel` 与"选中某个模型"的回调。留在 `chat_page.dart`
/// 里只会让那个已经超预算的文件继续长（`app/tools/verify-size.mjs` 的棘轮）。
///
/// ## 为什么要 `ListenableBuilder`
///
/// sheet 是**一次性构建**的静态 widget，不在 `ChatPage.build` 的监听范围里。
/// 2026-11-14 真机教训：宿主的 `team/mode` 已经写了（连接器幂等表里 4 条 `ok:true`、
/// 宿主投影 `agentTeam.enabled: true`），手机上那枚开关却还停在"关" ——
/// 因为投影回读之后，这张 sheet 没有任何东西会重画它。
/// DSH 侧没有这个问题：它的开关读 `useProjection('agentTeam')`（订阅式）。
///
/// 所以这里**整段包在 `ListenableBuilder(app)` 里**，`AppModel` 一通知就重画；
/// 而 `setTeamEnabled` 写完会重读投影并通知（`app_model.dart`），闭环才成立。
///
/// Note: 开关的位置与判据见 `docs/subsystems/agent-team.md` §5。
library;

import 'package:flutter/material.dart';

import '../data/app_model.dart';
import '../model/model_catalog.dart';
import '../theme/dsh_colors.dart';
import 'dsh_sheet.dart' show DshPickerRow;
import 'team_mode_row.dart';

/// 建模型菜单主体。
///
/// @param app - 会话状态（模型目录、Team 投影、当前模型）
/// @param onPick - 点中某个模型行（由 `ChatPage` 决定是直接切还是进推理等级二级页）
Widget buildModelSheetBody({
  required AppModel app,
  required void Function(ModelProviderGroup group, ModelCatalogEntry entry)
  onPick,
}) {
  return ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final c = context.dshColors;
      final catalog = app.modelCatalog;
      final current = app.currentModel;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final group
              in catalog?.groups ?? const <ModelProviderGroup>[]) ...[
            // 分组头（provider 名）—— Web 的根菜单同样按 provider 分组。
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
              child: Text(
                group.name,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: c.labelCaption,
                ),
              ),
            ),
            for (final entry in group.models)
              DshPickerRow(
                // **只显示模型名**：渠道由上面的分组头表达，说明文字与"几档推理"
                // 都是废话（用户 2026-10-26 原话："你就显示渠道和模型不就行了"）。
                name: entry.displayName,
                tags: const [],
                selected:
                    current != null &&
                    current.provider == group.id &&
                    current.model == entry.id,
                onTap: () => onPick(group, entry),
              ),
          ],
          // Team 开关就在**模型菜单**里，与 DSH 同一个位置
          // （slot `conversation.input.model.options`，`ui-agent-team/README.zh.md:28`）。
          // 三条不显示的条件在 `teamModeRowFor` 一处判（子会话 / 没投影 / 没能力位）。
          ?teamModeRowFor(
            teamAvailable: app.teamAvailable,
            childSession:
                app.sessionOf(app.currentSid ?? '')?.subagent ?? false,
            boardReady: app.teamBoard != null,
            enabled: app.teamBoard?.enabled ?? false,
            modelEverUsed: app.modelEverUsed,
            hasCurrentModel: current != null,
            onSetEnabled: (enabled) async {
              // 写完由 `AppModel` 重读投影，上面的 `ListenableBuilder` 跟着重画
              // （不做乐观更新：值只来自投影）。
              if (await app.setTeamEnabled(enabled)) return null;
              return app.lastError?.message ?? '未知原因';
            },
          ),
        ],
      );
    },
  );
}
