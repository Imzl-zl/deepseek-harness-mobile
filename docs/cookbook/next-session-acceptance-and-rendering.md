# 新会话提示词:真机验收 + ④ 会话渲染对齐 DSH

> 上一份(`next-session-home-and-rendering.md`,已 git mv 成本文件)里的四条反馈,
> **前两条(统计条单行横滚 / 顶栏收成一行)与 ③(连接后那一屏 = DSH 新会话页)
> 都已落地并全绿**,commit `6a9249b`。别再照它跑。
> 本份只做两件事:**先在真机上验收** ①②③(用户刚换了局域网),再开 ④。

## 起手第一步(必做)

读这些,并**核对被引用的 DSH 行号**(行号会漂;对不上就改正,别照抄):

1. `memory.md` + `tools.md` —— 当前门禁基线、坑点、真机装法。
2. `docs/design-and-tech-plan.md` §7.2 / §7.4 / §7.8(会话页、统计条、顶栏三段)。
3. `docs/subsystems/blank-session-hero.md` —— ③ 的规格(这一轮刚写的)。
4. `.agents/notes/implemented/` 里最近三篇:`2026-10-17-blank-session-hero.md`、
   `2026-10-17-icon-pipeline-fish-and-format-stability.md`、
   `2026-10-17-topbar-single-row-and-stats-scroll.md`。
5. DSH 源码 `D:\sudy\github\deepseek-harness`(只读)。

---

# 第一件事:真机验收(用户换了局域网,先确认还连得上)

**为什么排在最前**:①②③ 的证据全是单测 + CDP 原型 + 契约断言,**没有一张带数据的真机画面**。
用户刚换了局域网,电脑 IP 大概率变了,而这正是"端点自愈"那条设计的考场。

## 连之前先确认三件一起对(详见 `tools.md` 的「无线局域网直连」)

1. profile 补丁 `~/.dsh/profiles/<profile>/cordis.patch.yml`(**gitignore,换机器要重配**)里
   连接器 `listenPort: 8790` + `listenHost: '0.0.0.0'`;
2. 重启后 `Get-NetTCPConnection -State Listen -LocalPort 8790` 应显示 **`0.0.0.0`**;
3. 连接器状态面 `caps.direct` 必须是 `true`
   (`(Invoke-RestMethod http://127.0.0.1:<port>/api/dsh-mobile/status -WebSession $sess).caps.direct`)；
4. **手机侧选路必须真的出网卡**：`adb shell 'ip route get <电脑IP>'` 要落到 `dev wlan0`。
   若返回 `local <电脑IP> … dev lo`，说明手机被加过 `<电脑IP>/32`（常见搭配
   `iptables -t nat` 的 `REDIRECT`），于是"连电脑"变成"连自己"—— 表现为 1-2ms 内
   `Connection refused`、电脑侧 `SynReceived` 为空、抓包一个 SYN 都没有。
   三行定位与清理见 `tools.md` 的「手机'连不上电脑'先查手机有没有把电脑 IP 劫持到本机」。

**换局域网的后果**:手机落盘学到的 direct 端点(`192.168.x.x:8790`)已失效,第一次得先经
relay 连上,`endpoint.describe` 才会把新地址教给它并按"direct 先于 relay"并入端点表。
所以**第一次连不上不等于坏了** —— 去看设置页的端点列表是"拨不通 + 原因"还是"根本没这条"。

## 验收清单(按顺序,每步都要看到画面)

| # | 动作 | 期望 |
|---|---|---|
| 1 | 冷启动 App | 端点拨号 → 连上;若旧 direct 失败,应自动回落 relay 再自愈 |
| 2 | 连上后第一屏 | **落到 blank 会话 → hero**:鱼 + 「探索未至之境」+ 「预览版」+ 工作区 chip + 模式 chip |
| 3 | 看输入框占位符 | 是「描述你想要构建的内容, / 调用指令, @ 文件或对话」**不是**普通那句 |
| 4 | 点工作区 chip | 弹出工作区清单(来自 `workspace.list`),选另一个 → **真的建了一个该工作区的会话**并落进去 |
| 5 | 点模式 chip | 弹出四档(标准/PTC/极简/创造),选另一个 → 同上;名字是**中文**(内置走本地字典) |
| 6 | 发一条消息 | 电脑侧会话里出现;hero 让位给消息流;统计条三项有真数 |
| 7 | 顶栏 | 计数 chip 与标题同一行、只有"图标 + 计数";标题 ≤140px/13px |
| 8 | 统计条 | 单行、可横滚、轮次格是「N 轮 M 步」(没有「第」) |
| 9 | 断网再恢复 | 端点全失效时空态说"拨不通"而不是"还没有会话";恢复后自动重连 |

