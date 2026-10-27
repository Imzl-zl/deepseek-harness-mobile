# UI 状态与动作约束：全量归属审计（第 1 段，只读）

- 日期：2026-10-27
- 状态：proposed（第 1 段产物；**不含方案**，方案进第 2 段）
- 口径来源：状态分类（host / browser-local-persisted / device-local）与三条不变量见
  `2026-10-27-state-semantics-inventory.md`；分层与门禁见 `docs/subsystems/app-platform-boundaries.md`。
- 桌面证据一律给联网源码 `D:\sudy\github\deepseek-harness\packages\...:行号`；手机给本仓 `app/lib/...:行号`。
  查不到写「未找到」。

## 0. 方法与口径

1. "跨页面 / 跨重启 / 跨连接该活下来"的判据**不靠感觉，靠桌面**：桌面**持久化**的状态
   = `browser-local-persisted`；桌面**只存宿主**的 = `host`；桌面**只放组件内**的 = 允许
   手机同样临时（但要写进本表，免得下次被当成漏项补成第二份真值）。
2. 桌面持久化面只有一处机制：`defineStore({ …, persist })` / `createSnapshotStore(v, {persist})`。
   全仓 `persist:` 的**穷举结果**（27 处匹配去重后 10 个键）：
   `dsh.workspace.view.v5`（`client/ui-workspace/src/client/stores.ts:91`）、
   `dsh.sessions.current`（`client/ui-workspace/src/client/navigation.ts:173-175`）、
   `dsh.conversation`（`client/ui-conversation/src/client/stores.ts:8,25`）、
   `dsh.user-questions.drafts.v1`、`dsh.trajectory.jsonStringWrapping`、`dsh.trajectory.duration`、
   `dsh.voice-input.microphone`、`dsh.sidebar-browser.v1`、`dsh.plugin-manager.install-registry`、
   `dsh.open-in-app.choice`、`dsh.creation-recommendations.info-dismissed`。
   **桌面布局（左栏宽/开合、右栏面板选中、全屏态）明确不持久化**：
   "Transient layout preferences"（`client/ui-layout/src/client/stores.ts:12-15`），
   且有一条用例就叫 `creates independent instances without browser persistence`
   （`client/ui-layout/tests/layout-store.client.spec.ts:28`）。
3. 手机现有**两个**持久化缝（设计时要分别对待，不能合成一个）：
   - `data/store.dart` 的 `meta` 表 → `PreferenceStore`（`store.dart:124-148`），键：
     `send_mode` / `last_session` / `transcript_view` / `performance_usage` /
     `collapse_timing` / `ui_scale_index` / `theme.mode`（最后一个带点号，其余下划线 —— 已经不一致）。
   - 安全存储 `platform/pairing_store.dart:162-175`，键统一 `dsh.*`：凭据 10 项 + `dsh.endpoints` + `dsh.endpoint_meta`。
4. **恢复时机**只有两种，本表逐条标注：
   - **首帧前**：桌面 `localStorage` 在 store 创建时同步取（`client/store/tests/store.client.spec.ts:133-137`
     的 `revived` 语义；`dsh.conversation` 还会在 React 发布前读，见 T1-1）；
   - **首帧后（异步）**：手机 `AppModel.start()`（`app/lib/data/app_model.dart:1390-1417`）在
     内容首帧**之后**才跑（`main.dart:277-282` 先 `setState(_booting=false)`，再 `await app.start()`），
     所以"恢复不得阻塞首帧"这条**已经满足**，代价是**首帧用的是默认值**（见 T5 的结论）。

---

## A. 状态归属表

### T1 会话级 UI 状态（桌面按会话持久化）

| # | 状态 | 桌面主人 | 桌面键/实现 | 桌面恢复时机 | 桌面证据 | 手机现状 | 判定 |
|---|---|---|---|---|---|---|---|
| 1 | 输入框草稿 | browser-local-persisted，**按会话** | `dsh.conversation.<sid>` 的 `draft`，值是 **`DraftSnapshot` 对象**（不是字符串）：`{text, references:[{source,ref,offset,length,label,appearance?,clipboardText,invalid?}], command?:{token}, quotes?:[{offset,length,text}]}` | **首帧前**（同步 `localStorage`；另有"React 发布前读"的入口，因为输入机建得比渲染早） | 形状 `ui-conversation/src/client/contract/draft-editor.ts:22-56`；校验/迁移 `draft.ts:6-52,74-88`；键 `stores.ts:8,23-25`；发布前读 `stores.ts:43-56`；写入点在输入机发布时且**内容变了才写** `input/facade.ts:950-957`、`persistCurrentDraft` `:302-305` | `_input` 是 `ChatPageState` 的**一个** `TextEditingController`（纯文本），跨会话共用、随 widget dispose 丢（`ui/chat_page.dart:211,383`） | **缺口**：跨重启丢 + 跨会话串味。**存形状要照桌面的对象**（哪怕今天只有 `text`），否则加 `@` chip 时要造第二种格式（见 §F-4） |
| 2 | 视图页签（对话 / 轨迹） | browser-local-persisted，**按会话** | `dsh.conversation.<sid>` 的 `view`＝**已注册 `conversation.view` 的 id**（`'chat'` / `'trajectory'`），`null` = 回 Chat | 首帧前（`readConversationViewPreference`），并在 View 注册表变化时重算 | 键 `stores.ts:63-74`；id 常量与回落 `view-selection.ts:4-21`（`resolveActiveView`：存的 id 未注册 ⇒ 回 `chat`，**不挑别的**）；页签列表来自 slot 注册 `apply.ts:208-220,242-262`；渲染 `skeleton/DefaultConversationViews.tsx:17-41` | `int _tab`（下标，不是 id）（`ui/chat_page.dart:215,888-889`） | **缺口**：重启/切会话都丢。**必须存 id 而不是下标**（桌面两档页签以外还可能有第三方注册的 View） |
| 2.1 | 轨迹页签是否出现 | **host 设置**：`ui-settings` 命名空间 `developerTools.enabled`（默认 **true**） | 关掉时 `trajectory` 这个 View 不进页签列表 | 读即用 | `ui-settings/src/developer-tools-settings.ts:13-16`（`z.boolean().default(true)`）、`ui-settings/src/client/developer-tools.ts:14-25`；过滤点 `ui-conversation/src/client/apply.ts:213` | 手机恒显示两档（`ui/chat_page.dart:885-890`，条件只有"有会话且非 blank"） | **口径差**：桌面默认 true ⇒ 现状观感一致；但该 ns 不在手机 allowlist（`connector/src/dsh/settings-face.ts:26-29`）。记为"读不到宿主开关"，不是缺口，不进本批 |
| 3 | 轮组折叠（过程收起/展开） | **不持久化** | 桌面用组件内 `useDisclosure` | — | `ui-chat/src/client/chat/ChatGroupSeat.tsx:137`、`ReasoningRow.tsx:58`、`chat/GenericCommandCard.tsx:30` | `_turnOpen`（`ui/chat_page.dart:1128,1135-1160`） | **一致**（临时态）；注意「收起时机」是**偏好**，见 T5-3，两者别混 |
| 4 | 工具卡 / 命令卡 / 任务行展开 | **不持久化** | 同上 | — | 同上 + `ui-chat/src/client/chat/CompactionItem.tsx:37` | `_openJobs`（`ui/chat_page.dart:263`）、`chat_turns.dart:358,619,884,1593` | **一致**（临时态） |
| 5 | 抽屉里搜索框内容 | **不持久化** | 未见持久化；搜索是即时过滤 | — | 未找到（`ui-workspace` 无 search 持久化） | `_search`（`ui/session_drawer.dart:189`） | **一致**（临时态） |
| 6 | `@` 候选 drill 路径 | **不持久化** | 桌面每次重开面板回到根 | — | 未找到持久化证据 | `_drilled` / `_rows`（`ui/dsh_composer.dart:1516-1520`） | **一致**（临时态） |

