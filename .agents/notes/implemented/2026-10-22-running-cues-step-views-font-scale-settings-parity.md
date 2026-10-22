# Agent Note: 运行中动效、每步视图、字号刻度与设置对齐 —— 开工单（已完成）

Status: implemented（八件全部落地；每件一个提交 + 一篇决策笔记，见文末「落地索引」。
本轮的调研结论与判据未改，留作下一轮的前置事实）

## Problem

用户在真机上提了六件事，都指向同一个差距：**手机把 DSH 的"过程"压成了一条灰字，
而 Web 把它画成了会动的过程**。

1. **运行中没有动效** —— "没有这个动效还以为卡了呢"。
2. **每一步的展示不全** —— "web端的每一步查看子智能体、编辑、读取、运行命令，等等都有显示，APP 显示全不全？"
3. **运行命令时那段动效** —— "它这个运行命令，运行的时候好像也有一段动效"。
4. **字号不能统一控制** —— "能不能统一控制字体大小…最好是可以设置大中小，但是大了我怕有的样式崩了"。
5. **设置项没对齐** —— "设置中的设置是不是对齐了（有的不需要啊…APP 能支持的都对齐没）"。
6. **默认模式设置缺失** —— "这个默认的模式设置有没有，手机端最好也可以设置"。
7. **抽屉拖拽不好用** —— "web 人家拖拽移动的时候会有一个线标记到哪个位置了，上下都可以移动，
   你这个移动我往上不动，就是有时候都不动"；并指出"web 的会话也可以移动（工作区内移动）"。
8. **输入法自己弹出来** —— "输入框老是自动调出输入法…我都没点击输入框…每次回来都要关"。
9. **新建会话落在哪个工作区** —— 问"新建会话是哪个工作区的会话"（这条**已对齐**，只有一处数据面偏离）。

## 调研结论

### 1. 运行中动效：DSH 有三层，APP 一层都没有

| 层 | DSH 实现 | 参数 |
|---|---|---|
| **文字扫光** | `packages/client/ui-primitives/src/TextShimmer.tsx:37-57` + `TextShimmer.module.css:34-77`：把行头文字复制一份 `aria-hidden` 覆盖层，105° 线性遮罩 + `translateX(-100%→100%)` | 1.5s、延迟 0.3s、`steps(48, end)`、无限；`prefers-reduced-motion` 时整层 `display:none`（`:79-87`） |
| **转圈状态点** | `ui-primitives/src/StateDot.module.css:37-83`：14px、2px 描边、25% 透明整环 + 弧的 `stroke-dasharray 12→24→12` 呼吸 + 整体匀速旋转 | 1.5s linear |
| **流末尾运行条** | `ui-chat/src/client/chat/RunningStatus.tsx:20-41`，挂在流末尾（`ChatFlow.tsx:60`）：鲸鱼尾 APNG（`RunningWhaleTail.tsx:10-19`，CSS `mask` + `background: currentColor`，`ChatView.module.css:194-219`）+ 抖动文字「深度求索中，用时 12 秒 ···」+ **每秒 tick 的活时钟**（`message-chrome.ts:13` = 1000ms） | 只在会话运行中挂载 |

扫光**套在所有运行中的行上**，不是某一类：工具行（`ui-tool/src/client/tool/components/ToolRow.tsx:181-182,382` 传给 `DisclosureRow` 的 `running`）、命令卡（`bash-sample.tsx:111`）、思考行（`ReasoningRow.tsx`）、轮组头（`ChatGroupSeat.tsx:124`）、技能行、提问行 —— 都走 `ui-primitives/src/DisclosureRow.tsx:114` 那一个 `TextShimmer active={running}`。

命令行的动效有两处：行头扫光 + 展开后命令行头的转圈点（`TerminalBlock.tsx:151,213` 的 `runState` → `StateDot`）。

**APP 现状**：