**截图存 `mock/proto/shots/`**(该目录不入库),并把"哪一步和期望不符"写进回报。

## 成本纪律(每次跑之前报一句"这次约几个轮次"并拿到准)

- `~/.dsh/.credentials.yaml`、`sessions/`、`storages/` **全局共用**,`--profile` 只隔进程;
- 要专用会话走「问 → 建(名字带 `[可删]`)→ 跑 → 用户确认后删」;
- 装 App 一律 `flutter build apk --debug` + `adb install -r`
  (**不要 `flutter install`**,它会先卸载旧 App,配对凭据在私有目录里,一卸全没);
- `flutter test integration_test/` **跑完会卸载 App**,手机的 sqflite 被清 ⇒ 连接器重放整段历史。

---

# 第二件事:④ 会话页面的渲染与 DSH 差距很大

> 用户原话:"这个渲染其实可以自己做,甚至做得更好的",点名参考 rikkahub / DEEIX-Chat /
> deepseek-harness。**前一轮已查实:rikkahub 是 Kotlin/Compose、DEEIX-Chat 是 Next.js,
> 没有一行能直接搬进 Dart**,能搬的只有架构决策与数值阈值。

## 一眼能看出的差距(同一会话、同一时刻的真机对照)

| | 电脑 DSH Web | 手机 |
|---|---|---|
| 工具调用 | `> 运行命令 · Commit handoff-2 and memory update, not pushing` —— **一行**、无卡片边框 | `✅ 工具 role, source, toolCallId, conten… ›` —— **52dp 暖色卡片**,名字退回默认「工具」,参数是 JSON 键名堆 |
| 思考 | `思考 · Commit 成功:` 一行弱化文字 | `思考过程 ›` 一张带边框卡片 |
| 助手头 | **没有**头像/「助手」行 | `✦ 助手` + 头像 |
| 统计条 | 一行居中、无底色 pill | (已改成一行横滚) |

## DSH 的结构(照这个重建;行号 2026-10-17 重新核对过)

**1. 三级管线**:事件 → **Node**(16 种渲染 kind)→ **过程组** → ViewSnapshot → 组件。
聚合在 `packages/client/ui-conversation/src/client/conversation/assembler.ts:174`;
业务定义在 `packages/client/ui-chat/src/client/conversation-nodes/register.ts:22-38`
(2026-10-17 核对:该区间是 15 条**注册语句**,含 1 个 view 构建器 + 1 个 group 定义;
真实渲染 kind 是 **16** 个 —— message.ts 贡献 4、command.ts 贡献 2,其余各 1)。
**完整规格书是 `ui-chat/src/client/conversation-nodes/README.md`(331 行)——
先把它译成中文规格入 `docs/`,这是移动端最省力的真值源。**

**2. 折叠四档由单一策略表决定**(`ui-chat/src/client/presentation-policy.ts:23-52`):

| 模式 | foldCompletedTurns | stepGrouping | liveProcessDetail | settledReasoningPreview |
|---|---|---|---|---|
| compact | true | collapsed | false | false |
| standard(桌面默认) | true | collapsed | true | true |
| detailed(非桌面 Web 默认) | true | history | true | true |
| verbose | false | none | false | true |

手机**已经有这四个设置项**(`model/preferences.dart` 的 `TranscriptView`:简洁/标准/详细/完全展开,
文案照 `ui-chat/src/client/locale.ts:109-112`;任务书旧写的 `:103-108` 是标题与收起时机文案),
但**只传了一个 `autoOpenToolDetail` 布尔**。
把这 4×4 表直接落成 Dart 枚举,别在 UI 里散落判断。

