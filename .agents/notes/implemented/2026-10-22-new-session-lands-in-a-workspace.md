# Agent Note: 新建会话必须带 workspaceId（照 DSH 的链解析）

Status: implemented

## Problem

用户在真机上发现：**手机新建的会话永远落在「未分组」**。

根因不是分组算法，而是 `session.create` **没带 `workspaceId`**：宿主只在给了它的时候
才 `workspace.attachSession`（`packages/api/session-controller/src/commands.ts:116-148`），
而手机侧的分组只认 `workspace.list` 的 `sessionIds`（会话行里没有 `workspaceId`，
见 `app/lib/model/workspace.dart` 的 `workspaceGroupOf`）。
于是"没带" = "永远未分组"，而 DSH Web 从不这么建：它的新建链是
`显式 ?? 当前会话工作区 ?? 最近工作区`（`ui-workspace/src/client/navigation.ts:320-334`），
两者都没有时干脆不建（`:335-341`）。

## Decision

`AppModel.createSession` 在没给 `workspaceId` 时按 DSH 的链解析并带上；
`findBlankSession` 只复用**该工作区里**的 blank；建完立刻重读一次 `workspace.list`。

准入门槛（可机械判定）：

1. **链的顺序**：显式 > 当前会话所在工作区 > 最近工作区
   （`newSessionWorkspaceId`，`app/test/new_session_workspace_test.dart` 五条）。
2. **"最近"的算法**：每个工作区里会话的最大 `updatedAt`，并列按宿主行序
   （`navigation.ts:553-572`）。
3. **解析不出来就不塞**：这台电脑一个工作区都没有时，请求体里**没有**
   `workspaceId`（那时"未分组"是事实，不是缺陷）。
4. **建完要重读**：`createSession` 之后 `currentWorkspace` 立刻等于解析结果
   （否则抽屉会先把它摆在「未分组」，等下次刷新才归位 —— 真机实测：
   不重读的话要杀 App 重开才对）。
5. **复用也要在同一组**：`findBlankSession(workspaceId:)` 只认
   `blank && cwd == workspace.path && workspace.sessionIds.includes(id) && !archived`
   （`navigation.ts:220-233`）。

## Alternatives considered

1. **给「未分组」一个解释（文案说明"手机上建的会话不进项目"）**
   - 最强的理由：零代码改动、零风险；"未分组"本来就是一个合法的兜底桶，
     而手机确实没有"当前工作区"这个概念的全部上下文。
   - 为何被否：Web 上没有这个现象（它总是带 `workspaceId`），
     而用户的目标是"手机上开的新任务出现在我当前的项目里"。解释不能替代行为。
2. **把当前 `cwd` 当工作区（`session.create({cwd})`）**
   - 最强的理由：`session.create` 一直收 `cwd`，一行就够；
     而且"会话在哪个目录跑"看起来就是分组的依据。
   - 为何被否：`cwd` 与工作区**不是一对一**（一个目录可能不属于任何工作区，
     一个工作区也可能被改过路径），而且给了 `cwd` 就**不能**同时给 `workspaceId`
     （`commands.ts:112-113` 明确拒），等于放弃 attach 这条路 —— 会话照样不进账本。
3. **在手机侧本地把新会话塞进当前分组（只改显示）**
   - 最强的理由：一次本地插入就能让用户"看到它在项目里"，不必等宿主。
   - 为何被否：那是第二份真值 —— 下次 `workspace.list` 一刷新就跳回「未分组」，
     而"显示与账本不一致"比"诚实地未分组"更难查。
4. **补一个 `workspace.initializeDefault` 方法面，让手机能建默认工作区**
   - 最强的理由：DSH 自己在"两个目录都空"时会建默认工作区
     （`navigation.ts:462-466` 的 `initializeDefaultWorkspace`），
     补上它才算完整对齐。
   - 为何被否：方法面是封闭集，加一个方法要同步契约 §5.7、连接器、错误码三处；
     而"这台电脑一个工作区都没有"在本 profile 里不会发生（DSH 桌面端启动时就会建）。
     先把解析链做对，这条留作已知缺口。

## Consequences

- 收益：手机建的会话出现在当前项目分组里；建完立刻可见（不必重启）；
  blank 复用不会跨组。
- 代价：`createSession` 多一次 `workspace.list` 往返；
  "最近工作区"的算法里**缺 `createdAt`**（我们的 `workspace.list` 行只转四个字段，
  `connector/src/dsh/workspaces.ts:187-192`），所以"没有任何会话的工作区"
  永远不会被选中 —— 与 DSH 的 `recentWorkspace` 有一处已知偏离，
  写进了 `model/workspace.dart` 的注释与 `docs/subsystems/trajectory-page.md` 之外的那条链说明。