### T2 选择记忆（桌面全部**由宿主给**，浏览器不存第二份）

| # | 状态 | 桌面主人 | 桌面机制 | 恢复时机 | 桌面证据 | 手机现状 | 判定 |
|---|---|---|---|---|---|---|---|
| 1 | 当前会话的模型 | host（会话级选择 + 宿主默认） | 会话投影 `modelSelection.next`，**缺省回落 `catalog.default`** | 读即用 | `ui-model-selection/src/client/directory.ts:162,180`（`projected.next ?? catalog.value.default`） | `AppModel.currentModel` 只读会话行/投影，**没有 default 回落**（`data/app_model.dart:1256-1260`）⇒ 新会话恒显示「请选择模型」（`ui/chat_page.dart:1194-1209`） | **缺口**：手机漏了**宿主已经有的默认值**；不需要本地存 |
| 2 | 推理等级（思考程度） | host | 同一 `ModelSelection.reasoningEffort`；缺省回落 provider `defaultEffort` | 读即用 | `ui-model-selection/src/client/directory.ts:163-164`；`api/session-controller/src/catalog.ts:30-41,66-71`（`default` 带你 reasoningEffort） | `_reasoningLabel` 只读 `currentModel`（`ui/chat_page.dart:1223-1236`） | **缺口**：同 T2-1，随模型一起补 |
| 3 | 新建会话的默认模型（"以后新建的都跟着"） | host（`agent-default-model`） | `selectModel` 后 `saveSelection` 写回部署默认 | 读即用 | `api/session-controller/src/commands.ts:164-168`；`core/agent-default-model/src/index.ts:82-94` | `selectModel` 已调宿主（`data/app_model.dart:1274-1308`），**但目录 `default` 没被读** | **缺口只在读侧**；写侧已对 |
| 4 | 新会话落在哪个工作区 | host（**推导，不存**） | `workspaceId ?? 当前会话的工作区 ?? 最近更新的工作区` | 读即用 | `ui-workspace/src/client/navigation.ts:337-368`（`:351` 三档）、`:577-596`（`recentWorkspace` 按 `updatedAt`） | **已实现**：`defaultNewSessionWorkspaceId` + `createSession` 显式传（`data/app_model.dart:2956-2965,3304-3313`；`model/workspace.dart:141`） | **一致**（本项不是缺口，见 §C-2） |
| 5 | 权限档（访问模式） | host | 会话投影 + `permission.catalog` 目录 | 读即用 | 本仓已记录 `permission.catalog`/`permission.switch` 的 DSH 出处（`docs/subsystems/settings-and-versions.md`） | 走目录+投影（`ui/chat_page.dart:2258-2293`） | **一致** |
| 6 | Agent 预设 | host | 投影 `agentPreset` + `agentPresets.list` 的默认 | 读即用 | `ui-conversation/src/client/skeleton/ConversationContent.tsx:132`；`ui-workspace/src/client/navigation.ts:234-250`（复用 blank 时按预设挑） | `agentPresetValue ?? roster.defaultId`（`ui/chat_page.dart:2133`） | **一致** |
| 7 | 发送模式（排队 / 插话） | **host**：`ui-conversation` 设置命名空间的 `busyEnter` | `submission-settings.ts` 的 `CONVERSATION_SETTINGS_NAMESPACE` / `BUSY_ENTER_FIELD`，默认 `queue` | 读即用（设置文档） | `ui-conversation/src/submission-settings.ts:1,6-18,26-33`；浏览器侧 `input/submission-policy.ts:48,71-73`；消费 `skeleton/InputBar.tsx:345` | `device-local`，键 `send_mode`（`data/app_model.dart:1420-1436`）；连接器的设置 allowlist **不含**该 ns（`data/app_model.dart:1519-1523`） | **第二份真值**：同一件事桌面寸在宿主设置里。要么扩 allowlist 读宿主、要么在 `docs/` 写明"手机本地、不回写电脑"并回指决策笔记（见 §C-5） |
| 8 | 上次看的会话 | browser-local-persisted（桌面） | `dsh.sessions.current`（`MainSelection`） | 首帧后恢复导航 | `ui-workspace/src/client/navigation.ts:28-31,173-175`；恢复流程 `:460-495` | `device-local`，键 `last_session`（`data/app_model.dart:1423,2794-2801,3368`） | **同构替代**（已落地）；失效规则见 §D-3 |

### T3 列表与抽屉

