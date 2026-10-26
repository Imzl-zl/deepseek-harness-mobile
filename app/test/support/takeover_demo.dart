/// **测试专用**的三条接管交互（原来产品里的「＋ → 演示：接管输入栏」）。
///
/// 2026-10-26：发版前删掉产品里的演示入口（审批 / 提问 / 计划长什么样不该
/// 靠一个假入口展示）。这三条搬到测试里，走
/// `AppModel.emitInteractionForTest` 注入 —— 与真实信号的入口同一条流，
/// 只是不经过会话事件投影。
library;

import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/interaction.dart';

/// 一条审批。
const InteractionItem demoApproval = InteractionItem(
  itemId: 'demo-approval',
  sid: 'preview-1',
  callId: 'demo-call-approval',
  kind: InteractionKind.approval,
  toolName: 'bash',
  title: '工具 bash 请求越权执行',
  detail:
      'rm -rf build/ && flutter clean\n\n'
      '只读 / 工作区内修改模式下，越权操作要你确认；\n'
      '完全权限模式下这一步不会出现（那是"已授权"的结果）。',
);

/// 一条提问：三条选项 —— 真机上溢出的那一问就是三条（回归用例要同一形状）。
const InteractionItem demoQuestion = InteractionItem(
  itemId: 'demo-question',
  sid: 'preview-1',
  callId: 'demo-call-question',
  kind: InteractionKind.question,
  header: 'DSH 想确认一件事',
  title: '拆连接层的资源束时，要不要顺手把「在途请求」也一起拆出去？',
  questions: [
    InteractionQuestion(
      id: 'demo-q1',
      header: 'DSH 想确认一件事',
      question: '拆连接层的资源束时，要不要顺手把「在途请求」也一起拆出去？',
      options: [
        InteractionOption(
          // 标签里不写"（推荐）"：界面把它剥成独立徽标。
          label: '一起拆',
          description: '它俩生命周期不同：资源束每连接换一份，在途请求要跨重连保留',
          recommended: true,
        ),
        InteractionOption(label: '先只拆资源束', description: '改动更小，但在途请求那个缺口会留着'),
        InteractionOption(
          label: '先不动，等我画张图',
          description: '把两层画清楚再决定，代价是这一轮先停在原地',
        ),
      ],
    ),
  ],
);

/// 一条计划审查。
const InteractionItem demoPlan = InteractionItem(
  itemId: 'demo-plan',
  sid: 'preview-1',
  callId: 'demo-call-plan',
  kind: InteractionKind.plan,
  title: '把侧抽屉的「任务」面板接上 job 帧',
  approveLabel: '同意执行',
  questions: [
    InteractionQuestion(
      id: 'demo-call-plan',
      question: '把侧抽屉的「任务」面板接上 job 帧',
      detail:
          '1. 展开时 `job.follow`，收起时 `job.unfollow`\n'
          '2. 把三帧映射成 SideJob\n'
          '3. 停止走 `job.kill`，两步确认',
      options: [
        InteractionOption(label: '同意执行'),
        InteractionOption(label: '要求修改'),
      ],
    ),
  ],
);

/// 按 DSH 的优先级（计划 → 提问 → 审批）推进三条交互。
void enqueueDemoTakeovers(AppModel app) {
  for (final item in const [demoPlan, demoQuestion, demoApproval]) {
    app.emitInteractionForTest(InteractionOpened(item));
  }
}
