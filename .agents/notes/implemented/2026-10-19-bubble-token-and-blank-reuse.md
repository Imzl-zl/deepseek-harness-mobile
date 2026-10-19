# Agent Note: 补 `bubble` token + 抽屉顺序 + 无会话不显 tab + 新建会话复用 blank

Status: implemented

## Problem

用户 2026-10-19 夜间四条反馈（承接
`.agents/notes/proposed/2026-10-19-session-page-feedback-research.md` 的调研）：

1. 「用量应该在设置前面吧？」
2. 「然后整个会话页面和输入框背景这一块设计不和谐吧」
3. 「然后用户信息这个我刚开始一直以为渲染问题呢，后来才发现这个是用户消息」
4. 「对了会话页面，没有会话的时候对话，轨迹不用显示吧，没会话你显示没用啊」
5. 「对了你这个新会话的逻辑是啥样的？和 web 的逻辑一样吗？」

## 根因

### 第 3 条：用户消息气泡在浅色主题下与背景同色

`dsh_colors.dart` 的 `DshLightColors`：`layer1/2/3` **三条全是纯白**
（`:153-155` 注释原话"浅色靠描边分层，不靠底色"）。而
`chat_turns.dart` 的用户消息气泡用的正是 `color: c.layer3` ——
**气泡与 `bgBase` 同为 `0xFFFFFFFF`，完全看不见**。

用户看到的是"一段没有边界的文字贴在白底上"，所以说"以为是渲染问题"。

DSH 有**专用**的一个 token：`--dsw-specific-bubble`
（`ui-theme/src/styles/design-platform.css:268` 亮 = `--dsw-static-deepseek-50`
= `#EDF3FE`；`:386` 暗 = `--dsw-static-neutral-bluish-850` = `#2C2C2E`）。
**我们没实现它**，于是拿 `layer3` 顶了。

### 第 5 条：新建会话与 DSH Web 不一样

`ui-sidebar/src/client/contract/slots.ts:119-121` 原话：

> Start a New Session: with a workspace, **reuse-or-create its blank session**
> and open it; without one, inherit the current Session Workspace, then the
> recent Workspace, or **clear into the New Session pure view** when none exist.

我们的 `_newSession()`（`main.dart`）直接 `session.create` **即时建一个真会话**。
`app_model.dart:1440-1468` 的"没选中会话时落到 blank"只在启动那条路径上跑。

**后果**：每点一次「新建会话」就在电脑侧多一个会话，用户反悔不發消息也留着。

## Decision

### 1. 补 `bubble` token（结构性修复，不是打补丁）

`DshColorTokens` 加 `bubble`：亮 `#EDF3FE`、暗 `#2C2C2E`，
用户消息气泡从 `c.layer3` 改成 `c.bubble`。

**不改成"给气泡加描边"**：DSH 的做法是给气泡**专用底色**，
描边是我们自己发明的第二套分层规则；而且 `--dsw-specific-bubble` 在
DSH 里就是"消息归属"的语义色（亮色偏蓝、与助手的无底色形成对比），
照抄它同时解决"看不见"与"分不清是谁说的"两件事。

### 2. 抽屉底栏顺序：`文件 / 归档 / 用量 / 设置`

用户原话「用量应该在设置前面吧？」。常用功能不该埋在不常改的偏好后面。

### 3. 没选中会话时不显示「对话 / 轨迹」分段控件

用户原话「没有会话的时候对话，轨迹不用显示吧，没会话你显示没用啊」。
轨迹页读的是**当前会话**的事件流；没有会话时它是空屏。

**选中了但还没有条目时仍显示两个** —— 那时轨迹页有话说
（会话刚建、事件正在来）。

### 4. `_newSession()` 改 reuse-or-create blank

`AppModel` 新增公开的 `findBlankSession()`（原先的查询是私有的
`_openBlankSessionIfUnselected` 里的内联 `where`）。`_newSession()`
① 先复用它打开现有 blank；② 找不到才 `createSession()`。

## Alternatives considered（否掉的）

- **给气泡加 border 而不是新 token**：那是第二套分层规则，且没解决
  "分不清是谁说的"。否。
- **把浅色 `layer3` 整体改成淡蓝**：`layer3` 还用在别处（chip 等），
  一动全动。否。
- **没会话时把轨迹 tab 置灰而不是隐藏**：置灰仍在说"这里有个东西"，
  而用户要的是"没有就没有"。否。

## Consequences

- 收益：用户消息在浅色主题下**看得见**了（真机验过，`#EDF3FE` 气泡）；
  抽屉底栏常用功能前置；没会话时少一个点不开的 tab；
  「新建会话」不再每次都在电脑侧多造一个会话。
- 代价：`DshColorTokens` 多一个字段（4 处构造点跟着改）。
- 测试：`widget_test.dart` 更新两条（没配对时不显 tab；选中会话时两个都在），
  新增"选中了会话：对话/轨迹两个 tab 都在"守**不会砍过头**。
  `flutter test 816` 全绿。
- **真机**：气泡（`#EDF3FE` 右对齐 + 右下角 6px 小圆角）、
  无会话时 tab 消失、有会话时 tab 回来，都验过。

## 未回应

用户还说「整个会话页面和输入框背景这一块设计不和谐」——
**已由 `bubble` token 部分回答**（气泡曾是隐形的那一块），
但"输入栏背景"那一处用户未说具体，**实现前先问清**。