- 聊天流里**一处动效都没有**。运行中的工具卡只是把图标换成静态 `loading` 字形（`app/lib/ui/chat_turns.dart:341-345`）；`_DisclosureHeader`（`:1328-1420`）**连 `running` 参数都没有**。
- 流末尾没有运行条。只有 `liveText != null` 时的 `_LiveTurn`，空文本时是一行**静态**「正在生成…」（`app/lib/ui/chat_page.dart:2983-2987`）。两个工具之间（等结果时）屏幕上什么都没有 —— 这正是"以为卡了"。
- 全 App 的动画只有这几处，且**没有一处落在聊天流的行上**：顶栏连接点（`app/lib/ui/dsh_state_dot.dart:86-151`，1.5s 转 `loading` 字形）、子智能体树的行内点（`subagent_tree.dart:359`）、几处 `CircularProgressIndicator`（`main.dart:420,424` 启动、`connection_summary_block.dart:162` 重连、`dsh_composer.dart:757`、`takeover.dart:621`）、发送键 `AnimatedSwitcher`（`dsh_composer.dart:744`）、chip 入场 `TweenAnimationBuilder`（`:294`）、跳转钮 `AnimatedOpacity`（`chat_jumper.dart:157`）。**转圈点只在顶栏与子智能体树，工具行没用**（`DshStateDot` 的调用点只有 `dsh_app_bar.dart:147,218` 与 `subagent_tree.dart:359`）。

### 2. 每步视图：DSH 按 tool key 注册 9 个专用视图，APP 只有 1 个通用卡

DSH 的注册表（`ui-tool/src/client/tool/toolviews/*.tsx` 的 `tool.call.toolview` key）：

| key | 视图 | 内容 |
|---|---|---|
| `bash` | `TerminalBlock` | 每行一条 prompt + 状态点 + exit code pill + 流式输出 |
| `read` | `ReadBlock` | 带行号的文件片段，可点开到行（`read-row.tsx:14-20`） |
| `edit` / `write` | `DiffBlock` | 内联 diff + `+N −M` |
| `grep` / `glob` | `SearchBlock` | 匹配列表 + 截断恢复定位 |
| `web_search` / `web_fetch` | `WebBlock` | URL + 摘要 |
| `todo_write` | todo diff | |
| `ask_user_question` | `AskQuestionCard` | |
| `subagent` + 30 余个（goal / schedule / job / terminal / lsp / team / session_event…） | `ToolDetails` | 只读字段表（`details-row.tsx`） |
| 未注册的 | 通用 IN/OUT 卡（`ToolRow.tsx:326-356`） | |

**APP 现状**：只有一个 `ToolCard`（名字 + 一行参数 + **纯文本**明细 + diff 增量，`chat_turns.dart:297-548`）与 `CommandCard`（斜杠命令，`:550-649`）。具体缺：

- 命令行：没有"每行一条 prompt + exit code + 流式输出"；
- `read`：没有带行号片段，不能点开到行；
- `edit`/`write`：行内没有 diff（`DshDiff` 只用在右侧文件面板，`chat_page.dart:3304-3314` 的注释说明那里原来还是假数据）；
- `grep`/`glob`：没有匹配列表块；
- `web_*`：没有 URL + 摘要块；
- `todo_write`：没有 todo diff；
- **图片结果完全不渲染**（`attachmentCount` 只数不画，`chat_item.dart:154-156`）；
- `subagent` 等：纯文本而不是字段表。

### 3. 字号：DSH 的规范是 `base + delta`，不是整体缩放

这是回答"符不符合技术栈规范"的关键 —— DSH 已经把这套定死了：

1. **一个设置**：`fontSize` 整数 **10–22，默认 14**（`ui-theme/src/theme-settings.ts:24-30`），写到 `body` 的 `--dsh-content-font-size`（`boot-theme.ts:30`）。
2. **派生四个变量**（`ui-theme/src/styles/gradient-shadow-text.css:56-63`）：
   - `--dsh-content-font-delta: size - 14px`
   - `--dsh-content-font-size-secondary: min(size-1, max(13px, size-2))` ⇒ 10→9 / 14→13 / 15→13 / 22→20
   - `--dsh-content-font-delta-secondary: secondary - 13px`
   - `--dsh-code-font-delta: codeSize - 11px`（代码是**另一个**设置，10–16 默认 11，`:59`）
