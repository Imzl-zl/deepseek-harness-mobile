# Agent Note: 会话页/输入栏/右侧面板/侧边栏 —— 用户 2026-10-19 夜间反馈的调研结论

Status: proposed

> 本篇只记**查证到的事实**与**已定的方向**，实现分批评交。
> 每条都给 `packages/...:行号`（DSH）或绝对路径:行号（rikkahub）。

## 用户反馈原文（2026-10-19）

1. 「用量应该在设置前面吧？」
2. 「然后整个会话页面和输入框背景这一块设计不和谐吧」
3. 「然后用户信息这个我刚开始一直以为渲染问题呢，后来才发现这个是用户消息，
   你看看人家这个 rikkahub 怎么设计的」
4. 「我觉得这个 rikkahub 很多可取的地方，比人家的上传点击弹框有拍照，图片，
   上传文件啥的」
5. 「dsh web 我看每个消息完毕有复制用量啥的（具体自己看）」
6. 「然后右侧弹出的，你看人家 web 的右侧弹出的，你这个文件切换到任务（是后台
   任务吧），子智能体还变化大小多割裂啊（你这个你看多大合适，不全屏，然后有一个
   全面的图标，点击全屏，点击缩回不好了，然后 dsh web 的后台任务点击是可以看的
   还有停止啥的，子智能体是列表，每一个点击是能进入的，具体的还是看 web 的源码就行」
7. 「对了会话页面，没有会话的时候对话，轨迹不用显示吧，没会话你显示没用啊」
8. 「对了你这个新会话的逻辑是啥样的？和 web 的逻辑一样吗？」
9. 「哦还有这个侧边栏会话列表，人家的每个项目的会话可以折叠的，你没有啊」

## 调研结论

### A. 右侧面板（DSH Web 的事实）

外壳 = `packages/client/ui-sidebar-right`，页签类型走
`ctx.sidebarRightTabs` 注册表（`tab-registry.ts:229`），外壳
`client/shell/SidebarRight.tsx`。

- **宽度**：默认帧宽 × `RIGHTBAR_DEFAULT_RATIO = 0.45`
  （`ui-layout/src/client/columns.ts:29` + `AppFrame.tsx:165`）；
  拖拽钳制下限 `RIGHTBAR_MIN = 300px`、上限帧宽 × 0.7
  （`columns.ts:25,27` + `AppFrame.tsx:241`）；中栏保底 400px。
- **全屏 = `100vw`**（`SidebarRight.tsx:310-311`），且
  **帧宽 < 768px 自动全屏**（`autoFullscreen`，`:360-361`）。
- **全屏/退出全屏按钮在 tab 条最右端**（`PanelChrome`，`:263-296`，
  镜像的折叠按钮 `:244-260`）→ `service.ts:618-625` 的 `toggleFullscreen`。
  **这就是用户要的"点全屏 / 点缩回"**，DSH 已有，照抄即可。
- **点文件 = 新开一个页签**（不是就地展开）：
  `ui-sidebar-files/src/client/FilesBody.tsx:187` → `openResource(fileAddress)`
  → 由注册表裁决落到 `text` fallback 查看器
  （`ui-sidebar-documentpreview/.../definition.ts:45-55`，`priority:'fallback'`）。
- 面板可**左右分两格**、分隔条 20%~80%（`minPaneFraction={0.2}`，`:323`）。

**"后台任务"与"子智能体"不在右侧**（全仓扫描 `sidebarRightTabs.register`
只有 files/terminal/browser/subagentchat/plan/changes-review/scheduleTask/text/guide）：

- **后台任务** = 会话头部动作 `job-list`（`ui-jobs/src/client/index.ts:35-52`，
  order 20），弹层 portal 到 body、宽 500px / `max-width: min(560px, 100vw-32px)`
  （`JobListAction.module.css:46-48`）：
  - 分组 = `进行中` + 已结束（可折叠 + "清空"，`JobListAction.tsx:544,549-564`）；
  - **点击一个任务 = 就地展开实时输出面板**（`onToggle` `:503-505`；
    面板 `:299-319`：丢包提示 `gapBefore`、error 提示、`TerminalBlock`
    `maxLines={Infinity}` 靠滚动不折叠 `:306-317`）；
  - **"停止"按钮**仅 `status==='running'` 的行（`:506-513`），
    **两段式确认** idle→armed→pending→failed（`KillState` `:186`；
    armed 3s 自动解除 `KILL_ARM_MS=3000` `:64`；failed 提示 4s `:67`；
    armed 时按钮展开成带"确认停止"文字的药丸 `:294`）；
  - 行字段 = 状态点 + label + kind + detail + 时长 + chevron（`:215-250`）；
    数据模型 `JobView`（`packages/jobs/jobs/src/view.ts:64-98`）。
