# Agent Note: `workspace.list` 补 `createdAt` —— 空工作区也能当"最近"

Status: implemented

## Problem

DSH 的 `recentWorkspace`（`packages/client/ui-workspace/src/client/navigation.ts:553-572`）
用"每个工作区里会话的最大 `updatedAt`"算最近；**没有会话的工作区**用
`Date.parse(workspace.createdAt)` 参与比较（同文件 `:565`）。

手机侧的 `workspace.list` 行只转四个字段（`workspaceId` / `title` / `path` / `sessionIds`），
没有 `createdAt` —— 于是"刚建的空工作区"永远输给"任何一个有会话的老工作区"。
这是一处已记过的偏离（旧笔记 `2026-10-22-new-session-lands-in-a-workspace.md`，
本轮把它消掉）。

## Decision

1. **连接器原样过线**：`WorkspaceRow` 加 `createdAt: string`（宿主的
   `WorkspaceView.createdAt`，`packages/api/workspace-controller/src/types.ts:27`），
   `workspaces.ts` 的 `list()` 逐字段拷过去 —— 不解析、不换算时区。
2. **手机侧只用来比"谁更新"**：`WorkspaceGroup.createdAt`（ISO 串）+
   `newSessionWorkspaceId` 里"没有会话的工作区取 `Date.parse(createdAt)`"，
   与 DSH 同一条规则。字段缺席（老连接器 / 电脑侧没给）解析成空串 ⇒ 按 `-1`
   处理（**永远最旧**，不猜一个时间）。
3. `_parseIso` 用 `DateTime.tryParse`，解析不了也回 `-1` —— 与上一条同一个兜底。

## Alternatives considered

1. **连接器把 `createdAt` 解析成毫秒时间戳再给手机**
   - 最强理由：手机侧少一次解析。
   - 为何被否：那会让线上格式与宿主字段不同名同义（宿主是 ISO 串），
     而"谁解析"这件事应该在**用它的那一层**（`newSessionWorkspaceId`）。
     原样过线也让将来别的用途（显示"建于何时"）拿得到原文。
2. **手机侧拿不到 `createdAt` 时用"行序第一个空工作区"当最近**
   - 最强理由：总比永远选不中强。
   - 为何被否：那是**编**一个顺序语义 —— 行序是宿主的存储顺序，不是时间。
     缺席就是不知道，按最旧处理（与本项目"拿不到就不猜"同一条）。
3. **只在连接器里补字段，手机侧继续按 `-1`**
   - 最强理由：一行改动，零风险。
   - 为何被否：那样字段过线了但没人用，等于没修；而且下一轮会以为"已经对齐"。

## Consequences

- 收益：新建的空工作区能像 Web 一样赢得"最近"，新会话落点与电脑侧一致。
- 代价与边界：
  - 手机侧多了一次 `DateTime.tryParse`（每轮最多几次，可忽略）。
  - **真机上够不到那条分支**：App 冷启动总会恢复上一次的会话，而"当前会话所在工作区"
    是链的第二步、优先级高于"最近"；没有任何入口能"取消选中会话"。
    所以这一条只有单测证据（`new_session_workspace_test.dart` 三条：空工作区靠
    `createdAt` 赢过老会话 / 字段缺席时仍按最旧 / `workspace.list` 的字段原样落到模型）。
    真机只证了"加了空工作区之后 App 正常"（`h2-drawer-groups.png`：三个组照旧、
    没有多出一个空组）。
  - 抽屉**不列空工作区**（它按会话分组渲染），所以"空工作区"在手机上只在
    "新建会话落到哪"这一件事上可见 —— 与 Web 的侧栏一致。