3. **凡"贴着内容"的尺寸都写 `calc(基准 + delta)`**：正文行高（`AssistantMarkdown.module.css:13` 的 `calc(24px + delta)`）、标题阶梯（h1 21/30、h2 19/28、h3 18/26、h4 = 正文，`:65-91`）、图标与头像（`ChatView.module.css:187-188`、`MessageItem.module.css:128-138`）、缩进（`ContextInjectionRow.module.css:53-55` 的 `calc(100% - 22px - delta)`）、按钮与触达区（`MessageIconActions.module.css:9,67-86`）。
4. **小字（caption）与 chrome 固定不跟 delta** —— `:51-55` 的注释明写 "Small typography keeps a fixed size"。
5. 改字号另有快捷键 ±1（`ui-theme/src/index.ts:499-526`）。

**APP 现状：没有刻度。** `app/lib/` 里 **213 处**硬编码 `fontSize:`、**17 个**不同值，其中 5 个是半点（10.5 / 11.5 / 12.5 / 13.5 / 14.5）—— DSH 是整数阶梯：

```
11×50  12×47  13×46  12.5×16  14×16  11.5×11  15×9  16×4
10×2  18×2  10.5  13.5×4  14.5  19  20  21  34  各 1
```

`DshTheme._textTheme`（`app/lib/theme/dsh_theme.dart:89-115`）确实给了 6 档（13/12/11/13/15/20），但**绝大多数控件不用它**，直接写字面量。而且正文基准是 **13**，DSH 是 **14**。

结论：**能做，且规范是现成的** —— 照 DSH 的 `base + delta`，不要用 `MediaQuery.textScaler`（它会把顶栏、图标、间距一起放大，一定崩布局，正是用户担心的那件事）。

### 4. 设置对齐：DSH `general` 组 12 行，APP 有 4 行

DSH `general` 组注册了 **12 行**（`settings.general.item`）：`permission` / `language` / `appearance` / `font-size` / `transcript-view`（同一行组件里还有"工作步骤收起时机"）/ `developer-tools` / `shortcuts` / `link-opening` / `composer-enter` / `performance-usage` / `session-log-upload` / `current-version`。另有**一个头部动作**（不是行）「打开配置文件」，只在 loopback 下注册。

| DSH 行 | APP | 卡在哪 |
|---|---|---|
| 外观 | ✅ 主题（`settings_page.dart:136`） | — |
| 工作步骤展示 | ✅（`:149`） | — |
| 性能与用量 | ✅（`:162`） | — |
| 繁忙时的发送行为 | ✅（`:175`） | — |
| **权限**（新会话默认） | ❌ | 要 `settings.update` 写 `permission.defaultPreset`（`ui-permission-presets/src/client/settings-store.ts:44-48`） |
| **语言** | ❌ | App 只有中文；纯本地偏好，无技术阻塞 |
| **字号大小** | ❌ | 要先有刻度（§3） |
| **工作步骤收起时机** | ❌ | 纯本地偏好；两档语义（`回答结束后` / `下次有新消息时`，`ui-chat/src/client/locale.ts:107-108`）要在列表模型里落地 |
| 显示代码工作视图 | ❌ | 纯本地开关，但它控制"轨迹 + 本轮 diff"的可见性（`ui-settings/src/developer-tools-settings.ts:5,14-16`，默认开）—— 手机没有"侧边栏代码视图"这个面 |
| 快捷键 | 不适用 | 无物理键盘（已有定案） |
| 网页链接默认打开方式 | ❌ | 手机对应物只有"系统浏览器"一个值（内嵌浏览器已列 C 类不做）⇒ **没有第二个选项，不做** |
| 上传 Session Log | ❌ | 要 `settings.update` + 独立隐私文案（`ui-settings-session-log/src/client/index.ts:27,29`） |
| 打开配置文件（头部动作，不是行） | ❌ | 要让电脑弹原生编辑器 ⇒ 需扩方法面；同类已列"管理页面不做" |
| 当前版本 | ⚠️ 只有 App 版本（`:217`） | 电脑侧 DSH 版本**根本没过线**：`repo.info` 只回 `protocol` / `caps` / `aliasVersion` / `methods`（`connector/src/handlers.ts` 末尾），没有版本字段。要补一个字段（连接器自己的 `package.json` 就锁着 `0.2.1-rc.2`，但**运行时真值**应取宿主版本，不能拿构建期常量冒充） |

