/// 右抽屉这一次该有哪几枚面板。
///
/// **一处判据**：tab 条、计数徽标、面板主体都读它（`ui/side_pane.dart` 的
/// `SidePane.panels`），所以"tab 在但主体空"这种形态不可能出现。
///
/// 判据本身只有两条：
///
/// 1. `file` / `jobs` / `subs` 恒在（抽屉的基线三枚）；
/// 2. `team`（共享任务板）要两个条件同时成立：
///    - `teamAvailable` —— 电脑侧有 `agentTeams` 服务（`repo.info.caps.team`）。
///      老宿主 / 没带 tool bundle 的部署 ⇒ 整枚不出现，**不摆一块永远空着的板**；
///    - 当前会话**是根会话** —— 照抄 DSH：子会话连开关带任务板一起不显示
///      （`packages/client/ui-agent-team/src/client/TeamModeToggle.tsx:30-32` 对
///      `addressedChild || listedChild` 直接 `return null`；README 原话
///      "Child conversations keep subagent navigation without a task board or Team switch"）。
///      子会话自己那块投影**是空板**（`enabled: false`），画出来会与"根会话没开 Team"
///      同形 —— 那不是共享事实，是误导。
///
/// `caps.team` 只回答"这台电脑有没有这个服务"，**不管 Team 开没开**（那是投影的
/// `enabled`）。两件事混成一个能力位，会出现"服务在、开关关着却被当成没能力"。
///
/// 取舍与证据见 `.agents/notes/implemented/2026-11-14-agent-team-integration.md`。
library;

import 'side_pane.dart' show SidePanel;

/// 这一次要显示哪几枚面板。
List<SidePanel> visibleSidePanels({
  required bool teamAvailable,
  required bool childSession,
}) => [
  SidePanel.file,
  SidePanel.jobs,
  SidePanel.subs,
  if (teamAvailable && !childSession) SidePanel.team,
];