- **子智能体** = 会话头部动作 `SubagentCatalogAction`
  （`ui-subagent/src/client/index.ts:82-93`，order 10）→ `CatalogDropdown`
  （`SubagentHeaderLineage.tsx:760-778`）：`role="tree"` 树形下拉，
  宽 `min(336, innerWidth-32)`（`:443`）；行 = 状态点 + label +
  副行(title·mode·activity) + 指标(tokens·duration)（`:335-355`）。
  - **点击某一项 = `openChild` → `openSession(address)`** ——
    子会话**进主对话区**（`ui-subagent/src/client/index.ts:61-63`）；
  - 行尾还有一个侧箭头按钮 → `openChildAside` →
    `sidebarRight.openResource(subagentChatAddress, {kind:'subagentchat'})`
    （`:64-69`）—— **这个才进右侧栏**（`sidebar-chat/index.tsx:155-169`
    以 `variant:'embedded'` 渲染）。

**手机的偏离（有意，需记）**：手机头部放不下两个 portal 下拉，
所以我们把"文件 / 任务 / 子智能体"都收进右侧抽屉。
但**形态照 DSH**：页签制、默认 45%、可全屏、任务可展开可停、子智能体可进入。

### B. 新会话逻辑（DSH Web 的事实）—— 我们与它**不一样**

`ui-sidebar/src/client/contract/slots.ts:119-121` 原话：

> Start a New Session: with a workspace, **reuse-or-create its blank session**
> and open it; without one, inherit the current Session Workspace, then the
> recent Workspace, or **clear into the New Session pure view** when none exist.

- blank 会话在列表里显示为**本地化的"新建会话"行**，且
  **`blank` 行的标题永不进搜索**（`ui-workspace/src/client/tree.ts:290-296`）；
- **blank 且非当前的会话被 `sessionVisible` 藏掉**（`tree.ts:245`）；
- blank 会话的工作区**在第一条消息前可切换**（`ui-conversation/.../EmptyHero.tsx:29-30`
  的 WorkspaceChip 注释：picking another one moves the New Session flow to
  that workspace's blank session）。

**我们的差异**：`main.dart:625` 的 `_newSession()` 直接走
`AppModel.createSession()` → `session.create` **即时建一个真会话**。
`app_model.dart:1440-1468` 的"没选中会话时落到 blank"只在那条路径上跑。

**后果**：每点一次「新建会话」就在电脑侧多一个会话（用户反悔不發消息也留着）。
DSH 是 **reuse-or-create**：先复用现有的 blank，没有才建。

**要改的**：`_newSession()` 先走"找 blank 就打开"（`AppModel` 已有那个查询，
`app_model.dart:1466` 的 `_sessions.where((s) => s.blank && !s.subagent)`），
找不到才 `createSession`。

### C. 用量入口位置

用户：「用量应该在设置前面吧？」—— 抽屉底栏顺序改成
`文件 / 归档 / 用量 / 设置`。

## 待办（分批评交）

> **2026-10-20 进度**：1/2/3/5/6/7/9 已落地（各有独立笔记，见
> `implemented/2026-10-19-bubble-token-and-blank-reuse.md`、
> `-collapsible-project-groups.md`、`-side-pane-width-fullscreen-and-enter.md`、
> `-usage-to-drawer-and-wider-edge-drag.md`）。**4 被否掉**（不做页签制，
> 理由见 side-pane 那篇）。剩下 8 / 10 / 11。