`docs/settings-porting-notes.md` §1 的逐项表**漏了"工作步骤收起时机"与"服务版本变化"两行**，本轮要顺手补。

### 5. 默认模式：差的正是 `settings.update` 一个方法

DSH 的机制（已核）：

- 预设目录 `agentPresets.list` —— **APP 已接**（`app/lib/model/agent_preset.dart`，hero chip 能用）。
- 单次会话选预设 `session.create({agentPreset})`（`packages/api/session-controller/src/client/contract/sessions.ts:88-93`）—— **APP 已接**（`chat_page.dart:1860-1870`，连接器 `handlers.ts:480-510`）。
- **新任务默认** `settings.update('agent-preset-registry', { selectedDefault: id })`（`ui-agent-preset/src/client/settings-store.ts:17,30-37`）—— **APP 没有**。

所以 APP 现在能"这一次用哪个模式"，**不能"设成以后默认"**。

而连接器里 `SettingsPort`（`connector/src/dsh/settings.ts:51-70`）**已经写好、有单测**（脱敏读 `snapshot` + 只发新值的 `setField`，文件头写着三条安全规则），但 `createSettingsPort` **从没被调用**（全仓只有 `settings.ts` 自己提到它），`settings.describe` / `settings.update` 两个 handler 没挂（`connector/src/protocol/methods.ts:91-94` 列了，`handlers.ts` 里搜不到）。

⇒ 这是一笔**已经付了一半的账**：接上两个 handler 就能同时解锁「新任务默认模式」「新会话默认权限」「Session Log 开关」三行设置，而"密钥值不回传、改密钥只发新值"的规则已经在那个 port 里实现了。

### 6. 抽屉拖拽排序：插入线、上下方向、组内移动

**DSH Web 的做法（已核）**：用**原生 HTML5 drag**（`draggable` / `onDragStart` / `onDragOver` / `onDrop` / `onDragEnd`），
落点按指针在行的上半/下半决定 `before` / `after`（`ui-workspace/src/client/rows/Rows.tsx:200-203` 的 `rowHalf`）。

插入标记不是"整行变底色"，而是一条**画在被落行上/下 8px 处的 12px 高渐变带**
（`WorkspaceBrowser.module.css:451-493` 的 `.workspaceDropBefore::before` / `.workspaceDropAfter::after`）：

- `height: 12px`，`top: -8px`（before）或 `bottom: -8px`（after）；
- 三层渐变叠出来：左端两个 5×7px 的 55°/125° 小斜角 + 从 `x=4px` 到右边缘的 **2px 横线**；
- 颜色 `--dsw-alias-state-business-primary`；
- 列表最顶上另有一条 `listTopDropIndicator`（`top: -8px`，且第一条的 `::before` 被隐藏）。

三个关键交互细节（我们的实现都没有）：

1. **扫到就显示标记**：`onDragOver` 里 `drag.hover(rowHalf(e))` 持续更新 —— 标记跟着指针走，不是松手才知道。
2. **松手提交"最后扫过的那一格"**：`onDragEnd` 里 `if (drag?.over != null) commitSessionDrag(drag, drag.over)`
   （`WorkspaceBrowser.tsx:618`），**即使松手时指针已经不在任何行上**。
   配 `useNativeDragAcceptance`（`:124-135`）在 document 层 `preventDefault` 兜住 drop。
3. **空白行（还没发过消息的 blank）只能当 `after`**：`normalizeHalf`（`:597`）`node.blank ? 'after' : half`，
   且 blank 行本身不能起拖（`Rows.tsx:574` 的 `!row.blank`）。

**会话在工作区内移动**：`sessionDragOrder`（`:218-239`）算新顺序，`setSessionOrder(accountKey, nextOrder)`
落库 —— 落到**浏览器本地视图状态**（`stores.ts:19-24` 的 `orderBy: 'manual' | 'updated'` +
`sessionOrderByAccount`，persist key `dsh.workspace.view.v5`；`setSessionOrder` 里 `d.orderBy = 'manual'`）。
**注意**：宿主侧其实有 `workspace.insertSessionBefore`（`packages/api/workspace-controller`），
但 DSH 的客户端**一次都没调**（全仓只有测试提到它）—— Web 的会话顺序是**每个浏览器自己的**。
而项目（工作区）顺序相反：`commitWorkspaceDrag` 走 `insertWorkspaceBefore` → **落电脑侧真值**（`:451`）。

