# Agent Note: 后台任务簇搬出 `AppModel` —— 收窄的第一簇（第一刀真掉的）

Status: implemented

## Problem

`AppModel` 已经 5209 行 / 178 个方法 / 235 个可变字段。收窄提案
（`proposed/2026-10-27-ui-state-design.md`）说"按簇收窄"，已经搬出去的是
`EndpointBook` / `HostCatalogs` / `UiStateStore` 三簇，**之后就没有下一簇了** ——
提案躺在 `proposed/`，而 `AppModel` 还在长。

2026-11-10 加了尺寸预算棘轮（`implemented/2026-11-10-size-budget-ratchet.md`），
于是"再长"这件事第一次会红。但棘轮只挡增长，**不证明搬得动**：一条只见过"不许变长"
的门禁，无法说明"缩短是安全的"。这一批就是第一刀真掉。

## Decision

把**后台任务簇**整簇搬进 `data/job_book.dart`（`JobBook`）：

| 搬走的东西 | 原来在 `AppModel` |
|---|---|
| `_jobs` / `_followedJobs` / `_jobOutput` / `_jobErrors` 四个表 | `:1079-1090` |
| 桶归属规则（带 sid 就归那个桶；不带 sid 退回当前会话，且只在桶已存在时） | `:1206-1237` |
| 终态单向合并的调用点（规则本身仍只在 `core/job.dart`） | 同上 |
| 输出只追加 / `gapBefore` / `lossy` 的处理 | `:1179-1196` |
| `follow` 的幂等（"点了两下、输出翻倍"） | `:1137-1143` |

`AppModel` 只剩三件事：转发读面（`jobsOf` / `jobOutput` / `jobError` / `isJobFollowed`）、
**编排**（`_writes.followJob/unfollowJob/killJob` 这些网络端口）、**通知**
（`maybeRemind → _syncNotices` 与 `notifyListeners`）。

边界的判据（写进文件头，避免下次又搬回来）：

- `JobBook` **不认识端口**：它不订阅、不 kill、不发帧。
- `JobBook` **不认识会话**：需要"当前会话"的地方由调用方传 `fallbackSid`
  （这条很关键 —— 原来 `row.sid ?? _currentSid` 直接读了 `AppModel` 的私有字段）。
- `JobBook` **不发通知**：`applyFrame` 返回"要不要重算提醒"，由调用方决定。

## Alternatives considered

1. **先搬会话执行簇（发消息 / 取消 / 翻页 / 恢复）**
   - 最强的理由：它是 `AppModel` 里最大的一簇，搬完数字掉得最多。
   - 为何被否：它与 `_stores` / `_rows` / 水位 / 投影纠缠在一起（见
     `proposed/2026-11-11-session-memory-compaction.md` 列的四个边角），
     而任务簇的四个表**只有内部一致性**，没有跨簇依赖。
2. **先搬通知簇**
   - 最强的理由：`_desiredNotices` 是纯函数式的（读条目与任务行算出一批提醒）。
   - 为何被否：它读 `_stores`（`:3198` 逐会话扫条目）与 `_jobs`（任务完成那一条）。
     任务簇先搬出去，它才有一个明确的外部依赖面；顺序反了会把两个簇绑在一起搬。
3. **连 `_writes` 一起搬进 `JobBook`（让它自己发请求）**
   - 最强的理由：`followJob` 的"本地标记 + 网络 + 回滚"三段在一个类里最内聚。
   - 为何被否：那样 `JobBook` 就要认识 `AppModel` 的错误模型与 `notifyListeners`，
     变成"另一个 AppModel"。状态与编排分开，正是这一簇值得搬的理由。

## Consequences

- 收益：`AppModel` **5136 行 / 176 个方法**（−73 行、−2 个方法）。数字掉得不多，
  但这是"棘轮只降不升"第一次被真实验证 —— 改完 `verify-size` 立刻红，要求把
  上限从 5250 / 178 收紧到 5150 / 176。**收紧动作本身是这批的产物**：不收紧，
  棘轮就松回去了。
- 收益：桶归属那三条判据（带 sid / 不带 sid / 全局同步同 id）现在只在一个文件里，
  且它们的注释一起搬了过去 —— 原来它们埋在 5000 行的中段。
- 代价：`JobBook` 的 `applyFrame` 返回 `bool`（要不要重算提醒）是一个隐式契约。
  它是**两个消费者之间唯一的耦合**（`_applyJobFrame` 是唯一调用点），刻意选了
  返回值而不是回调，因为回调会让"谁发通知"重新变模糊。
- 代价：`_applyJobRow` 原来在桶命中时 `notifyListeners()` 后再 `return`，所以一帧可能
  通知两次（桶内一次、`_applyJobFrame` 末尾一次）。搬完只剩末尾一次 —— 行为更收敛，
  但**这是一处行为变化**，靠 `job_panel_test` / `job_merge_test` / 全量 1812 项钉住。
- 未做：任务输出缓冲仍**只追加、无上限**（`job_book.dart` 的 `_output`）。它与会话缓存
  是同一类问题（见 `proposed/2026-11-11-session-memory-compaction.md`），
  但那一篇讨论的是条目表；输出缓冲要不要裁、裁多少，需要单独量一次
  （一条 `flutter build` 的日志可以到 MB 级）。
- 未做：`_stores` 与通知簇。下一簇按 §"Alternatives 2" 的顺序：通知簇（因为它的外部
  依赖面已经清晰），再会话执行簇。