**3. 分组**(`ui-chat/src/client/conversation-nodes/process-groups.ts`):
⚠ **旧任务书里的 `INDEPENDENT` 名单已经不存在了**(全仓搜不到)—— 现在"是不是独立根"
由 `isAtOrOutside(node, 'process')` 判定(`:153`)。仍然成立的几条:
`turn-process` 控制行不切断;`assistant-step` 带 reasoning 入组(`:158`)、是回复则关组(`:159-162`);
其余(含工具)入组(`:163`)。"是回复"判据 `hasAssistantReplyContent`
(`contract/assistant-content.ts:9-15`):text 非空白 / image / 其他可见块 ——
**reasoning 与 tool-call 不算回复**。组标题 = 计数排名前 3 + 「等」
(`ui-chat/src/client/chat/step-process.ts:11-27`,README 的排序规则在 `:251`)。

**4. 工具名分类表**(`conversation-nodes/README.md:257-271`,**13 类**):
`read` / `readImage` / `search`(grep、glob、后缀 `_inspect`)/ `write` / `edit`(edit、apply_patch)/
`commands`(bash、pwsh、exec_command、write_stdin、前缀 `terminal_`)/ `code`(run_code)/
`webSearch` / `webFetch` / `subagents`(前缀 `subagent_`)/ `plan`(todo_write、create_goal、
update_goal、get_goal)/ `questions`(ask_user_question、request_user_input)/ **其余归 `tools`**。
分类用的是**记录下来的工具名原样**:不转小写、不剥命名空间、不按参数猜(`README.md:255`)。
分类函数名是 `activity`(`process-activity.ts:8-22`,兜底 `return 'tools'`)。
live detail 字段优先级 `README.md:311`(22 个候选字段按序),**截到 160 grapheme** `README.md:331`。

**5. 流式**:持久事件里**没有 `message/delta`**(权威定义 `core/session/src/types.ts:282`
的 `SessionEventMap`;全仓 grep `message/delta` 于 `packages/core/session` = 0 命中);
瞬态走 `assistant/live-chunk`(`api/session-controller/src/client/contract/events.ts:7`),
用**分数 seq** 插在持久 seq 之间
(`api/session-controller/src/client/sessions/assistant-stream.ts:88` 与 `:158`;
任务书旧写的 `ui-chat/.../chat/assistant-stream.ts` **不存在**),step 结束时被
`assistant/message` **整体替换**(`events.ts:181-196` 的 `settleAssistant`;
"同一 step"的判定是 turn+step 相等,成功 message 留到 `step/end` 才退役瞬时行)。
连接器若同时转发两者,**必须实现同一条替换规则**,
否则出重复气泡。Markdown 侧:**冻结除末尾两块以外的块、只重解析尾部**
(`ui-primitives/src/markdown/incremental.ts:38` 的 `UNSTABLE_TAIL_BLOCKS = 2`),
冻结键是**绝对源码 offset**。

**6. 截断是头/尾各半 + 可全展开**(`ui-primitives/src/head-tail-cap.ts:23-27`),
不是"只看前 N 行"。阈值现在在 `ui-tool` 的 models 里(目录是 `client/tool/models/`):
`CHAT_DIFF_MAX_LINES = 9`(`ui-tool/src/client/tool/models/diff-card-model.ts:8`)、
`CHAT_READ_MAX_LINES = 8`(同目录 `read-card-model.ts:17`)、
`CHAT_SEARCH_MAX_LINES = 8`(同目录 `search-card-model.ts:12`);
primitive 各块默认 16,Chat 行覆盖成上表三值。
**Chat 里的终端输出是 `maxLines={Infinity}`**(`ui-tool/.../tool/components/ToolRow.tsx:266`)——
不要自作主张加折叠。**「`JsonBlock` 20000 字符」本轮核实时仍然存在**
(`ui-primitives/src/markdown/JsonBlock.tsx:6` 的 `MAX_CHARS = 20_000`,:26 应用),
旧任务书写的"未找到"是错的,照 20000 用。

**7. 跟随阈值 = 24**(`ui-chat/src/client/chat/use-chat-reading.ts:7` 的 `FOLLOW_THRESHOLD`,
判定用 `+1`,即 25px 容差):上滚即失去跟随(`use-scroll-follow.ts:90-95` 的 `sample`),
触底即恢复(`use-chat-reading.ts` 的 `onScroll :158-166`,距底 <1px 即 `followTail`;
`restore :120-133` 同判据),500ms 采样防抖(同文件 `:8`),
尊重 `prefers-reduced-motion`(Flutter 侧对应 `MediaQuery.disableAnimations`)。