**APP 现状（已核）**：

- 长按起拖 + `DragTarget` 落在**整行**上（`app/lib/ui/session_drawer.dart:829-906`），
  落点按 `details.offset.dy > rect.center.dy` 判上/下（`:865`）；
- **反馈只有"整行变底色"**（`:888-890` 的 `candidates.isNotEmpty ? layer2 : transparent`），**没有插入线**；
- **"不会改变顺序"的落点直接拒绝**（`dropAnchorInDisplayOrder` 返回 `null` → `onWillAcceptWithDetails` 为 false，
  `app/lib/model/workspace.dart:143-155` + `session_drawer.dart:875`）——
  于是**拖到自己身上、或没跨过邻行中线时，屏幕上一点反馈都没有**；
- **松手必须正好在某一行上**：只在 `onAcceptWithDetails` 里提交（`:877-881`），
  松在自己那行、组头、或行间空白 ⇒ 什么都不发生；
- 列表是普通 `ListView`（`session_drawer.dart:342`），**拖动到边缘不会自动滚**；
- 会话顺序走**电脑侧** `workspace.insertSessionBefore`（`app_model.dart:1980`），
  与 Web 的"浏览器本地 manual order"是**两条不同的路**（见上）。

⇒ "往上不动 / 有时候都不动"的**机械解释**：上行时指针要先跨过上一行的中线才被接受，
而"没跨过中线"和"拖到自己身上"都是**静默拒绝**；没有插入线就看不出"还差一点"，
于是读成"往上没用"。**这条是推断，不是已证实的根因** —— 下一轮第一件事是加一行探针
（`onWillAcceptWithDetails` 被拒时打一行日志 + 记 `details.offset`），
在真机上拖一次上行，看是"根本没进 `onAccept`"还是"进了但 `beforeSid` 算成原地"。

### 7. 输入法自己弹出来

**机制（已核，是框架行为 + 我们一处都没兜）**：

1. `Scaffold` 的抽屉由 `DrawerController` 管；抽屉打开时
   `packages/flutter/lib/src/material/drawer.dart:538` 执行 `FocusScope.of(context).setFirstFocus(_focusScopeNode)`
   —— **焦点被搬进抽屉**。
2. 抽屉关掉 / 弹层 pop 之后，框架把焦点还给页面里上一次的焦点节点。
3. `EditableText._handleFocusChanged`（`packages/flutter/lib/src/widgets/editable_text.dart:4752-4753`）
   第一句就是 `_openOrCloseInputConnectionIfNeeded()` —— **焦点一回来，输入法就重新打开**。

而 `app/lib/` 里**一次 `unfocus` 都没有**（全仓 grep 零命中），只有两处 `autofocus: true`
（`queue_dock.dart:350` 的编辑排队消息弹窗、`settings_page.dart:899`），都不在会话页。
会话页那个唯一的输入框是 `dsh_composer.dart:315` 的 `TextField`（没有 `autofocus`、没有显式 `FocusNode`）。

⇒ 只要用户**曾经**点过输入框（发过消息就够了），它就成了"上一次的焦点"，
之后每次开合抽屉 / 关弹层 / 从设置页返回，焦点都会被还给输入框 ⇒ 输入法弹出来。
**这是可复现的因果链，不是玄学**；下一轮要做的是在真机上验证一次（打开会话 → 发一条 → 开抽屉 → 点空白关闭 → 看输入法），
并在**路由/抽屉开合时统一 `unfocus`**。

### 8. 新建会话落在哪个工作区（这一条其实已经对齐）

**DSH**：`startSession`（`ui-workspace/src/client/navigation.ts:320-334`）
`显式给的 ?? 当前会话所在工作区 ?? recentWorkspace(...)`；
`recentWorkspace`（`:553-572`）取"每个工作区里会话的最大 `updatedAt`"，**空工作区用 `Date.parse(workspace.createdAt)`**；
两者都拿不到时（全库一个工作区一个会话都没有）才 `initializeDefaultWorkspace`，失败就提示
「无法创建默认工作区，请通过"选择工作区"选择文件夹」。