| # | 状态 | 桌面主人 | 桌面键/实现 | 恢复时机 | 桌面证据 | 手机现状 | 判定 |
|---|---|---|---|---|---|---|---|
| 1 | 工作区分组的**展开态** | browser-local-persisted，**按工作区身份** | `dsh.workspace.view.v5` 的 `groupExpansion` | 首帧前 | `ui-workspace/src/client/stores.ts:25-26,50,91,99`；`rows/WorkspaceBrowser.tsx:279-282` | `Map<String,bool> _expanded`，**键是显示标题**，且明写"不落盘"（`ui/session_drawer.dart:191-200,363-367`） | **缺口**；且**键选错**（标题不是身份，改名即丢）。稳定身份**有**：`DrawerSection.workspaceId`（`session_drawer.dart:91-98`）—— 代码注释里"没有 id"的说法**不成立** |
| 2 | 会话排序模式 / 手排顺序 / 归档筛选 | browser-local-persisted | 同上（`orderBy` / `sessionOrderByAccount` / `archivedFilter`，`:21-31,110-127`） | 首帧前 | `ui-workspace/src/client/stores.ts:21-31,94-127` | 手机**没有**这三档：分组恒为工作区、排序用宿主 `workspace.insertSessionBefore`（`data/app_model.dart` 的 `moveSession`）、归档单独一页（`ui/archive_sheet.dart`） | **有意偏离**（桌面手排是浏览器本地覆盖 + 宿主插入两条并存，`ui-workspace/src/client/rows/Rows.tsx:643`、`WorkspaceBrowser.tsx:1085`）；手机只走宿主一条 —— 记入 §C-3，不进本批 |
| 3 | 左侧抽屉开合 / 宽度 | **不持久化** | layout store 是 transient | — | `ui-layout/src/client/stores.ts:12-15` + `tests/layout-store.client.spec.ts:28` | 原生 `Drawer`，无持久态 | **一致** |
| 4 | 右抽屉：面板（文件/任务/子代理）、差异/文件分段、全屏态 | **不持久化** | `activePanelId` 在 transient layout store；右栏展开态"belongs to its occupant" | — | `ui-layout/src/client/stores.ts:16-22,94-96`；`ui-layout/src/client/service.ts:36` | `_sidePanel` / `_fileTab` / `_sideFullscreen`（`ui/chat_page.dart:222-230,256`） | **一致**（临时态）；已在注释里写明不落盘的理由 |
| 5 | 文件页当前路径 | **不持久化** | 未找到持久化证据 | — | 未找到 | `_path`（`ui/files_page.dart:46`） | **一致**（临时态） |
| 6 | 子智能体树展开集合 | **不持久化** | `expanded: ReadonlySet<SessionId>` 由上层持有 | — | `ui-subagent/src/client/SubagentHeaderLineage.tsx:41,200-243` | `Set<String> _expanded`（`ui/subagent_tree.dart:103-104`） | **一致**（临时态） |
| 7 | 排队条折叠 | **不持久化** | 未找到（队列本体是宿主的：`session.updateQueue`） | — | `ui-conversation/.../InputBar.tsx:170`（`canSteerQueue` 是运行态）；队列数据在宿主 `inbox` 投影（本仓 `connector/src/dsh/sessions.ts:225-229`） | `_collapsed`（`ui/queue_dock.dart:56-59`） | **一致**（临时态）；队列内容本身 = host |
| 8 | 用量页项目段展开 | **不持久化** | 未找到 | — | 未找到 | `_open`（`ui/usage_page.dart:888`） | **一致**（临时态） |
| 9 | 接管卡最小化 | 桌面无接管卡这一层 | — | — | — | `_minimized`（`ui/takeover.dart:121`） | **手机自有**；临时态即可 |

### T4 连接瞬间的复合状态（全部 host，手机不缺数据，缺"一次画全"）

| # | 状态 | 主人 | 数据源 | 桌面呈现 | 桌面证据 | 手机现状 | 判定 |
|---|---|---|---|---|---|---|---|
| 1 | 会话在跑 | host | `session.list.running` + `api-session/status` 帧 | 会话页运行条 / 输入栏主键变 Stop | `InputBar.tsx:72,341-343` | 已有：`_running` + `RunningBar`（`ui/chat_page.dart:1001-1002`；`docs/subsystems/connect-landing.md` §3） | **一致** |
| 2 | 子智能体后台任务 | host（**但计数是客户端算的，不是宿主字段**） | 父行 `values.subagentCatalog`（summary 键默认携带）+ 子行 `running` | 见下方"桌面方案"一整段 | `subagent/subagent/src/catalog.ts:114-125`；summary 归一 `session/session-projection/src/index.ts:109-115,367`；**计数公式** `ui-workspace/src/client/tree.ts:381-386,402`；**渲染与优先级** `ui-workspace/src/client/rows/Rows.tsx:396-445`；同名两枚点 `Rows.tsx:352-362` | **只**在右抽屉子代理页 / 任务面板看得到；会话页不画；`readSessionRow` 只解 4 个投影键，`values.subagentCatalog` 没读（`wire/rpc/session.dart:296-298`）。`model/session_dot.dart:9-15` 断言"手机侧没有 `runningSubagentCount` 这个投影"——**前提错了**：桌面根本没有这个宿主字段，它是客户端算的 | **缺口（解析+渲染）**，不需要新方法/新字段：父行 `values.subagentCatalog` 已过线（`connector/src/dsh/sessions.ts:354-364`） |
| 3 | 待处理项（审批 / 计划审查 / 提问） | host | 会话日志事件投影（没有 `interaction.list`）；**宿主给的是 kind，不是计数** | 行首状态点**按 kind 换文案**：`approval`→`status.waitingApproval`、`plan-review`→`status.planReview`、`question`→`status.waitingAnswer`；`runningSubagentCount` 另画一枚点；优先级 pending > running > subagents > completed | `ui-workspace/src/client/tree.ts:35,369-379,396`；`rows/Rows.tsx:392-445` | 有：`TakeoverController` 按会话分桶（`ui/takeover.dart:97`）+ 一枚点（`model/session_dot.dart:39-47`）。但点只有**一态**（warning），且 `_pendingCountOf` 只数审批（`data/app_model.dart:3271-3277`） | **口径差**（不是缺口）：手机把三 kind 压成一态；计数只是我们自己的中间量。要与桌面一致就得**分文案**，但计划审查卡手机有意不接 ⇒ 本批维持一态并在 `docs/` 写明 |
| 4 | 计数（token / 轮次） | host | 投影 `tokenUsage` / `sessionStats` | 统计条 | `docs/subsystems/app-channel-client.md:225` | 已有（`ui/chat_page.dart:1013-1024`） | **一致** |
| 5 | 队列（已排队消息） | host | 宿主 inbox 投影 | 输入栏上方 dock | `InputBar.tsx:170-171`；本仓 `connector/src/dsh/sessions.ts:225-229` | `queueOf(sid)` + `QueueDock` | **一致** |

### T5 呈现偏好与本地凭据

