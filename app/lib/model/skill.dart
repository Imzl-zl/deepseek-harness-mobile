/// 技能目录（`skill.catalog`，契约 §5.7）：桌面 `/` 菜单的**另一半**。
///
/// ## 它补的是什么
///
/// 桌面的 `/` 菜单是两块拼起来的：宿主的**命令表**（`repo.info.commands`，
/// 形状见 `wire/rpc/repo.dart`）与**这一会话可见的技能目录**
/// （`ui-skill/src/client/index.ts:171-184`：`trigger:'/'`、`order:2`，
/// 子会话里不出现）。手机端命令表早就有了，技能整块没接 —— 于是 `/`
/// 看起来"比桌面少一堆东西"。
///
/// ## 形状出处
///
/// 宿主：`packages/api/session-controller/src/skill-catalog.ts:36` 的
/// `@Remote`（namespace `skills`），应答 `{skills: [{name, path?, description,
/// whenToUse?, modelInvocable}]}`，已经滤成"用户可调用"。
/// 连接器那一侧：`connector/src/dsh/skills.ts` 只留三样
/// （`name` / `description?` / `modelInvocable?`），一行认不出就**跳过那一行**
/// —— 少一条技能优于整张菜单报错（与 `job.list` 同一条口径）。
///
/// ## 技能不是命令
///
/// 选中它只是把 `/名字` 插进输入框、按**普通消息**发出（DSH 把它当引用解析，
/// `ui-skill/src/client/SkillReference.tsx`）。所以这里只有读；写路径是
/// `session.prompt`，不是 `command.execute` —— 手机上那处分流在
/// `model/command.dart` 的 `sendRouteOf` 里**不需要**为技能加分支。
library;

/// 一条技能。
///
/// **只有三样**：名字、宿主的说明、能不能被模型调用。`path` / `whenToUse`
/// 是桌面侧的东西（连接器不过线），手机菜单不画它们。
class SkillEntry {
  const SkillEntry({required this.name, this.description, this.modelInvocable});

  /// 技能名（**不带前导 `/`**；菜单与插入文本都自己加）。
  final String name;

  /// 宿主的说明。`null` = 宿主没给（那一列不画，不编一句）。
  final String? description;

  /// 能不能被**模型**主动调用。`false` = 桌面菜单会标「仅用户可调用」，
  /// `null` = 宿主没报（老连接器）。
  final bool? modelInvocable;
}