**APP**：`app/lib/model/workspace.dart:131-155` 的 `newSessionWorkspaceId` **照抄了同一条链**，
并且 `main.dart:721-760` 的 `_newSession` 也是**先复用该工作区现有的 blank、没有才建**
（引的是 DSH `ui-sidebar` slot 契约原文），与 `reuseOrCreateBlank` 一致。

**两处已知偏离（都不是 bug，是数据面缺字段）**：

1. **空工作区永远赢不了**：我们的 `workspace.list` 行只转 4 个字段、没有 `createdAt`
   （`connector/src/dsh/workspaces.ts` 的 `WorkspaceRow`），所以"没有会话"记成 `-1`
   —— 已在 `.agents/notes/implemented/2026-10-22-new-session-lands-in-a-workspace.md` 记过。
2. DSH 在"一个工作区都没有"时**不建会话**（回到空白新会话视图）；我们会带着 `workspaceId: null` 建一个，
   于是它落在抽屉的「未分组」桶里（那一桶不支持重排，`session_drawer.dart:90` 的 `canReorder`）。

⇒ 这一条**不需要重做**，只需要把 `createdAt` 补上（`workspace.list` 多转一个字段），
空工作区就能像 Web 一样靠"建得晚"赢。

## 建议的施工顺序

1. **运行中动效**（用户最痛，直接说"以为卡了"）。三件：
   - `DshShimmer` 组件（1.5s / 延迟 0.3s / `steps(48)` 遮罩扫光；`MediaQuery.disableAnimations` 时关掉，对应 `prefers-reduced-motion`）；
   - 给 `_DisclosureHeader` / `ToolCard` / `CommandCard` / `_CollapsibleNote` / 轮组头加 `running`；
   - 流末尾 `_RunningBar`（活时钟 + 在动的图标）。
   - **要决定的一件事**：鲸鱼尾 APNG 要不要引入。DSH 用它（`ChatView.module.css:209` 的 `running-whale@2x.png`），但那是 2x APNG 资源；Flutter 侧要么 `Image.asset` 逐帧（新资源 + 版权确认），要么用已有的 `loading` 转圈字形（零新资源，但少了品牌感）。
2. **每步视图**（最大一件）。建议**只做三个高频的**：`bash`（命令行 + exit code + 状态点）、`read`（行号片段）、`edit|write`（内联 diff），其余走现有通用卡并在文档写明**有意偏离**。图片结果单独一件（要 `session/attachment` 读面，已列 C 类未接）。
3. **字号刻度**：`DshType`（`body/secondary/caption/title/code` 各带 `+delta`）+ 设置行 + 213 处收敛。风险在"收敛调用点"不在"加设置"；5 个半点尺寸要一次逐屏对照，靠现有 widget 测 + 390dp 溢出断言兜。
4. **`settings.describe` / `settings.update`**：接 handlers → 解锁三行设置。
5. **（小件）电脑侧 DSH 版本**：`repo.info` 加一个字段，设置页「当前版本」显示两个版本（排错必需）。
6. **抽屉拖拽**（用户反馈"往上不动"）：先加探针确认是"没进 `onAccept`"还是"`beforeSid` 算成原地"，
   然后照 Web 补三样 —— **插入线**（12px 带 + 2px 横线，落在行的 ±8px）、
   **扫到就显示**（`onMove` 里更新标记，不是等松手）、**松手提交最后扫过的那一格**（含空白松手）。
   顺带决定：继续用 `LongPressDraggable`+`DragTarget`，还是换 `SliverReorderableList`
   （后者自带自动滚与位移动画，但指示器是"让位空隙"而不是 Web 那条线）。
7. **输入法自动弹出**：抽屉/弹层/路由开合时统一 `unfocus`（这条是框架行为，见 §7）；
   加一条 widget 测钉住"关掉抽屉后 `primaryFocus` 不是输入框"。
8. **（小件）`workspace.list` 补 `createdAt`**：让空工作区也能当"最近"，与 Web 的 `recentWorkspace` 对齐（§8）。

