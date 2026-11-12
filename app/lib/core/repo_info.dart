/// `repo.info` 里**手机消费的那几样**，**解好之后的值**。
///
/// ## 为什么在 `core/`
///
/// 端口（`core/host_rpc.dart` 的 `HostRpc`）要能把它交出来，而端口是 `data/` 认的那一面。
/// `caps` / `commands` / `methods` 怎么拆、缺键算不算漂移，全在 `wire/rpc/repo.dart`。
///
/// Note: 分批见 `.agents/notes/implemented/2026-11-06-p1b-batch2-catalog-family.md`。
library;

import '../model/command.dart' show SlashCommand;

/// `repo.info` 的能力位与版本。
final class RepoInfo {
  const RepoInfo({
    required this.slashCommands,
    required this.mentionsAvailable,
    required this.filesAvailable,
    required this.changesAvailable,
    required this.pluginsAvailable,
    required this.jobsAvailable,
    required this.dshVersion,
    required this.hostName,
    required this.methodCount,
  });

  /// `/` 候选菜单的内容（**电脑侧原样过线**，手机不抄第二份）。
  final List<SlashCommand> slashCommands;

  /// `caps.references`：`@` 面板显不显示。
  final bool mentionsAvailable;

  /// `caps.files`：文件页显不显示。
  final bool filesAvailable;

  /// `caps.changes`：收口改动卡画不画。
  ///
  /// 缺了（老连接器 / 没装 `workspace-changes` 的部署）就**不画卡片** ——
  /// 一张永远读不到的卡比没有更糟。
  final bool changesAvailable;

  /// `caps.plugins`：插件页显不显示。
  final bool pluginsAvailable;

  /// `caps.jobs`：能不能拉任务表。
  ///
  /// **与上面四个不同**：它们决定"这一屏显不显示"（缺了就不画），
  /// 而这个决定**要不要发 `job.list`** —— 缺 jobs 服务的部署里连接器
  /// 根本不挂 `job.*`（`connector/src/handlers.ts:1582`），发出去只会拿
  /// `connector/unsupported`，而它会被画成"任务读取失败"：**把缺服务画成故障**。
  ///
  /// 反过来的默认也不同：caps 里**没有**这个键时按 `true` 处理（老连接器照样能拉），
  /// 因为这里"猜错"的代价是一次多余的成功调用，而不是整块能力消失。
  final bool jobsAvailable;

  /// 电脑侧 DSH 运行时版本（拿不到就是 `null`，不编一个）。
  final String? dshVersion;

  /// 电脑自报的名字（`os.hostname()` 原值；老连接器不报 ⇒ `null`）。
  ///
  /// **纯展示值**：可改、可伪造、会重名，从不参与判据
  /// （`proposed/2026-10-29-one-phone-many-computers.md` 决策 2）。
  final String? hostName;

  /// `methods` 的**条数**（形状检查用；方法名手机不读）。
  final int methodCount;
}