| # | 状态 | 主人 | 键 | 恢复时机 | 手机现状 | 判定 |
|---|---|---|---|---|---|---|
| 1 | 界面字号档 | device-local | `ui_scale_index` | **首帧后**（`start()` 内） | `data/app_model.dart:1482-1503,2334-2337` | 已落地；**首帧会以 1.0 渲染再跳档**（见 §C-4） |
| 2 | 主题模式 | device-local | `theme.mode`（点号，与其他键不一致） | 首帧后（`_boot().then(_restoreTheme)`，`main.dart:194,201-215`） | `main.dart:231-241`；`model/theme_mode.dart:27` | 已落地；同样"闪一下默认"；键名风格待统一 |
| 3 | 工作步骤展示密度 / 收起时机 / 性能用量 | device-local | `transcript_view` / `collapse_timing` / `performance_usage` | 首帧后 | `data/app_model.dart:1440-1480,2320-2338` | 已落地 |
| 4 | 端点表 + 记住的端点 + 隐藏集 + 成功集 | device-local（身份相关） | 安全存储 `dsh.endpoints` / `dsh.endpoint_meta` | 首帧前（`_assemble` 时 `PairingStore.load`，`main.dart:255-282`） | `platform/pairing_store.dart:162-175,298-360` | 已落地；**与 `meta` 是两个缝**，不该合并（凭据不能进 sqflite 明文） |
| 5 | 配对凭据（种子 / 令牌） | device-local | 安全存储 `dsh.*` 10 项 | 首帧前 | 同上 | 已落地 |

---

## B. 动作前置约束表

桌面口径只有一处：`primaryDisabled = primaryStops ? stopAction === undefined
: empty || disabled || machineBusy || uploadsPending`
（`client/ui-conversation/src/client/skeleton/InputBar.tsx:343`），其中
`disabled = removed || inert || !live || blocked !== undefined || parentOffline`（`:154`）。

| # | 动作 | 桌面条件（逐条给行） | 手机现在 | 缺什么 | 该说的话 |
|---|---|---|---|---|---|
| 1 | 发消息（普通） | ① `empty`（`:89`，正文与附件都空）② `!live` = 没有当前会话的输入机（`:82,154`）③ `inert` = 没有会话，或 hero 上**工作区解析不出来**（`skeleton/ConversationContent.tsx:142,149-155`）④ `removed`（会话已删，`:74`）⑤ `machineBusy` = 裁定/提交中（`:161`）⑥ `uploadsPending`（`:94-96`）⑦ `parentOffline`（continuable 子会话父级离线，`:149`）⑧ `blocked`（owner 提的阻塞，`:146,160`） | `enabled: _hasData && sid != null`（`ui/chat_page.dart:992`）+ `_send` 里判空（`:528-541`） | **① 缺 ③⑤⑦**：无工作区/无会话不 inert；没有"裁定/提交中"；子会话父离线不判 | 桌面 `placeholder` 就是 `blocked.reason` / "选择工作区"（`ConversationContent.tsx:152,160`；文案 `placeholder.workspace`）。手机要改成"**键在、但点了先说缺什么**"或"灰 + 占位文案"，措辞照桌面 |
| 2 | 发消息（命令 / 空白会话） | 命令走 `adjudicating`（`:161`），命令没匹配也按普通消息（本仓 `ui/chat_page.dart:573-577` 已同） | 已同 | — | — |
| 3 | 模型未选 | **桌面不置灰发送**：会话没有记录选择时跟随宿主默认（`api/session-controller/src/agent.ts:464-472` 的 `agentOptions()` 三个 getter），目录也回落默认（`directory.ts:162,180`）；`requireModel` 只在 `selectModel` 里用（`commands.ts:354-358`） | 手机新会话显示「请选择模型」并**没有** default 回落 | 缺"回落宿主默认" | **不能**给手机加"未选模型 ⇒ 发送置灰"：那是 DSH 没有的边界（`AGENTS.md` 宿主语义优先）。正确说法是让默认值出现（T2-1/2） |
| 4 | 切模型 | `modelSeatLocked = removed || inert || !live`（`InputBar.tsx:160` —— **owner block 不锁它**，因为"选模型正是清障手段"，`:156-159`）；地址型子会话另有硬拒（`directory.ts:152-156`） | `onPickModel` 恒接（`ui/chat_page.dart:1005`），目录为空时弹"拿不到模型目录"（`:1914-1918`） | 子会话（addressed subagent）不该走 `session/select-model` | 桌面抛的是 `model selection is unavailable for addressed subagent sessions`；手机应隐藏/说明，而不是发出去再报错 |
| 5 | 分支（fork） | ① `useAccess('session/fork')`（`ui-chat/src/client/chat/TurnTailNodeView.tsx:32`）② 只在**收口行**（`:47-71`）③ `branchUnavailable = data.branchUnavailable || hasLaterChatNode`（`:71`） | 只在收口行给按钮（`ui/chat_page.dart:3705-3707`、`ui/chat_turns.dart:1174-1180`），在途置灰（`chat_turns.dart:1070-1080`） | 缺 ③（同轮后面还有节点时桌面不给分支） | 不置灰时应"不摆这枚钮"（桌面 `onBranch` 缺省即 `undefined`），不是灰按钮 |
| 6 | 打开文件 / 正文提及 | `fileMentions` + `openFile` 由外层注入，能力位决定有没有（`ui-chat/src/client/chat/ChatView.tsx:63,235`） | `filesAvailable` caps 门控（`data/app_model.dart:1660`；`docs/subsystems/prose-file-mentions.md`） | — | — |
| 7 | 建会话 / 切工作区 | 无工作区可解析时：`notify(draft.workspaceRequired)`，不清屏（`ui-workspace/src/client/navigation.ts:352-359`） | `defaultNewSessionWorkspaceId` 可能为 `null`，此时**不传** `workspaceId`（`data/app_model.dart:3305-3313`）⇒ 会话落宿主默认 cwd、不进任何工作区 | 缺"解析不出来时明说" | 桌面文案 `draft.workspaceRequired`；手机应说"这台电脑还没有工作区，会话会不进分组"或直接挡 |
| 8 | 子会话发消息 | `continuable` 才可输入；`one-shot`/`unknown` 换只读框；父离线另算（`InputBar.tsx:148-149`） | 已按 `one-shot`/`unknown` 换只读框（`ui/chat_page.dart:1336-1345`；`docs/subsystems/subagent-page.md`） | 父离线那一档不判（本仓注释已承认：拿不到 `parentAvailable`） | 保持"不知道就不承诺"；补 `parentAvailable` 需要宿主字段，**不在本批** |
| 9 | 归档运行中的会话 | 宿主回 `workspace/session-active` ⇒ 弹"停止并归档"（本仓 `data/app_model.dart:3041-3050`） | 已实现 | — | — |
| 10 | 附件 / 图片 | `uploadsPending`（`:94-96`）+ `uploadDenied`（`:65`）+ `imageLimits` 投影预检（`:109`） | 有 `imageLimits` 与 `isInert`（`docs/subsystems/attachments.md`） | 缺"上传中"这一档（手机附件是本地选图，没有宿主上传阶段） | 不引入假的上传态；按 `docs/subsystems/attachments.md` §已知边界说 |

---

## F. 桌面持久化机制本身（先读本节；C/D/E 都引用它）

### F-1 机制只有一层，且没有迁移框架

`client/store/src/index.ts`：

