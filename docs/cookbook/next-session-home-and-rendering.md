# 新会话提示词:连接后首页(blank 会话 hero)+ 会话渲染对齐 DSH

> 复制下面 `---` 之间的全部内容到新会话。
> 上一份(`next-session-interaction-to-phone.md`)的任务已完成,别再照它跑。
> 本份是 2026-10-17 深夜里那轮四条反馈的**后两条** —— 前两条(统计条横滚 + 顶栏收成一行)
> 已在同一轮落地并全绿,别重做。

---

## 任务

用户 2026-10-17 一次提了四条界面问题,**前两条已做完**,这两条只调研过、**一行代码没动**:

- **③ 刚连上电脑时落的那一屏要像 DSH Web 的新会话页**:「刚链接的首页能不能像人家这样?
  或者就是 web 端是啥页面,连接上的时候就是啥样?这应该可以做的,通过插件,
  应该原生能力都可以支持」。(**范围已在下方「验收口径」里澄清过:只有这一屏,不是所有页面。**)
- **④ 会话页面的渲染与 DSH 差距很大**:「这个渲染其实可以自己做,甚至做得更好的」,
  点名参考 rikkahub / DEEIX-Chat / deepseek-harness。

**建议顺序:先 ③ 再 ④。** ③ 是独立一块(hero + 两个选择器 + 一个连接器只读方法),
④ 要动 `chat_page.dart`(100KB)与 `chat_item.dart`,风险与改动面都大得多,适合单独一轮。
顺序由你和用户确认。

## ③ 的验收口径(2026-10-17 深夜,含用户澄清)

> 原话:"连接后最好是电脑显示啥手机也显示啥,方便,因为就是操作电脑的。"
> **随即澄清**:"我说的是**刚连上的时候的页面**,显示的不是 web 所有页面啊。"

**所以 ③ 的范围就是"刚连上时落的那一屏",不是"把 Web 的每个页面都搬过来"**:

- **要的**:连上电脑后落到的那个 **blank 会话页**,长成 DSH Web 新会话页那样
  (鱼 + 「探索未至之境」+ 工作区 chip + 模式 chip + 大输入框),
  而不是现在的空态 / "选一个会话"。
- **不要的**:左侧栏 / 右侧栏 / 插件页 / 设置页 / 内嵌浏览器 —— 那些仍然只在电脑上。
- **为什么这条路走得通**(一句话):手机与电脑是**同一个 DSH 进程的同一批 `@Remote` 方法
  与会话投影**,所以那一屏的数据都能照形状拿到(`docs/mobile-surface-roadmap.md` 的不变量)。
  但"能拿到"≠"要照搬布局":桌面尺度(卡片 712–952px、标题 26px、chip 13px)要按触屏重算。

## 插件边界(用户 2026-10-17 追问,已按源码给结论)

> 用户原话:"桌面版安装了插件也可以用是吧?因为都是接口传输是吧"

**对了一半 —— 看插件贡献的是什么。**

- **✅ 插件提供的「能力」跟着走**:插件装的是工具 / 命令 / 服务 / agent 预设。手机发一句话,
  电脑上的 agent 用它装的插件跑,结果照形状回传 —— 手机**不需要知道插件的存在**。
  手机现在用的 `ask_user_question`、后台任务、子智能体、计划模式、权限档本身就是 DSH 的子系统
  / 插件。**Agent 预设(就是「标准模式」)本质就是"插件组合"**。
- **❌ 插件自己画的界面传不过来(架构事实,不是没做)**:插件 UI 是 `dsh.client` 声明的
  **浏览器 bundle**,宿主 `/plugins` 把 `client.js` 送到浏览器 → 模块加载器执行 →
  往 slot 注册表注册 React 组件(`packages/client/ui-slots/src/index.ts:1203`)。
  **线上没有任何"UI 描述",只有代码** —— 手机要显示它 = 手机要跑 DSH 的 Web 客户端。
  完整论证见 `docs/plugin-and-jobs-notes.md` A.6(每条带行号)。
