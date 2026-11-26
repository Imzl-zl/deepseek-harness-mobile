# Agent Note: 工作区行的三个动作 —— 新建会话 / 重命名 / 删除，以及为什么没有「在文件夹中显示」

Status: implemented

## Problem

用户 2026-11-26 原话（连着三段）：

> 这个桌面的工作区有一些操作还可以在工作区选中的时候有新会话按钮，APP 也没有

> 在文件夹中显示我们怎么做，那是桌面宿主的能力我们手机怎么显示？你认真看没，有的我们 APP 就做不了吧？新建会话，删除，重命名还行

> 那有啥用我是远程，你就是打开了我又看不了啊？所以不做这个在文件夹打开了，还是做能在手机上操作的这些吧

所以这一批只做三件：**在工作区里新建会话**、**重命名工作区**、**删除工作区注册**。
「在文件夹中显示」被用户明确否掉。

## 「在文件夹中显示」到底能不能做（查证结论，别再翻案）

**能做，但没用** —— 这两件事要分开记，否则下次又有人问一遍。

- 宿主**有**这个 RPC：`openWorkspacePath({path, action:'reveal'})`
  （`packages/api/session-controller/src/index.ts:347-354`，`reveal` 分支调
  `revealNativePath`），还有 `canOpenWorkspacePath()`（`:326-328`）与
  `workspaceDesktop()`（`:332-336`，回 `fileManager: 'finder'|'explorer'|…`）。
  渲染端用法见 `packages/client/ui-file-actions/src/client/context-menus.tsx:38`。
  **我先前说它"不是 RPC"是错的**，`apps/desktop/src/main.ts:117` 那个
  `showItemInFolder` 只是崩溃报告页的专用桥，不是工作区那条。
- 但它执行在**电脑的文件管理器**上：远程用户点完，手机屏幕上什么都不会发生。
  这是用户的原话判断，不是我的推测。

⇒ 不进菜单。菜单里留一个"点了屏幕上没反应"的按钮，比不做更糟。

## Decision

三件事各自的落点：

| 动作 | 宿主 RPC | connector | 手机侧入口 |
|---|---|---|---|
| 在这一组里新建会话 | `session.create`（已有） | 已覆盖 | 组头「＋」 |
| 重命名工作区 | `workspace.rename`（`workspace-controller/src/index.ts:120`）| **新增** | 组头「…」→ 重命名 |
| 删除工作区注册 | `workspace.delete`（`:130`）| **新增** | 组头「…」→ 删除工作区 |

**新建工作区仍不做**：`create` 的 `path` 必须是宿主上已存在的目录
（`commands.ts:36-70` 会 realpath 校验），手机上没地方输一个电脑路径。

## Alternatives considered

1. **把 `renameWorkspace` / `deleteWorkspace` 塞进 `AppModel` 之外的接线层**
   - 最强的理由：`AppModel` 已经 5300 行、尺寸棘轮卡得最紧。
   - 为何被否：写路径必须经过 `AppModel` 才能改 `_workspaces` 并
     `notifyListeners()`；绕过去就要在别处再存一份工作区表 —— 那是第二个真值。
   代价照实记：`verify-size.mjs` 的预算因此**提了**（见下）。
2. **在客户端 `trim()` 标题、判空、判重名**
   - 最强的理由：本地拦掉就不会打一次失败请求。
   - 为何被否：宿主自己 `trim()` 后判空（`commands.ts:74-77`）、重名报
     `workspace/name-conflict`（`:80-87`），而且**与自己的名字相同不算冲突**
     （`:80-83` 直接回旧视图不落盘）。客户端再判一次就是两份规则，且
     `trim` 语义迟早漂移。现在标题**原样发**。