| 事实 | 行 |
|---|---|
| `createSnapshotStore(init, {persist:{name}})`：**创建时同步读**（`getItem` → `JSON.parse` → `setState`），解析失败只 `console.error` 并保留 `init` | `:146-158` |
| **写入＝每次状态变化同步 `setItem(JSON.stringify(state))`**；没有节流、没有合并、没有防抖；写失败只 log | `:159-165` |
| `flush` 默认 `sync`（受控输入要同拍回显），帧驱动的店可 opt-in `raf`（一帧合并成一次通知，**那只是通知合并，不是落盘合并**） | `:90-122` |
| `defineStore({init, persist, actions})`：`create(scopeKey?)` ⇒ 持久化键 = `persist` 或 `persist + '.' + scopeKey`（**scopeKey 就是 sessionId**） | `:217-227` |
| `init` 是**函数**：每个实例一份新默认值（默认值只写在 `init`，不散落在 UI） | `:214-227` |
| actions 是**纯 draft mutator**：没有任何一个 action 里写持久化（落盘完全由 store 声明负责） | `:228-232` |
| `clearPersisted()`：删掉这个键（"统一清理"的现成缝） | `:238-246` |
| 同一 resolve 键下多个活实例会**互相污染**；唯一性由框架"一 handle × 一 scopeKey 一实例"的缓存保证 | `:184-199` |

**迁移＝没有框架，只有三种手写手段**（这就是"版本号 + 迁移"在 DSH 里的真实形态）：

1. **键名带版本**：`dsh.workspace.view.v5`（`ui-workspace/src/client/stores.ts:91`）；换代即换键，
   旧键自然作废，`init` 兜住（`archivedFilter` 在 v5 之前缺失 ⇒ 读成 `'default'`，`:29-30`）。
2. **读时容错解析**：`parseStoredDraft` 先认字符串（旧形态）再按 zod 校验新对象，坏数据回 `undefined`
   （`ui-conversation/src/client/draft.ts:74-88`）；`workspace.view` 的 `retainAccountKeys`
   把已消失工作区的键删掉（`ui-workspace/src/client/stores.ts:100-109`）。
3. **prune（按活集合裁）**：提问草稿 `prune(draft, keep)` 只留还挂着的请求
   （`ui-user-questions/src/client/draft-store.ts:56-60`）。

### F-2 桌面**全部**持久化键与默认值（全仓 `persist:` 穷举）

| 键 | 作用域 | `init` 默认 | 谁读 |
|---|---|---|---|
| `dsh.workspace.view.v5` | 根 | `{groupBy:'workspace', orderBy:'updated', groupExpansion:{}, sessionOrderByAccount:{}, archivedFilter:'default'}`（`stores.ts:84-90`） | 侧栏分组/排序/折叠 |
| `dsh.sessions.current` | 根 | `{}`（`MainSelection`，`navigation.ts:28-31,173-175`） | 冷启动回到哪个会话 |
| `dsh.conversation` + `.<sid>` | **每会话** | `{draft:'', view:null, viewRequest:null}`（`stores.ts:23-25`） | 输入框草稿 / 页签 |
| `dsh.user-questions.drafts.v1` | **每会话** | `{progressByRequest:{}}`；每请求 `{index, drafts:[{selected[],custom,skipped}], wait?}`（`draft-store.ts:28-46`） | 提问卡（答一半离开再回来） |
| `dsh.trajectory.duration` | 根 | `false`（`duration-store.ts:9-13`） | 轨迹页用时显示 |
| `dsh.trajectory.jsonStringWrapping` | 根 | `false`（`string-wrapping-store.ts:9-13`） | 轨迹页 JSON 展开 |
| `dsh.voice-input.microphone` | 根 | `{id:'',label:''}`（`experimental/client-ui-voice-input/src/client/microphone-device.ts:15`） | 语音输入设备（实验） |
| `dsh.sidebar-browser.v1` | 根 | 未读（浏览器面板标签页） | 桌面专属，手机无对应物 |
| `dsh.plugin-manager.install-registry` | 根 | 未读（安装登记） | 桌面插件管理 |
| `dsh.open-in-app.choice` | 根 | 未读（用哪个 App 打开文件） | 桌面专属 |
| `dsh.creation-recommendations.info-dismissed` | 根 | `false`（`experimental/.../info-store.ts:7`） | 桌面专属（实验） |

另外两个**不是**浏览器持久化的偏好，走**宿主设置文档**（手机要读就得进连接器 allowlist）：

| 宿主设置 | 默认 | 作用 | 证据 |
|---|---|---|---|
| `ui-conversation.busyEnter` | `queue` | 跑动中按 Enter = 排队还是插话 | `ui-conversation/src/submission-settings.ts:1-33` |
| `ui-settings.developerTools.enabled` | **true** | 决定 `trajectory` 这个 View 是否进页签 | `ui-settings/src/developer-tools-settings.ts:13-16`；过滤 `ui-conversation/src/client/apply.ts:213` |

### F-3 页签是什么

不是"两档开关"，是**注册表**：`conversation.view` 是 `kind:'list' + scope:'session'` 的 slot
（`ui-conversation/src/client/contract/slots.ts:278`）；`chat`（`ui-chat/src/client/apply.ts:234-236`）
与 `trajectory` 各自注册进来，页签 id / 标签 / 顺序**都从注册项来**（`apply.ts:208-220`），
存的是 **id**；`resolveActiveView` = 存的 id 若已注册就用它，否则回 `chat`，**绝不挑第三方 View**
（`view-selection.ts:15-21`）。切 View 还要处理"注册表变了"（`apply.ts:242-262` 重算 + 每会话重设），
以及一次性 `viewRequest`（`openView` → 目标 View 消费后 `completeViewRequest` 清掉，`stores.ts:29-33`）。

→ 手机今天只有两档、用**下标**存，等于把"注册表"压成了"布尔"。本批不必做注册表，但**存 id**
（`'chat'` / `'trajectory'`），将来接第三方 View 不用改盘上格式。

### F-4 草稿是什么

不是一段文本，是 **`DraftSnapshot`**（`contract/draft-editor.ts:43-56`）：
`text` + `references[]`（`@`/`/` chip 的跨页身份：`source/ref/offset/length/label/clipboardText/appearance/invalid`）
+ 可选 `command.token`（命令 chip）+ 可选 `quotes[]`（引用块）。
读盘时有 **zod 校验 + 一致性约束**（引用必须有序、不重叠、且 `text.slice` 等于 `clipboardText`，
`draft.ts:27-52`），旧形态（纯字符串）被显式接受（`:74-75`）。写入时机 = 输入机 `publish()` 时，
**快照变了才写**（`input/facade.ts:950-957`），另有 `persistCurrentDraft()` 供"恢复/初始化"时补写（`:302-305`）。