- **中间地带(结构化数据,手机能做,但连接器现在一个都没接)**:`pluginInventory.list()`
  (`packages/host/plugin-inventory/src/index.ts:70-73`)、`pluginManager.listBundles()`
  (`packages/boot/plugin-manager/src/index.ts:279-319`)、行级与 bundle 级启停
  (`setPluginEnabled` `:424-435` / `setBundleEnabled` `:442-448`)、安装日志流
  (`plugin-manager/install-log`,白名单 `packages/api/remotes/src/remote-events.ts:43-44`)。
  **方法面 30 个里没有插件方法** —— 想上"手机上管插件",这是独立的一批接线。
- **配置只有 `.volatile()` 字段过线**(Schemastery `schema.toJSON()` 信封,
  `packages/settings/settings/src/index.ts:302-340`);其余配置**根本不过线**,
  只能显示"需在电脑上编辑"。**别自己从零做通用 schema 渲染器** —— DSH 两次否决过
  (`.agents/notes/archived/architecture/2026-07-30-web-config-plane.md:31`、
  `2026-08-10-web-plugin-configuration.md:37`),理由都是"字段真相没有视觉层级 = 不可用的卡片"。

## 前两条已完成(别重做,也别"顺手改回去")

2026-10-17 深夜落地,笔记:
`.agents/notes/implemented/2026-10-17-topbar-single-row-and-stats-scroll.md`。

- **统计条**(输入卡片下方)改成**单行 + 横向滚动**(`Wrap` → `SingleChildScrollView`)。
  真机实测三项合计 632.6dp、411.4dp 屏可用仅 391.4dp,缩字号填不平 → 用户明确选了"一行 + 可滑"。
  轮次格文案改回 DSH 原文 `{turns} 轮 {steps} 步`(原来多印了「第」和一个 `·`)。
- **顶栏收成一行**:标题 `14→13px` / 上限 `220→140px` / 图标 `18→16`;
  **子智能体 / 后台任务计数 chip 进顶栏**(取"图标 + 计数",全文本退进 aria/tooltip);
  原来那一整行撤销(`_LiveChipsRow` / `_LiveChip` 已删)。
- 基线文档、原型 `mock/proto`、`memory.md` / `tools.md` 都已同步;
  `mock/proto/tools/verify-proto.mjs` 从"只 dump JSON"补成 **13 项断言**。

## 起手第一步(必做)

读这些,并**核对被引用的 DSH 行号是否仍指向该内容**(行号会漂;对不上就改正,别照抄):

1. `memory.md` + `tools.md` —— 当前门禁基线、坑点、真机装法。
2. `.agents/notes/implemented/` 里最近的几篇(尤其 `2026-10-17-topbar-single-row-and-stats-scroll.md`
   与 `2026-10-16-message-body-stays-gfm-markdown.md`、`2026-10-17-conversation-rendering-fills-dsh-gaps.md`)。
3. `docs/design-and-tech-plan.md` §7.2/§7.4/§7.8(会话页、统计条、顶栏三段)。**与文档冲突时先改文档再改代码。**
4. DSH 源码 `D:\sudy\github\deepseek-harness`(只读)。

---

# ③ 连接后首页 = DSH 的 blank 会话 hero

## 调研结论(已核实,直接可用)

**1. DSH 那个首页不是"没有会话",是"已有会话但它是 blank"。**
`ConversationMainPanel.tsx:41-43` 的 `hero` 有两个来源,实际走的是后者;
blank session 在**工作区连接时被急切创建**(`ui-workspace/src/client/navigation.ts:195-205`
的 `reuseOrCreateBlank()`,复用不到就 `sessions.create({ workspaceId })`)。
证据:渲染快照 `snapshots/web/lifecycle-chrome/plan-active-zh.expected.md:23-25` 同时出现
权限 / 计划 / 模型三个按钮,而这三个在 `InputBar.tsx:464,465,476` 都被
`sessionId === undefined ? null : …` 包着 ⇒ `sessionId` 已定义。