3. **`workspace/name-conflict` 不进 `ERROR_TABLE`**
   - 最强的理由：它不是连接层的事，看起来"归 P2 处理"就够了。
   - 为何被否：`errors.ts:19-22` 写着漏一个码的后果 —— 被归一成 `internal`
     → `log-and-retry` → 用户对着一个永远重试也不好的对话框反复点。
     本仓已经栽过一次（`not-paired` 被报成 `bad-frame`）。
4. **删除工作区时顺手把它的会话也摘掉**
   - 最强的理由：界面上"删了项目，组里那些会话还在别处飘着"看起来不干净。
   - 为何被否：宿主**只删注册**（`commands.ts:94` 的原注释：目录与会话都留着）。
     手机上把会话一起抹掉就是在骗用户 —— 那些会话在电脑上还好好活着。
     所以确认文案也照这个写，不写"删除项目"。

## 二阶影响

1. **尺寸棘轮被提了三次**（`verify-size.mjs`）：`app_model.dart` 5250→5320、
   `main.dart` 1950→1995、`session_drawer.dart` 1400→1650。这是**有意的可见 diff**，
   每处都在表里写了原因。同时做了一次真削减：`DshGroupAction` 抽去
   `ui/dsh_group_action.dart`（它服务组头而不是抽屉，内联列表将来要复用它）。
2. **三处计数闸随之更新**（它们本来就该红）：
   `methods.test.ts` 54→56、`method-name-table.test.ts` 54→56、
   `flow.test.ts` 错误码 35→36、`connection-methods.test.ts` 的 `repo.info`
   金样方法清单 +2。这四处是**契约的同步闸**，红是设计好的。
3. **两条错误码两侧同步**：`connector/src/protocol/errors.ts` 与
   `app/lib/core/errors.dart` 各加 `workspace/name-conflict`
   （clientAction = `disable-and-annotate`），契约 §3.1 的表同步加一行。
4. **「＋」只出现在真工作区行**：`workspaceId == null` 的桶（「未分组」/
   没有清单时的「会话」）不画动作 —— 硬放上去只会得到一句失败。这与 DSH Web
   的 `ProjectRowActions`（`ui-workspace/src/client/rows/Rows.tsx:142` 的接口、
   `:238` 的 `create !== undefined` 门：未分组桶因 `create` 缺席就没有这一枚）同一条。
   动作顺序也照 DSH：`:230-249` 的 `rowActions` 里「…」在 `:231-237` 在前、
   「＋」在 `:238-249` 在后（`Rows.module.css:118` 没反转，DOM 序 = 视觉序）。
5. **两个新建入口共用一条实现**：顶部那个落到"最近的工作区"、组头这个落到
   用户点的那一组，差异只有目标工作区；复用 blank、在途合并、失败提示
   全部走同一个 `_newSessionIn`。各写一份迟早有一边忘了复用 blank，
   于是每点一次电脑上就多一条空会话。

## Consequences

- 收益：工作区行能直接建会话/改名/删注册，不用再去电脑上操作。
- 代价：`main.dart` 的分页装配回调又多三条；`main.dart` 与 `session_drawer.dart`
  的预算提高，下一批功能该先削减。
- 明确不做：`workspace.create`（要电脑路径）、reveal（远程看不见）。

## 回归网

- `connector/tests/workspaces-archive.test.ts` 新增 4 条：改名的载荷形状
  （**标题不 trim**）与 `sessionIds` 过别名、重名原样抛码、删除只发
  `workspaceId` 且回 `{deleted: true}`、端口抛错时**不回** `deleted`。
- `app/test/workspace_rename_delete_test.dart` 9 条：标题原样发、同值不发请求、
  重名/认不出的应答**不动本地表**、删除后**会话列表长度不变**、缺工作区时不打请求。

**变异校验（两条，都红）**：
- 在客户端对标题 `trim()` ⇒ "标题原样发"这条红（证明测试钉住了这个边界）；
- 把 `deleteWorkspace` 改成"应答认不出也摘组" ⇒ "认不出的应答不能当成删成功"红。