→ 手机当前正文里**没有**引用 chip（`docs/subsystems/app-channel-client.md:193` 已记为有意偏离），
所以今天只需要 `text`；但**盘上形状照 `{text, references: []}` 起**，加 chip 那天不必换格式。

### F-5 "子智能体后台任务"的桌面方案（有现成公式，照抄）

```ts
// ui-workspace/src/client/tree.ts:381-386
function runningChildCount(list, parentId, statuses) {
  return list.projectionsBySession[parentId]?.values.subagentCatalog?.reduce(
    (count, child) => count +
      ((statuses.get(child.id)?.running ?? list.byId[child.id]?.running) === true ? 1 : 0),
    0) ?? 0
}
```

三点都在一句话里：**父行的 `subagentCatalog` × 子行的 `running`（状态流优先、列表行兜底）＝ 数量**。
它**不是**宿主字段（`SessionSummary` 里没有 `runningSubagentCount`），所以手机不需要新协议。

呈现也全是现成语义（`rows/Rows.tsx:392-445` `sessionStatuses`），**优先级四条**：

| 顺序 | 条件 | 状态点 | 文案键 |
|---|---|---|---|
| 1 | `pendingInteraction`（kind 三档） | warning | `status.waitingApproval` / `status.planReview` / `status.waitingAnswer` |
| 2 | `running` | ongoing | `status.running` |
| 3 | `runningSubagentCount > 0` | ongoing | `status.subagentsRunning.one` / `.other`（`{n}` 插值） |
| 4 | `completed`（= `completionUnread`） | done | `status.completed` |

且 1 与 3 **可以同时画两枚点**（`if (pending !== undefined) return subagents === undefined ? [pending] : [pending, subagents]`，`:438`；
`running` 与 3 同理 `:441`）。→ 手机 `model/session_dot.dart:9-15` 的"只有一枚点、没有 subagent 计数"是
**基于错误前提的自我限制**，桌面这里既没有第二份真值也没有额外字段。

### F-6 实现分叉原则：语义照桌面，机制照 Flutter（**不许硬套**）

数据源同一个 ⇒ **语义**（谁是真值、什么时候失效、什么条件禁用）必须与桌面一致；
但**机制**（存在哪、怎么写、什么时候读、怎么通知）由 Flutter/移动端事实决定。
下面五处是"照抄就会坏"的地方，证据都在本机 SDK：

| 面 | 语义（与桌面一致） | 桌面机制 | Flutter 必须换成 | 为什么（证据） |
|---|---|---|---|---|
| 草稿的**活文本** | 用户打的字不丢 | 存进 `dsh.conversation` store（细粒度 store，只有输入栏订阅） | **`TextEditingController` 仍是唯一主人**；落盘是旁路 sink | `ChangeNotifier.notifyListeners()` **同步遍历全部监听者、无合并**（`packages/flutter/lib/src/foundation/change_notifier.dart:410-451`）⇒ 草稿一旦进 `AppModel` 并 `notifyListeners`，**每个击键整页 `ListenableBuilder` 重建一次** |
| 草稿**恢复** | 重启/切会话后同一条草稿 | 编辑器 `setDraft` 后自动聚焦（浏览器无输入法） | 只设 `controller.text` + 选区归零，**不请求焦点** | `EditableText._handleFocusChanged` 第一句就是 `_openOrCloseInputConnectionIfNeeded()`（`widgets/editable_text.dart:4752-4753`，定义 `:3992`）⇒ 带焦点恢复 = 键盘自己弹出来，违反 `docs/subsystems/input-focus.md` |
| **写盘频率** | 内容变化就记下 | 每次变更同步 `localStorage.setItem`（`client/store/src/index.ts:159-165`） | 合并 + 尾部防抖；`AppLifecycleState.paused` 强制刷一次 | sqflite 是异步事务（不能每击键 `await`）；后台被杀前必须落盘 —— 复用既有 `platform/app_state_reporter.dart` 的 paused 态，不另造观察者 |
| **作用域** | 每会话一份 | 键后缀 `dsh.conversation.<sid>`，**从不清理**（死键永久留在浏览器） | 一张表 + 按活会话 **prune** | 已删会话的草稿**没有语义**；桌面不 prune 是 localStorage 的便宜，不是产品要求 |
| 行首状态点 | 待处理 > 运行中 > 子代理在跑 > 已完成 | 侧栏行里**两枚点** + 缩略文案 | 360px 只能**一枚点 + 一行文字** | 布局事实（`type-scale.md` 的 minHeight、`chat_page.dart` 的 `_BottomBudget`）；桌面侧栏宽 240–420px，手机整行 360dp |

推论（第 2 段的写法）：**默认值与唯一真值仍照桌面取（`catalog.default`、`inspect` 出来的既有事实），
但"存哪、怎么通知、写多频"全部按上表重选** —— 这不是偏离，是同一语义的 Flutter 实现。

### F-7 移动端参照实现（rikkahub，Android/Compose）给的选择

`D:\sudy\github\rikkahub` 是仓库登记过的移动端参照（本仓用量页的形态也取过它）。逐条对照：

| 关注点 | DSH 桌面 | rikkahub（移动端实际做法） | 我们的选择（Flutter） |
|---|---|---|---|
| 输入框活文本 | 自己的 store | `ChatInputState.textContent = TextFieldState()`，纯 UI 层（`ui/hooks/ChatInputState.kt:12-17`） | `TextEditingController`（UI 层），**不进 AppModel** |
| 草稿持久化 | **每会话**持久化 | **完全不持久化**（全仓无 draft/unsent 存取） | 做，但**必须便宜**：旁路 sink + 防抖 + 只有落盘侧订阅；**不做就等于没有**——这是"照 DSH 语义 + 用户要求"，不是移动端惯例，所以不能照桌面的"每击键同步写" |
| 模型/助手选择记忆 | host 投影 + `catalog.default` 回落 | **会话行的一列** `assistant_id`（`data/db/entity/ConversationEntity.kt:11-12`，带 `defaultValue`） | 与桌面一致：**host 投影 + `catalog.default`**，手机不建本地键 |
| "默认选哪个" | `agent-default-model` 服务 | settings 里 `?: DEFAULT_ASSISTANT_ID` / `?: DEFAULT_AUTO_MODEL_ID`（`data/datastore/PreferencesStore.kt:273-292`） | 读 `session/modelCatalog` 的 `default`（宿主已有），**默认值只在声明处写一次** |
| 发送门槛 | `empty \| disabled \| machineBusy \| uploadsPending`（`InputBar.tsx:343`） | **`enabled = showStop \|\| !empty`**（`ui/components/ai/ChatInput.kt:442`；`empty = 文本空 且 无附件`，`ChatInputState.kt:93-95`） | `empty` + 无会话 + hero 无工作区 + 子会话只读；**不含模型** —— 两个独立实现都印证 §C-1 |
| 版本与迁移 | 键名带版本 / 读时容错 | **编号迁移脚本 + 列默认值**（`data/db/migrations/Migration_11_12.kt` 等 8 个、`@ColumnInfo(defaultValue=…)`） | **并进本仓既有的 `storeSchemaVersion` + `storeMigrations`**（`data/store.dart:32,199-241`；由 `platform/sqflite_item_store.dart:47-64` 的 `onCreate`/`onUpgrade` 执行）—— 这就是移动端原生做法，比"键名带版本"更对 |
| 偏好存取 | localStorage 整值 | DataStore + 自己的编号迁移（`data/datastore/migration/PreferenceStoreV{1,2,3}Migration.kt`） | `meta` 表（sqflite），与 items 同库同迁移代 |