> **对手机端的含义**:不要照抄"无会话态"。手机已经有 `blank` 标志
> (`model/chat_item.dart` 的 `SessionSummary.blank`,连接器一直在发)与
> "这个会话还没有内容"的空态分支(`chat_page.dart` 的 `_ChatTab`)——
> 所以这是**把那块空态换成 hero**,不是新造一套页面状态。

**2. 组件树**(`ConversationContent.tsx:164-169` 是装配点):

```
composerStack(.composerHero)
├─ HeroShell                      EmptyHero.tsx:132
│  ├─ .headline: fish(34px) + 标题「探索未至之境」26px/32px/w500 + 「预览版」徽标
│  └─ .body(空)
├─ .heroWorkspaceRow              仅 hero:WorkspaceChip + AgentPresetSeat
├─ [slot] conversation.input.dock
└─ InputBar(variant='hero')       InputBar.tsx:46
```

尺寸(都在 `HeroShell.module.css`):`.stack` gap 12px、`.headline` 标题 **26px/32px/w500**、
fish **宽 34px**(`EmptyHero.tsx:104-105`)、工作区 chip `min-height:28px` / `13px/20px/w500` /
`radius 8px` / `padding 0 8px`、模式 chip 同形(`AgentPresetSeat.module.css` 顶部注释:
"Geometry mirrors HeroShell's .workspace so the two read as one row")。
**卡片与标题的桌面尺度不能用**:卡片 `max-width` 是 712–952px(`ConversationRoot.module.css:384-389`),
手机上要按比例重算,别照抄像素。
「预览版」徽标**没有开关,无条件渲染**(`EmptyHero.tsx:155`),用等宽字体 + `StadiumBorder`
(CSS 的 `corner-shape` 在 Flutter 里没有对应物)。

**3. hero composer 与普通会话 composer 的差别**(`InputBar.module.css`):
输入区最小高 **52px**(普通 36px)、占位符**两行**(普通一行 `nowrap`)、底部内边距 0(普通 4px)、
dock 里只有 `ContextMeter`。**按钮集合完全相同**。

**4. 占位文案有两套**(`ui-conversation/src/client/locales.ts:20,23`):
`placeholder.default` = 「发消息或创建任务, / 调用指令, @ 文件或对话」(手机现在恒用这套)vs
`placeholder.hero` = 「描述你想要构建的内容, / 调用指令, @ 文件或对话」。
**都是半角逗号。**

**5.「标准模式」= Agent 预设**,不是计划模式、也不是权限档 —— 三者是三个独立控件、
三个独立写路径(快照里同时出现;排除依据:权限注册在 `ui-permission-presets/src/client/index.ts:167-174`、
计划模式在 `ui-plan/src/client/index.ts:116-128`)。

| id | 中文名 | 出处 |
|---|---|---|
| `standard` | 标准模式 | `agent-preset-registry/src/display.ts:41` |
| `ptc` | PTC 模式 | `:42` |
| `minimal` | 极简模式 | `:43` |
| `cordis` | 创造模式 | `:44` |

显示名解析 `presetDisplayText`(`display.ts:63-73`):**内置预设走本地化字典,
用户自建预设的元数据永不翻译**(判据 `isBuiltInPreset` = 没有自定义 `name` 且 id 在表内)。
文案在 `ui-agent-preset/src/client/locales.ts:95-102`。

**6. 写路径不用加方法面。** DSH 那边是 `remote.agentPresets.select(sessionId, id)`
(`seat-store.ts:230`),而它**跑过一轮就拒绝换**(`agent-preset-registry/src/index.ts:351`
抛 `agent-preset/locked`,原注释 "a session's composition is fixed once its conversation starts")。
手机侧的出路更干净:**连接的 `session.create` 已经收 `agentPreset`**
(`connector/src/handlers.ts:387,391`;DSH 侧形状 `SessionCreateRequest`
`packages/api/session-controller/src/types.ts:288-293`)—— 手机自己建会话时把它传进去,
就绕开了"跑过就锁"。