| 项 | 内容 | 状态 |
|---|---|---|
| 1 | 抽屉底栏顺序（用量提前） | ✅ 已落地 |
| 2 | 无会话时隐藏「对话/轨迹」tab | ✅ 已落地 |
| 3 | `_newSession()` 改 reuse-or-create blank | ✅ 已落地 |
| 4 | 右侧抽屉改页签制 | ❌ 否掉（手机 300dp 放不下一排页签 chip） |
| 5 | 任务：点击展开输出 + 两段式停止 + **3s 自动解除** | ✅（前两条早有，后一条本次补） |
| 6 | 子智能体：点击进入子会话 | ✅ 已落地（连接器换别名 + 面包屑返回） |
| 7 | 侧边栏按项目折叠 | ✅ 已落地 |
| 8 | 消息底部操作栏（复制 / 用量 pill / 时钟） | **待做**（调研已完成，见下） |
| 9 | 用户消息视觉区分（气泡） | ✅ 已落地（补 `bubble` token） |
| 10 | 上传弹框（拍照 / 照片 / 文件） | **待做**（调研已完成，见下） |
| 11 | 会话页与输入栏背景"不和谐" | **待用户说清是哪一处** |

## 第 8 条：消息底部操作栏（调研已完成，待实现）

DSH 的形态（`packages/client/ui-chat/src/client/chat/`）：

- 它是**独立的 `turn-tail` 行**，不是助手消息的一部分：
  `turn/end` 时以 `seq + CHAT_SYNTHETIC_SEQ_OFFSETS.finalizedFollowup`（+0.1）
  物化（`conversation-nodes/turn-tail.ts:107-140`），**一个 turn 只有一条**，
  多 step 不重复出现。渲染入口 `TurnTailNodeView.tsx:57-80`。
- 按钮顺序：**复制**（复制后 1s 变对勾，`MessageIconActions.tsx:85-89,62-76`）
  → 点赞/点踩（插件槽 `conversation.chat.assistant-actions`，order 10）
  → 分支（`session/fork` 可用时）→ **用量 pill** → 时钟。
- **用量 pill** 文案 = `用量 {total}`，而 total 自带 ` tok` ⇒ 实际是
  **`用量 10.6M tok`**（`locale.ts:178,186` + `TurnUsagePanel.tsx:18-20`）。
  点开是详情弹窗：精确值（三位分组）+ 提供方/模型 + 缓存命中% +
  未缓存输入 / 缓存读取 / 缓存写入 / 输出（含"其中推理 X tok"，`:52-107`）。
  数字来自 `deriveTurnTokenUsage`（`packages/llm/token-meter/src/turn-usage.ts:178`），
  在 `conversation-nodes/turn-tail.ts:90-92` 由 turn/start→turn/end 事件折叠。
  三重门控：detailed 模式 + 窗口含 turn/start + 用量可证明。
- **用户消息只有时钟 + 复制**（`MessageItem.tsx:298-321`），没有分支
  （测试 `chat-view.client.spec.tsx:3350` 注释 "The user bubble offers no branch"）。
- **明确没有**：分享、重新生成、编辑。
- 显隐：混合策略（`MessageIconActions.module.css:42-61`）——
  只有「最新一轮且以回复结尾」与「最新一条 user 消息」常显，其余 hover/focus 才显；
  无悬停设备恒显。**手机无悬停 ⇒ 一律常显**。

## 第 10 条：上传弹框（调研已完成，待实现）

rikkahub 的形态：
- `＋` 按钮 → `ChatFilesPickerSheet`，是 **`ModalBottomSheet`**
  （`ui/pages/chat/ChatPage.kt:567`），内容 `ui/components/ai/FilesPicker.kt:121-145`。
- 选项（`FlowRow`）：**拍照**（`Camera01`）/ **照片**（`Image02`）/
  视频（`Video01`，仅 Google provider）/ 音频（`MusicNote03`，同上）/
  **上传文件**（`Files02`）/ 语音模式（仅 ASR 支持时）。
  每个是 `BigIconTextButton`（`:501-534`）：图标装在 `surfaceContainer` 圆角 8dp 的
  Surface 里（`padding h32 v16`），文案在下、`bodySmall`。
- 动作实现在 `ChatAttachmentPicker.kt`（相机 `TakePicture()`、
  图片/视频/音频 `GetMultipleContents()`、文件 `OpenMultipleDocuments()` + 白名单校验）。
- 我们当前 `＋` 只有"添加文件或调用指令"的占位（`_notWired`），**没有弹框**。

## 未决

- **第 11 条（背景不和谐）**：用户没说具体是哪一处。
  已由 `bubble` token 部分回答（气泡曾是隐形的那一块），
  但"输入栏背景"那一处仍未确认 —— **实现前先问清**，不猜。