两条可直接落进第 2 段的结论：

1. **设备本地 UI 状态进库、走项目既有的编号迁移**（`storeMigrations` 加一代建 `ui_state` 表），
   不发明键名版本、也不另开一套迁移。
2. **草稿持久化必须做成旁路**：rikkahub 干脆不做，桌面做得很贵（每击键同步写）；
   我们要做就得介于两者之间 —— 防抖 + 生命周期强制刷 + 不触发整页通知。

---

## C. 与清单不一致的四处 + 一处新发现（以源码为准，先改文档再改代码）

1. **清单第 5 条"未选模型时发送键不可用"不成立**。桌面发送门槛里没有模型项
   （`InputBar.tsx:343` 的四个条件 + `:154` 的五个 disabled 来源，与模型无关）；
   会话无记录选择时**跟随宿主默认**（`agent.ts:464-472`），只有 `selectModel` 才校验模型可用性
   （`commands.ts:354-358`）。所以正确修法是"补默认值"（T2-1/2），不是"补一条置灰"。
   —— 任务书里"缺工作区/模型置灰"这一句，**工作区成立、模型不成立**。
2. **清单第 4 条"新会话工作区不记"实际已按桌面的链实现**（`data/app_model.dart:2956-2965` +
   `model/workspace.dart:141`，链的出处 `navigation.ts:337-368`）。它不是缺口；
   真正缺的是 §B-7 的"解析不出来时怎么说话"。
3. **抽屉展开态不是"没有稳定 key"**：`DrawerSection.workspaceId` 就是宿主工作区身份
   （`ui/session_drawer.dart:91-98`），桌面也用工作区身份作键（`ui-workspace/src/client/stores.ts:25-26`）。
   现在按 `label` 记（`:363-367`）会在改标题后丢，且跨重启丢。
4. **恢复时机的既有代价**（不是新缺口，但第 2 段必须一并处理）：`ui_scale_index` / `theme.mode`
   都在内容首帧之后才读回（`app_model.dart:1390-1417`、`main.dart:194`），首帧用默认值，
   于是**字号与主题会跳一下**。桌面是同步 localStorage（首帧前）所以不跳。
5. **`send_mode` 是第二份真值，不是"桌面没有、手机新加"**：桌面的发送模式寸在**宿主设置**
   （`ui-conversation` 命名空间的 `busyEnter`，`ui-conversation/src/submission-settings.ts:1-33`），
   手机的 `send_mode` 寸在 `meta` 表，而连接器设置 allowlist 只有三个 ns
   （`connector/src/dsh/settings-face.ts:26-29`，不在里面的 ns **静默跳过** `:52-53,89-92`；
   手机侧同一份清单 `data/app_model.dart:1519-1523`）⇒ 两边可以打架。要么扩 allowlist（改连接器 + 金样），
   要么把"手机本地、不回写"写进 `docs/` 并留决策笔记 —— **本段不选，第 2 段定**。

## D. 仍未测 / 仍开放（其余都已从源码定案）

### D-0 已从源码定案、不再算"不确定"的（附出处，免得下次又去猜）

| 问题 | 结论 | 出处 |
|---|---|---|
| 提问草稿要不要留 | **要**，桌面按每会话持久化 `{progressByRequest:{<key>:{index, drafts:[{selected[],custom,skipped}], wait?}}}`，带 `clear` / `prune` | `ui-user-questions/src/client/draft-store.ts:28-60`（注释原话：离开会话或重启不擦未答完的答案，`:38-42`）；手机同四样是内存态 `ui/takeover.dart:103-118` |
| 草稿 `prune` 什么时候跑 | 按**活请求集**裁：`actions.prune(pending.liveKeys())` | `ui-user-questions/src/client/QuestionComposer.tsx:230` |
| "跑完未读"绿点是谁的 | **客户端派生**，两边都不落盘（跑完时不是主视图 ⇒ 记 unread；成为主视图 ⇒ 立刻清） | `ui-session/src/client/index.ts:292,512-514,529`；手机 `data/app_model.dart` 的 `_completionUnread` 同构 |
| `parentAvailable` 从哪来 | **客户端**字段（不是 `session.list`）：由 `agentAvailable(parentSessionId)` 初始化，父会话被移除时翻 `false` | `api/session-controller/src/client/contract/snapshot.ts:77`；`client/sessions/manager.ts:277-286,722-725` |
| 待处理角标数什么 | 桌面**没有计数**，只有 kind 三档 + 另有 `runningSubagentCount` 那枚点 | `ui-workspace/src/client/tree.ts:35,369-379,396-402` |
| 轨迹/JSON 展开两个开关 | 桌面持久化，手机轨迹页有意不做 | `ui-trajectory/.../duration-store.ts:9-13`、`string-wrapping-store.ts:9-13`；`docs/subsystems/trajectory-page.md` |

### D-1 "发不出去"的报错规则：**已由源码穷举，不需要实测**

`session.prompt` 从手机到宿主一共两层校验，**能返回的错误码只有下面这些**（逐一给行号）：

**连接器层**（`connector/src/handlers.ts:601-625`）

| 码 | 触发条件 | 行 |
|---|---|---|
| `protocol/bad-frame` | `sid` 缺失/空串 | `:407-413` |
| `protocol/bad-frame` | `requestId` 缺失或空（写必带幂等键） | `:606-608` |
| `protocol/bad-frame` | `content` 不是非空数组，或某项没有 `type` | `:578-589` |
| `protocol/bad-frame` | `mode` 不是 `queue`/`steer` | `:611-613` |
| `session/not-found` | 别名不认识（连接器别名表里没有这个 sid） | `:422-428` |

**宿主层**（`api/session-controller/src/index.ts:451-476` → `commands.ts:305-352` → `agent.ts`）