**7. 唯一要加的读取面:预设目录。** DSH 侧是 `@Remote('list')` → `remoteExportList()`
(`agent-preset-registry/src/index.ts:194-197`),返回
`{presets:[{id, name?, description?, isDefault, broken?}]}`(`types.ts:12-22`);
`presetOptions()` 只保留 `broken === undefined` 的项(`ui-agent-preset/.../settings-store.ts:119-127`)。
连接器现在是 in-process 插件,直接 `ctx.get('agentPresets').remoteExportList()` 即可。
**这是方法面 30 → 31 的唯一增量**;改完要同改三处:契约 §5.7、`tools.md` 的方法数、`memory.md` 的"方法面 x/30"。

**8. 工作区选择器**:数据已在手机侧(`workspace.list` → `AppModel.workspaces`,
`connector/src/dsh/workspaces.ts:76`),条目就是 `{workspaceId, title, path}`。
**DSH 的语义是"切工作区 = 立刻建/复用一个该工作区的 blank 会话,并把草稿搬过去"**
(`ConversationContent.tsx:119-131` → `navigation.ts:220-230`,`beforeOpen` 把草稿与附件搬过去),
不是"只记住选择"。

**9. 鱼 logo 不在现有 98 个图标里。** 抽取器只扫
`ui-primitives/src/icons/index.tsx`、`shared-artwork.tsx`、`PermissionIcon.tsx`、`props.ts`
(见 `mock/proto/icons.js` 的文件头)。
`FishLogo.tsx` 只有一条 path + `FISH_LOGO_VIEWBOX = {width:23.16, height:17.04}`,
**给 `mock/proto/tools/extract-dsh-icons.mjs` 加一条来源、重跑它,再跑
`node app/tools/extract-dsh-icons-dart.mjs`** —— 两边产物都不许手改。
(注意它 `svg` 上是 `fill="none"`、path 上才是 `currentColor`,与图标集里的写法不同。)
`HeroFish` 的 hover 游动形变(`EmptyHero.tsx:111-121` 的 SMIL)**不要搬** —— 触屏没有 hover。

**10. 手机端做不到 / 该砍的**(调研已分类,别浪费时间去试):
拖拽上传(HTML5 drag & drop)、**"添加工作区…"的目录选择器**(走 Host 同机的操作系统文件夹对话框,
`ui-directory-picker-native/README.md:12,28,34`:明确写着"browser runs on the same machine as the Host"),
hover 游动、快捷键提示、`<input type=file multiple>` 原生多选、滚轮链式传递、列宽拖拽手柄、Electron 窗口 chrome。
另:**首页在 blank 期没有任何内容区**(`DefaultConversationViews.tsx:32` 直接返回 `null`),
所以手机也不要在 hero 下塞"历史会话列表"。

## ③ 的验收判据(建议)

1. Blank 会话(或未选中会话)时主界面出现 hero:鱼 + 「探索未至之境」+ 预览版徽标 +
   工作区 chip + 模式 chip;占位文案是 `placeholder.hero` 那句。
2. 工作区 chip 显示的是**当前会话所属工作区**的标题(链:`pendingWorkspace` → 会话所属
   → 列表未 ready 且有 cwd 时用目录名 → **列表 ready 但无归属时占位**,绝不拿已删目录名顶上;
   出处 `ConversationContent.tsx:89-108`)。
3. 模式 chip 显示**当前会话的 `agentPreset` 投影**(`AgentPresetLabel.tsx:46-49`),
   跑过一轮的会话上是**只读标签**(原注释 "Read-only by construction");
   blank 会话上可切,写路径走 `session.create({agentPreset})` 或 `agentPresets.select`。