**8. 安全边界(必须照搬)**:原始 HTML **当纯文本**(`ui-primitives/src/markdown/render.tsx:333-335`,
原注释 "No HTML parser enters the pipeline");链接白名单**只有 `http:` / `https:` / `mailto:`**
(`render.tsx:53-68` 的 `sanitizeUrl`)。(手机侧的 `dsh_markdown.dart` 已经是"HTML 当纯文本",保持一致。)

## 手机侧的三个结构性缺口(读自己的代码得到的)

1. **`ChatItem` 的注释写着"UI 用它做 `==` 比较来决定要不要重建",但类里根本没有
   `operator ==` / `hashCode`**(`app/lib/model/chat_item.dart`)。于是每条 delta 都新建实例
   ⇒ `ListenableBuilder` 重建整棵树 ⇒ 每条可见的 `AssistantTurn` 都重跑 `MarkdownBody`
   (整段重解析 + 重排版)。**这是最影响手感的一条,也是投入产出比最高的一条。**
2. **没有分组 / 折叠层**:每张 `ToolCard` 都是独立大卡片,`chat_turns.dart` 里没有"过程组"这个概念。
3. **没有 DSH 的工具呈现层**:工具名落到默认值 `'工具'`、参数落到 JSON 键名堆
   (`app/lib/data/projection.dart` 三处 `?? '工具'`)。

## 参考项目的真实情况(别再假定它们是 Flutter)

- `D:\sudy\github\rikkahub` 是 Kotlin Multiplatform / Jetpack Compose
  (`settings.gradle.kts:36-49`,711 个 `.kt`,**没有 `pubspec.yaml`**)。
- `D:\sudy\github\DEEIX-Chat` 是 Next.js 16 + React 19(`apps/web/package.json`)。
- 结论:**没有一行能直接搬进 Dart**,能搬的是架构决策与数值阈值。

可搬且已量化的(行号 2026-10-17 重新核过;**全部零新依赖**):

| 点 | 出处 | 值 |
|---|---|---|
| 块模型 + 每块稳定 key | rikkahub `app/src/main/java/me/rerere/rikkahub/ui/pages/chat/` 下的消息模型 | `finishedAt == null` 表示流式中 |
| 代码高亮护栏 | rikkahub `highlight/src/main/java/me/rerere/highlight/Highlighter.kt:20`、`:61` | 长度 **4096** 不高亮;结果缓存 |
| 关连字 | 同上 `:75` | `'calt' 0, 'liga' 0, 'clig' 0`(高亮切分处不断裂) |
| 超长会话阈值 | rikkahub `.../ui/pages/chat/ChatSizeChecker.kt:18-19` | **768 节点 / 300k token,双条件**才提示 |
| 帧对齐节流(不是纯 debounce) | DEEIX `apps/web/features/chat/hooks/use-chat-stream-buffer.ts:9-13` | 文本 **50ms** / 思考 **40ms** |
| 追赶模式 | 同上 `:45-50`(常量在 `:12-13`) | 积压 **>1024** 字符时每次 flush **256** 而非 48 |
| 工具载荷解析设界 | DEEIX `apps/web/features/chat/model/tool-result-presentation.ts:18-21` | 深度 **24** / 节点 **512** / 结果 **64** / JSON **64KB** |

**明确不要抄**:rikkahub 的 markdown→HTML→jsoup 管线(重、且失败静默渲染空白)、
`streamdown`(15 个传递依赖)、把 `animateContentSize` 用在流式块上、
`key(block.index)` 用在会变序的块上、**聊天列表虚拟化** —— 三家(DSH/rikkahub/DEEIX)
都不做,DSH 的对策就是"流式只重排末尾两块",`dsh_markdown.dart` 文件末的"仍未做"第 2 条
已经记着这条结论。

**一条必须偏离的**:DSH 浏览器端不虚拟化会话列表;Flutter 在几百轮的长会话上必须虚拟化
(`ListView.builder` 已经在用),但 DSH 的**语义锚点定位**(`use-chat-viewport.ts:225-234`
按 DOM 属性找锚点)依赖"所有行都在 DOM 里",所以做定位时要另存 `anchorKey → index` 映射。

## ④ 的验收判据(建议)