| 码 | 触发条件 | 行 |
|---|---|---|
| `gateway/bad-request` | content 里既没有非空白文本也没有附件 | `index.ts:454-456` |
| `session/invalid-time-zone` | `clientTimeZone` 非法（**手机不发这个字段**，不可达） | `index.ts:460-466` |
| `session/not-found` | 会话不存在 / 准入期间被 dispose | `agent.ts:197-199`、`commands.ts:331-337` |
| `session/writer-held` | 该会话日志的写句柄已被别的 owner 占住（`SessionAlreadyOwnedError`） | `agent.ts:209-211` ← `session/session-persistence/src/errors.ts:30-37` |
| `session/agent-busy` | 子会话归 subagent 路由所有（`reason: use subagent delivery for this child session`） | `agent.ts:117-123,181-182` |
| `session/agent-busy` | `followup`/`steer`/`bindPrompt` 抛的任何其它错 | `commands.ts:342-348` |
| `session/attachment-invalid` | 带图但当前模型的 `inputModalities` 不收图；或 `AttachmentError` | `commands.ts:316-327,344-346` |
| `gateway/cancelled` | 调用方在准入前取消 | `index.ts:453` |

**三条结论**（都能从表里直接读出来，不用量）：

1. **没有"模型"这一项** —— 与 §C-1 一致：模型只在 `selectModel` 里校验（`commands.ts:354-358`）。
2. **没有"空白会话"或"工作区"这一项** —— 宿主 prompt 路径上**完全没读** `blank` / `workspace`。
   所以"因为它是空白会话所以发不出去"这条因果**在源码里不存在**。
3. `{accepted: true}` 的语义是**"收下了"**，不是"跑起来了"（`commands.ts:349`）：真正的回合由
   agent 循环起。所以"**没有任何报错、消息也进了正文、但没有回合**"是**另一类**现象，
   不是 RPC 失败 —— 本仓 `tools.md` 已记录一条确定机制：**工作区已失效的会话，prompt 照常落
   `user/message`，agent 永远不起轮次，全程零错误**（`tools.md` 的「真机靶子会话的工作区必须存在」）。

**手机侧已经能自己区分这两类**（不用专门跑评测）：失败会走 `_send` 的 catch
（`ui/chat_page.dart:612-614`），而 `ProtocolException.toString()` 带码
（`core/errors.dart:219-220`）⇒ toast 里出现 `ProtocolException(<code>)` 就是上表某项；
**完全没有 toast、正文却有那条消息、回合不启动** ⇒ 第 3 条（会话的工作区/进程侧已失效）。

### D-2 仍开放（三条，按影响排序）
1. **`parentOffline` 的等价判据**：桌面是"客户端有这个父会话的**活 agent**"（`agentAvailable`），
   手机能拿到的最接近事实是"父会话**还在 `session.list` 里**"（子行自带 `parentSessionId`，
   `wire/rpc/session.dart:272`）。两者**不等价**（活 agent 与"列表里有一行"不是同一件事）。
   建议：取近似 + 在 `docs/` 写明偏差；不取"不判"——默认放行会在父级没了时必然失败。
2. **手机侧的写入节流参数**：桌面是"每次变更同步 `setItem`"（`client/store/src/index.ts:159-165`），
   sqflite 不能照抄（移动端规范要求异步合并）。需要一个**实测上界**（单次事务毫秒数）来定 debounce，
   并把数字写进 `docs/` 与用例。这是"有意偏离"，不是桌面缺口。
3. **360px 上"子代理在跑"放哪**：数据、文案、优先级都有现成方案（§F-5），**唯独布局没有**
   桌面对应形态（桌面是侧栏行内两枚点 + 会话页面板）。需要一次设计，并过底部预算
   （`ui/chat_page.dart` 的 `_BottomBudget`）与 `type-scale.md` 的 minHeight 规则。

### D-3 我们这边已拍板（不是不确定，写进 `docs/` 即可）

- 页签集**不**镜像宿主 `ui-settings.developerTools.enabled`（默认 true，观感一致；读它要再开一个
  allowlist 条目，收益为零）。
- 行首状态点**维持一态**（计划审查卡手机有意不接），中文案不变；与桌面的三 kind 差异写进 `docs/`。
- `last_session` 死别名：落点判定失败时**删键**（照 `navigation.ts:515-521` 的 `clearMain` 语义）。

## E. 第 2 段必须回答的问题（本文件不写答案）

1. `device-local` 的统一机制（照 `client/store` 的三条事实设计，不发明新库）：一个键前缀
   （现有三种风格 —— `send_mode` / `theme.mode` / `dsh.*` —— 的迁移路径要写出来）、
   **默认值只写在声明处（对应 `init`）**、**一处恢复点**（`AppModel.start()`）、
   **一处清理**（`clearPersisted` 的对应物：重新配对时清哪些键、哪些必须留）。
   迁移手段照桌面那三种（键名版本 / 读时容错 / prune），不引入 schema 框架。
2. 页签 / 草稿是**按会话**的（桌面 `dsh.conversation.<sid>`）：手机的 `AppModel` 是否要持有
   `sid → 会话级 UI 状态` 这一层？住哪个文件（`AppModel` 已 4078 行，`app_model.dart:1-4078`）。
3. `host` 类状态：`catalog.default` 的回落点放在 `AppModel.currentModel`（一处）还是每个消费点？
4. 动作门槛的唯一入口签名（"能用 / 缺什么 / 第几句话"）以及它与 `caps`、`blocked`、
   `machineBusy` 的关系；哪些条件是**手机没有的**（`machineBusy` 的裁定/提交阶段）—— 没有就写"不判"。
5. 连接瞬间："子智能体后台任务"进会话页所需的最小解析（父行 `values.subagentCatalog` + 子行 `running`）
   会不会打破 `wire/` 单入口预算（`node app/tools/verify-rpc-single-caller.mjs`）。
6. `send_mode` 的归属（§C-5）。**倾向照宿主**：读 `ui-conversation.busyEnter`、写回同一条
   （`settings.describe` / `settings.update` 已有，只是 allowlist 少这个 ns 与这个 path ——
   属"补通道"，不是"替宿主决定"，符合 `AGENTS.md` 三问）。代价写明：连接器
   `settings-face.ts:26-29,34-39` 各加一条 + 连接器用例 + 手机侧改成"宿主值 + 本地覆盖？
   **不叠加**，直接以宿主为准"；本机旧键 `send_mode` 作废（版本迁移：首次启动读一次旧键
   当**初始请求**回写宿主，然后删键）。替代方案（保留本地）的代价是**两份真值长期共存**，
   手机与电脑会显示不同的发送模式而无处解释。