4. 手机新建会话时**带上所选 `workspaceId` 与 `agentPreset`**,并有一条断言钉住参数形状。
5. 原型 `mock/proto` 同步,且 `verify-proto.mjs` 补上 hero 的断言。

---

# ④ 会话渲染对齐 DSH(甚至更好)

## 现状:一眼能看出的差距(同一会话、同一时刻的真机对照)

| | 电脑 DSH Web | 手机 |
|---|---|---|
| 工具调用 | `> 运行命令 · Commit handoff-2 and memory update, not pushing` —— **一行**、无卡片边框 | `✅ 工具  role, source, toolCallId, conten…  ›` —— **52dp 暖色卡片**,名字退回默认「工具」,参数是 JSON 键名堆 |
| 思考 | `思考 · Commit 成功:` 一行弱化文字 | `思考过程 ›` 一张带边框卡片 |
| 助手头 | **没有**头像/「助手」行 | `✦ 助手` + 头像 |
| 统计条 | 一行居中、无底色 pill | (本轮已改成一行横滚) |

## DSH 的结构(照这个重建)

**1. 三级管线**:事件 → **Node**(13 种)→ **过程组** → ViewSnapshot → 组件。
聚合在 `ui-conversation/src/client/conversation/assembler.ts:174`;
业务定义在 `ui-chat/src/client/conversation-nodes/register.ts:22-38`;
**完整规格书是 `ui-chat/src/client/conversation-nodes/README.md`(330 行)——
建议先把它译成中文规格入 `docs/`,这是移动端最省力的真值源。**

**2. 折叠有三层**:整轮 → 组 → 单块,默认态由**四档模式单一决定**
(`ui-chat/src/client/presentation-policy.ts:28-57`):

| 模式 | foldCompletedTurns | stepGrouping | liveProcessDetail | settledReasoningPreview |
|---|---|---|---|---|
| compact | true | collapsed | false | false |
| standard(桌面默认) | true | collapsed | true | true |
| detailed(非桌面 Web 默认) | true | history | true | true |
| verbose | false | none | false | true |

**手机已经有这四个设置项**(`model/preferences.dart` 的 `TranscriptView`:简洁/标准/详细/完全展开,
文案照 `ui-chat/src/client/locale.ts:103-108`),但**只传了一个 `autoOpenToolDetail` 布尔** ——
策略本身没实现。把这 4×4 表直接落成 Dart 枚举,别在 UI 里散落判断。

**3. 分组规则**(`conversation-nodes/process-groups.ts:128-185`):
独立根 `INDEPENDENT = {user, steering, turn-trigger, model-retry, turn-error, turn-max-tokens, turn-tail}`
(`:13`)切断当前组;`turn-process` 控制行不切断(`:168-170`);`assistant-step` 带 reasoning 入组(`:172`)、
是回复则关组(`:173-176`);其余(含工具)入组(`:177`)。
"是回复"判据 `hasAssistantReplyContent`(`contract/assistant-content.ts:9-15`):
text 非空白 / image / 其他可见块 —— **reasoning 与 tool-call 不算回复**。
组标题 = 计数排名前 3 + 「等」(`chat/step-process.ts:11-27`)。

**4. 工具名分类表**(`conversation-nodes/README.md:256-270`):
`read` / `read_image` / `grep|glob|*_inspect` / `bash|pwsh|exec_command|write_stdin|terminal_*` /
`run_code` / `web_search` / `web_fetch` / `subagent*` / `todo_write|create_goal|update_goal|get_goal` /
`ask_user_question|request_user_input` / 其余归 `tools`。分类名文案表 `README.md:153-168`,
live detail 字段优先级 `README.md:310`,**截到 160 grapheme**`README.md:330`。