## 判据（新会话必须守住）

- 动效**不许用 `MediaQuery.textScaler` 或全局 `Transform.scale`** 做字号；字号只走 `base + delta`。
- 扫光只在**真的在跑**的行上（`running`），静止的行不许闪 —— 与"生产路径上的假数据"同一条纪律。
- 每个数字/文案仍要有来源：运行条的秒数读 `session.list` 的 `running` + 本轮的 `startTime`（`trajectory` 投影的 `startTime` 已有），**不在手机侧编**。
- 新增设置行只落**点了真的有作用**的；做不了的写进 `docs/settings-porting-notes.md` 的"不做"并给理由，不摆占位行。
- 改 `connector/src/**` 后必须跑 `tsc --noEmit` + `build` + `test`；改 `app/lib/**` 后跑 analyze + format + `verify-platform-boundary`。
- 引用 DSH 行为必须给 `packages/...:行号`；查不到写「未找到」。
- **拖拽的反馈必须是"扫到就有"**：任何"不会改变顺序"的落点也要**看得见**（Web 的标记一直在），
  不允许继续现在的"静默拒绝"。
- **输入法只能由用户点击输入框引起**：路由/抽屉/弹层开合后 `primaryFocus` 不许落在输入框上。
  这条要有 widget 测兜（关掉抽屉后断言焦点不在 `TextField` 的节点上）。

## Alternatives considered

1. **字号用 Flutter 的 `MediaQuery.textScaler` 全局放大**
   - 最强的理由：一行代码，所有文字一起变大，零改动。
   - 为何被否：它同时放大**图标、间距、行高、触达区**，而 App 里 213 处尺寸是各自写死的字面量、没有跟着缩放 —— 结果是文字撑出容器。这正是用户担心的"大了有的样式崩了"。DSH 的 `base + delta` 只动"贴着内容"的那一维，chrome 与 caption 固定，才是可预测的。
2. **照搬 Web 的 `TextShimmer` 做逐字符渐变**
   - 最强的理由：与 Web 逐像素同源。
   - 为何被否：Web 的做法是**两层文字叠在一起 + 遮罩移动**（`TextShimmer.tsx:42-56`），因为 CSS 能白拿。Flutter 里等价物是 `ShaderMask` + `AnimationController` 每帧重建 —— 每行一个 ticker，一屏几十行就是几十个 ticker。可行但要走"一个共享 controller + `RepaintBoundary`"，不能每行各建一个（`dsh_state_dot.dart:83-95` 已经踩过"无条件建 ticker 污染测试"的坑）。
3. **整块重做聊天流成 DSH 的"轮组 + 组内步骤"结构**
   - 最强的理由：这才是 Web 的真结构，顺带解决动效与每步视图。
   - 为何被否：那是 `memory.md` 待办第 1 条（轮组），是**独立一件**且更大。本轮四件都能在现有平铺结构里落地；两件一起做会让 diff 无法审。
4. **设置页照 DSH 13 行全摆**
   - 最强的理由："对齐"最省心的判据就是行数一样。
   - 为何被否：其中 3 行在手机上**没有第二个取值**（快捷键无键盘、链接打开方式只有系统浏览器、代码工作视图没有那个面），摆上去就是点不动的假入口 —— 与本项目"不摆假入口"的既有纪律冲突。对齐的是**能力**，不是行数。
5. **抽屉重排改用 `ReorderableListView` 一把换掉**
   - 最强的理由：框架自带自动滚动、让位动画、跨行命中，代码能少一半；`settings_page.dart:434` 已经在用它排端点。
   - 为何暂时不选：它的指示器是"把别的行让开形成空隙"，而 DSH 是**一条线**；抽屉里还有**组头 + 会话**两层可拖（`_WorkspaceDrag` / `_SessionDrag`），`ReorderableListView` 只认一条扁平列表，套两层会先把"组头也能拖"这件事做丢。先按第一个方案（保留现结构 + 补三样反馈），把 `SliverReorderableList` 列为后续可选项。