1. 一轮结束后,过程内容**折成一组**(组头带计数摘要),正文不被工具卡冲散。
2. 设置页那四档**真的改变默认折叠态**(现在改了等于没改)。
3. 流式期间只有**末尾少数几块**在重排:判据是"给 `AssistantTurn` 加计数器,
   一条 20 块的回复在 100 个 delta 下的 rebuild 次数 ≈ 块数 × 常数,而不是 delta 数 × 块数"。
4. 工具行的名字是**分类后的中文**、参数是**人类摘要**,不再是 `工具` + JSON 键名。
5. 原始 HTML 仍是纯文本;超长内容头/尾各半 + 可全展开。

---

## 插件边界(结论仍有效,压缩版)

- **插件提供的「能力」跟着走**:插件装的是工具 / 命令 / 服务 / agent 预设,手机发一句话、
  电脑上的 agent 用它跑,结果照形状回传 —— 手机**不需要知道插件的存在**。
- **插件自己画的界面传不过来(架构事实)**:插件 UI 是 `dsh.client` 声明的**浏览器 bundle**,
  线上没有任何"UI 描述",只有代码 —— 手机要显示它 = 手机要跑 DSH 的 Web 客户端。
  完整论证见 `docs/plugin-and-jobs-notes.md` A.6(每条带行号)。
- **中间地带(结构化数据,手机能做,连接器现在一个都没接)**:`pluginInventory.list()`、
  `pluginManager.listBundles()`、行级与 bundle 级启停、安装日志流。
- **配置只有 `.volatile()` 字段过线**,其余只能显示"需在电脑上编辑"。
  **别自己从零做通用 schema 渲染器** —— DSH 两次否决过。

## 门禁(当前基线,改完必须全绿)

| 命令 | 当前 |
|---|---|
| `cd app; flutter test` | **687** |
| `cd app; dart analyze --fatal-infos lib test integration_test` | 0 |
| `cd app; dart format --output=none --set-exit-if-changed lib test integration_test` | 0 |
| `node app/tools/verify-platform-boundary.mjs` | **266** |
| `node mock/proto/tools/verify-icons.cjs` / `verify-tool-paths.mjs` | 100 图标 / 19 脚本 |
| `cd connector; pnpm exec tsc --noEmit && pnpm build && pnpm test` | **522**(改 `connector/src/**` 必须先 `pnpm build`) |
| `node protocol/verify-{fixtures,loopback,vectors}.mjs` | 486 / 26 / 49 |
| CDP:`verify-proto`(**31**)/ `verify-authz`(18)/ `verify-settings`(28)/ `verify-tasks`(53)/ `verify-picker` | 全绿 |

CDP 起法:`pwsh -File mock/proto/tools/cdp.ps1 -Port 9400`,然后
`$env:CDP_URL='http://127.0.0.1:9400'; $env:NO_PROXY='127.0.0.1,localhost'`。

**项数的唯一出处是 `tools.md`;改断言必须做一次变异校验**(故意破坏不变量,确认**恰好**那一条红)。

## 纪律(违反会返工)

- **改基线要同步改落地端**:`mock/proto` 是交互基线,`app/` 是 Flutter 落地端,不许两边漂。
- **视觉/文案以 `docs/design-and-tech-plan.md` 为基线**:与文档冲突时**先改文档再改代码**;
  该文档**已超词数预算**(约 3418 / 上限 3000),新增内容**一律先下沉到专项文档**。
- **非平凡改动必须留决策笔记**(格式见 `decision-notes` 技能),代码与笔记**同批**。
- **Flutter 行为不许猜**:先 `node app/tools/flutter-api.mjs <符号>` 查本机 SDK 源码,
  引用写 `packages/flutter/lib/src/...:行号`。
- **DSH 行为不许猜**:给 `packages/...:行号`;查不到写「未找到」(本份已示范两处:
  `INDEPENDENT` 名单被重构没了、`JsonBlock` 20000 没搜到)。
- **改源码只用编辑工具,不用 shell 字符串替换**;提交前看 `git status` 完整清单,
  重点是**意外的文件**。
- **提交信息里避免反引号**(pwsh 会当 Unicode 转义,整条命令在解析阶段就失败);
  长提交信息写进临时文件再用 `git commit -F`。

## 提示词结束