**5. 流式**:持久事件里**没有 `message/delta`**(权威定义 `core/session/src/types.ts:281`);
瞬态走 `assistant/live-chunk`(`api/session-controller/src/client/contract/events.ts:7`),
用**分数 seq** 插在持久 seq 之间(`assistant-stream.ts:88`),step 结束时被 `assistant/message`
**整体替换**(`events.ts:181-196`)。连接器若同时转发两者,**必须实现同一条替换规则**,否则出重复气泡。
Markdown 侧:**冻结除末尾两块以外的块、只重解析尾部**(`ui-primitives/src/markdown/incremental.ts:38`
的 `UNSTABLE_TAIL_BLOCKS = 2`),冻结键是**绝对源码 offset**。

**6. 截断是头/尾各半 + 可全展开**(`ui-primitives/src/head-tail-cap.ts:23-27`),
不是"只看前 N 行"。阈值:`CHAT_DIFF_MAX_LINES = 9`、`CHAT_READ_MAX_LINES = 8`、
`CHAT_SEARCH_MAX_LINES = 8`、`JsonBlock` 20000 字符;
**Chat 里的终端输出是 `maxLines={Infinity}`**(`ui-tool/.../ToolRow.tsx:262`)—— 不要自作主张加折叠。

**7. 跟随阈值 = 25px**(`ui-chat/src/client/chat/use-chat-reading.ts:7,252` 的 `FOLLOW_THRESHOLD + 1`):
上滚即失去跟随(`use-scroll-follow.ts:90-95`),触底即恢复(`use-chat-reading.ts:137-142`),
500ms 采样防抖,尊重 `prefers-reduced-motion`(Flutter 侧对应 `MediaQuery.disableAnimations`)。

**8. 安全边界(必须照搬)**:原始 HTML **当纯文本**(`markdown/render.tsx:333-335`,
"no HTML enters the DOM");链接白名单**只有 `http:` / `https:` / `mailto:`**(`render.tsx:53-68`)。
(手机侧的 `dsh_markdown.dart` 已经是"HTML 当纯文本",这条保持一致。)

## 手机侧的三个结构性缺口(读自己的代码得到的)

1. **`ChatItem` 的注释写着"UI 用它做 `==` 比较来决定要不要重建",但类里根本没有
   `operator ==` / `hashCode`**(`app/lib/model/chat_item.dart`)。于是每条 delta 都新建实例 ⇒
   `ListenableBuilder` 重建整棵树 ⇒ 每条可见的 `AssistantTurn` 都重跑 `MarkdownBody`
   (整段重解析 + 重排版)。**这是最影响手感的一条,也是投入产出比最高的一条。**
2. **没有分组 / 折叠层**:每张 `ToolCard` 都是独立大卡片,`chat_turns.dart` 里没有"过程组"这个概念。
3. **没有 DSH 的工具呈现层**:工具名落到默认值 `'工具'`、参数落到 JSON 键名堆
   (`app/lib/data/projection.dart:73,89,104` 三处 `?? '工具'`)。

## 参考项目的真实情况(别再假定它们是 Flutter)

- **`D:\sudy\github\rikkahub` 是 Kotlin Multiplatform / Jetpack Compose**(`settings.gradle.kts:36-49`,
  711 个 `.kt`,**没有 `pubspec.yaml`**)。
- **`D:\sudy\github\DEEIX-Chat` 是 Next.js 16 + React 19**(`apps/web/package.json`)。
- 结论:**没有一行能直接搬进 Dart**,能搬的是架构决策与数值阈值。

可搬且已量化的(全部零新依赖):