6. **输入法问题靠 `keyboardDismissBehavior` / `onTapOutside` 解决**
   - 最强的理由：一行属性，最省事。
   - 为何被否：那两个解决的是"点空白收起键盘"，而这里是**焦点被主动还给输入框**（`DrawerController` 的 `setFirstFocus` + `EditableText` 的 `_handleFocusChanged`）。属性改不动焦点所有权，症状会原样留着。

## Consequences

- 收益：运行中的每一步都"看得见在动"，用户不用猜是不是卡了；高频工具（命令 / 读 / 改）有与 Web 同构的视图；字号有了唯一的控制点，不再靠 213 处字面量各自漂移；三行设置靠一个已写好一半的方法面解锁。
- 代价：
  - 扫光与活时钟是**常驻动画**，会一直占一帧的重绘预算；必须限制在"运行中的行"并给 `disableAnimations` 留出口，否则长会话滚动会掉帧。
  - 字号刻度要动 213 处调用点 —— 这是一次**大范围但机械**的改动，必须一次做完（半截会让两套刻度并存，比现在更糟）。
  - `settings.update` 一旦挂上，手机就获得了写电脑设置的通道；port 里的脱敏与 mutate 规则必须原样保留，且 `role('secret')` 字段永不过线（`connector/src/dsh/settings.ts:9-21` 的三条）。
  - 每步视图只做三个意味着**已知的偏离**：`grep`/`web`/`todo`/图片在手机上仍是通用卡。要写进文档，不能让下一轮误以为"已经对齐"。
  - 拖拽补插入线之后会多一层"标记状态"，扫到每一行都要 `setState` —— 抽屉只有几十行，代价可接受；但**不能用它驱动整棵树重建**，标记要走单独的 `ValueNotifier`/局部状态。
  - `unfocus` 是双刃：如果做过头（比如用户点输入框的瞬间也被 unfocus），会吃掉点击。只能绑在**路由/抽屉开合**这些明确的转换点上。
  - 会话顺序**两条路**（Web 本地 manual / 手机写宿主）如果要统一，得改一边的数据归属。本轮**不动**，只在文档写清"两边可能不一致"。

## 落地索引（2026-10-22，八件八提交）

| 件 | 提交 | 决策笔记 | 现状事实 |
|---|---|---|---|
| G 输入法只由用户点击引起 | `4f52a65` | `2026-10-22-input-focus-only-from-user-tap.md` | `docs/subsystems/input-focus.md` |
| F 抽屉拖拽（插入线 / 扫到即显示 / 松手提交最后格） | `6f30f11` | `2026-10-22-drawer-drag-insertion-line.md` | `docs/subsystems/session-ordering.md` |
| A 运行中动效（共享 ticker 扫光 + 活时钟运行条） | `00f69a1` | `2026-10-22-running-cues-shimmer-and-live-clock.md` | `docs/subsystems/running-cues.md` |
| C 字号刻度（base + delta，10–22 默认 14） | `38f0661` | `2026-10-22-type-scale-base-plus-delta.md` | `docs/subsystems/type-scale.md` |
| B 每步视图（bash / read / edit|write） | `376a575` | `2026-10-22-tool-views-three-high-frequency.md` | `docs/subsystems/tool-views.md` |
| D 设置三行 + 默认模式 | `d11e935` | `2026-10-22-settings-handlers-and-default-mode.md` | `docs/subsystems/settings-and-versions.md` |
| E 电脑侧 DSH 版本 | `f5592af` | 同上 §4 | 同上 §4 |
| H `workspace.createdAt` | `fab945d` | `2026-10-22-workspace-created-at.md` | `docs/subsystems/blank-session-hero.md` §4.1 |

**与开工单的三处出入**（都已写进对应笔记的 Consequences，别当成漏做）：
1. **A 的"在跑吗"判据**：开工单写的是读 `session.list` 的 `running`，真机实测它是旧值
   （一轮跑 40 秒、运行条整轮不出现）—— 改成事件流判据（`turn/start` / `turn/end`）。
2. **B 只做三个高频**：`grep` / `web_*` / `todo_write` / 图片结果仍走通用卡，是有意偏离。
3. **C 只让"贴着内容"的文字跟刻度**：chrome 与 caption 固定（DSH 同一条），
   216 处字面量里收敛的是内容那一半，其余按"固定"记档。