| 点 | 出处 | 值 |
|---|---|---|
| 块模型 + 分组 + 每块稳定 key | rikkahub `UIMessagePart.kt:73-216`、`ChatMessageCot.kt:46-84` | `finishedAt == null` 表示流式中 |
| 帧对齐节流(不是纯 debounce) | DEEIX `use-chat-stream-buffer.ts:9-13,171-185` | 文本 50ms / 思考 40ms,rAF + setTimeout 双机制 |
| 追赶模式 | 同上 `:45-50` | 积压 >1024 字符时每次 flush 256 而非 48 |
| 同引用短路 | 同上 `:237-245` | 无变化返回同一对象 |
| 代码高亮护栏 | rikkahub `Highlighter.kt:20,60`、`HighlightEngine.kt:44-46` | 长度 4096 不高亮;结果缓存;语法只编译一次 |
| 关连字 | `Highlighter.kt:75` | `'calt' 0, 'liga' 0, 'clig' 0`(高亮切分处不断裂) |
| 超长会话阈值 | `ChatSizeChecker.kt:18-19` | 768 节点 / 300k token,**双条件**才提示 |
| 工具载荷解析设界 | DEEIX `tool-result-presentation.ts:18-21` | 深度 24 / 节点 512 / 结果 64 / JSON 64KB |

**明确不要抄**:`MarkdownNew.kt` 的 markdown→HTML→jsoup 管线(重、且失败静默渲染空白)、
`streamdown`(15 个传递依赖)、把 `animateContentSize` 用在流式块上、`key(block.index)` 用在会变序的块上、
**聊天列表虚拟化** —— 三家(DSH/rikkahub/DEEIX)都不做,DSH 的对策就是"流式只重排末尾两块",
`dsh_markdown.dart` 文件末的"仍未做"第 2 条已经记着这条结论。

**一条必须偏离的**:DSH 浏览器端不虚拟化会话列表;Flutter 在几百轮的长会话上必须虚拟化
(`ListView.builder` 已经在用),但 DSH 的**语义锚点定位**(`use-chat-viewport.ts:225-234`
按 DOM 属性找锚点)依赖"所有行都在 DOM 里",所以做定位时要另存 `anchorKey → index` 映射。

## ④ 的验收判据(建议)

1. 一轮结束后,过程内容**折成一组**(组头带计数摘要),正文不被工具卡冲散。
2. 设置页那四档**真的改变默认折叠态**(现在改了等于没改)。
3. 流式期间只有**末尾少数几块**在重排:可用的判据是"给 `AssistantTurn` 加计数器,
   一条 20 块的回复在 100 个 delta 下的 rebuild 次数 ≈ 块数 × 常数,而不是 delta 数 × 块数"。
4. 工具行的名字是**分类后的中文**、参数是**人类摘要**,不再是 `工具` + JSON 键名。
5. 原始 HTML 仍是纯文本;超长内容头/尾各半 + 可全展开。

## 门禁(当前基线,改完必须全绿)

| 命令 | 当前 |
|---|---|
| `cd app; flutter test` | **654** |
| `cd app; dart analyze --fatal-infos lib test integration_test` | 0 |
| `cd app; dart format --output=none --set-exit-if-changed lib test integration_test` | 0 |
| `node app/tools/verify-platform-boundary.mjs` | 258 |
| `node mock/proto/tools/verify-icons.cjs` / `verify-tool-paths.mjs` | 96 图标 / 19 脚本 |
| `cd connector; pnpm exec tsc --noEmit && pnpm build && pnpm test` | 516(**改 `connector/src/**` 必须先 `pnpm build`**) |
| `node protocol/verify-{fixtures,loopback,vectors}.mjs` | 486 / 26 / 49 |
| CDP:`verify-proto`(13)/ `verify-authz`(18)/ `verify-settings`(28)/ `verify-tasks`(53)/ `verify-picker` | 全绿 |

CDP 起法:`pwsh -File mock/proto/tools/cdp.ps1 -Port 9400`,然后
`$env:CDP_URL='http://127.0.0.1:9400'; $env:NO_PROXY='127.0.0.1,localhost'`。
(2026-10-17 深夜起的那个 headless Chrome 可能还在,端口 9400。)

**项数的唯一出处是 `tools.md`;改断言必须做一次变异校验**(故意破坏不变量,确认**恰好**那一条红)。

## 纪律(违反会返工)

- **改基线要同步改落地端**:`mock/proto` 是交互基线,`app/` 是 Flutter 落地端,**不许两边漂**。
- **视觉/文案以 `docs/design-and-tech-plan.md` 为基线**:与文档冲突时**先改文档再改代码**;
  该文档有词数预算,**新增内容先下沉到专项文档**;文档里不写"以前/现在/不再"这类变迁叙述。
- **非平凡改动必须留决策笔记**(格式见 `decision-notes` 技能),代码与笔记**同批**;
  被取代的旧篇**结论不改**,标注被谁取代后移入 `archived/`(先例:部分取代时加一行
  `取代范围：` 说明哪些结论仍有效)。
- **Flutter 行为不许猜**:先 `node app/tools/flutter-api.mjs <符号>` 查本机 SDK 源码,
  引用写 `packages/flutter/lib/src/...:行号`;查不到按 `tools.md` 的「Flutter 行为查证」顺序继续。
- **DSH 行为不许猜**:给 `packages/...:行号`;查不到写「未找到」。
- **改源码只用编辑工具,不用 shell 字符串替换**(shell 出错是静默的,已两次把源文件写空)。
  提交前看 `git status` 完整清单,重点是**意外的文件**。
- **`.agents/notes/**` 禁止建总索引**。

## 真机验收(本轮卡在这,下次先解决)

本轮**装上了新构建但拿不到带数据的画面**:手机能连的路径全断了 ——
电脑侧 `8790` 没有监听(连接器的 `direct` 通道没起),4 个端点全拨不通。

- 直连要三件一起对(详见 `tools.md` 的「无线局域网直连」):profile 补丁
  (`~/.dsh/profiles/<profile>/cordis.patch.yml`,**gitignore,换机器要重配**)里
  `listenPort: 8790` + `listenHost: '0.0.0.0'`;重启后 `Get-NetTCPConnection -State Listen -LocalPort 8790`
  应是 `0.0.0.0`;连接器状态面的 `caps.direct` 必须是 `true`。
- **`~/.dsh/**` 这类工作区外的文件,编辑工具会"报成功但不落盘"** —— 用 shell 写,写完**当场回读 + 看 mtime**。
- 装 App 一律 `flutter build apk --debug` + `adb install -r`
  (**不要 `flutter install`**,它会先卸载旧 App,配对凭据在私有目录里,一卸全没)。
- **成本纪律**:`--profile` 只隔进程/插件/端口,`~/.dsh/{.credentials.yaml,sessions,storages}` 全局共用;
  不另起 profile;要专用会话就走「问 → 建(名字带 `[可删]`)→ 跑 → 用户确认后删」;
  每次跑之前报一句"这次约几个轮次"并拿到准;跑完把自起的进程杀干净。
- 想零成本看渲染:用**临时 golden 用例**按真机尺寸出图
  (`tester.view.physicalSize = Size(1080/(420/160), 2400/(420/160))` + `matchesGoldenFile`,
  `flutter test --update-goldens`)。注意测试环境**没有中文字形**,文字会渲染成方块,
  只能验**结构**;验文案用 widget 断言。

## 相关文件(入口)

- 手机端:`app/lib/ui/chat_page.dart`(2425 行,主页面)、`app/lib/ui/chat_turns.dart`(消息渲染)、
  `app/lib/ui/dsh_markdown.dart`(Markdown + 代码块)、`app/lib/model/chat_item.dart`(领域模型)、
  `app/lib/data/projection.dart`(事件→条目投影)、`app/lib/data/app_model.dart`。
- 连接器:`connector/src/handlers.ts`(方法表)、`connector/src/dsh/`(各适配器)、
  `connector/src/protocol/methods.ts`(`METHODS` 数组)。
- 原型:`mock/proto/{index.html,styles.css,app.js,interactions.js}` + `tools/verify-*.mjs`。
- 契约:`docs/subsystems/remote-channel.md` §5.7(方法表)、
  `docs/subsystems/app-channel-client.md` §7(渲染性能对策与"仍未做")。

---

## 提示词结束

---
