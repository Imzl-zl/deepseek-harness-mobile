# 会话页渲染：剩余问题清单（逐条标证据状态）

Status: proposed（**清单，不是决定**；每条都写了"证据状态"，未取证的不许先改）

用户 2026-10-20 晚：「其他的也有问题还是啥。有问题都记录一下，开新会话优化」

## 已修（同日，留档以免重复排查）

| 问题 | 依据 | 笔记 |
|---|---|---|
| 代码块没有底色（用 `bgBase`，与页面同色） | `CodeBlock.module.css:15-21` | `implemented/2026-10-20-markdown-codeblock-and-list-styling.md` |
| 代码块圆角 `sm`（应为 `lg`）、多一圈 border | 同上（`border-radius: radius-lg`、无 border） | 同上 |
| 代码块缺 16px 外边距 | 同上（`margin: 16px 0`） | 同上 |
| 代码块 banner 底色没接 | `CodeBlock.module.css:5,38` + `design-platform.css:229,347` | 同上 |
| 列表 marker 用正文色（应 `label-secondary`） | `MarkdownText.module.css:111-118` | 同上 |
| 行内 HTML 标签原样露出 | 探针实测 + `markdown-7.3.1` ExtensionSet | `implemented/2026-10-20-markdown-coverage-and-inline-html.md` |
| 空态文字折行后左对齐 | — | `implemented/2026-10-20-empty-state-and-bottom-strip.md` |
| 底部一条 `sidebar` 色的缝 | 真机像素 | 同上 |
| 系统栏不跟主题 | SDK 注释（`targetSdk 36` 忽略 `SystemUiMode`） | 同上 |

## 未修 / 未验（**本清单要解决的就是这些**）

> **2026-10-20 第二轮进度**：1 / 3 / 5 / 6 / 7 已改（依据与断言见
> `implemented/2026-10-20-render-alignment-to-dsh-spec.md`）；2 / 8 已判定
> "不是缺陷、不改"；4 仍需真机（阶段二）。

1. **用户消息是纯 `Text`**（`chat_turns.dart:110-117`）——**已核对：与 DSH 一致，不改**。
   DSH 的用户正文走 `conversation.user.text` → `UserTextRun`
   （`packages/client/ui-primitives/src/user-text.tsx:18-20`，"without Markdown or
   reference recognition"），气泡只负责 `white-space: pre-wrap`。我们少的只是
   `@文件` / `/skill` 引用 chip（那是 `ui-reference` / `ui-skill` 的匹配器，未接）。
   断言：`test/render_alignment_test.dart` 的"用户消息：DSH 不跑 Markdown"。

2. **附件计数文案「N 个附件（手机上不显示）」**（`chat_turns.dart:127-134`）
   —— 文本诚实（收来的事件只带引用不带字节，要 `session/attachment` 才能读），
   但"手机上不显示"作为长期形态很弱。是否要缩略图取决于要不要接
   `session/attachment` 方法（那是新方法面）。
   **证据状态**：事实清楚，**产品取舍未定**（本轮不改）。

3. **工具卡内部未逐一比对** —— **已改**：正文按 `.ioCard` / `.ioSection` / `.ioText`
   （11/16 等宽、`label-secondary`、上限 150 + 内滚、内边距 12×16），
   不再是 `ToolDetails.module.css` 的 `.root`（那是结构化字段卡）。
   断言：`render_alignment_test.dart` 的"工具卡展开正文"。

4. **斜杠命令卡（`CommandCard`）未逐一比对** —— 示例数据里没有 `CommandItem`，
   真机上这一屏还没出现过（端到端验收也列着它）。
   **证据状态**：未验（demo 无样本 + 未配对）—— 阶段二看。

5. **`_CollapsibleNote`（"系统提示词"那行）是纯 `SelectableText`**
   —— **已改**：行照 `DisclosureRow`（行高 24→36 的触屏偏离、标题 13/24、
   `label-tertiary`、图标 14），正文分两种：思考 = compact Markdown（13/20、
   `label-tertiary`、收起时显示首行摘要），系统提示词 / 上下文注入 = 11/16 等宽
   + 上限 141 的滚动区（`ContextInjectionRow.module.css:50-64`）。
   系统提示词的图标改成 `browse`（`SystemPromptRow.tsx:30`）。
   断言：`message_rendering_test.dart` 的"思考过程块"两条 +
   `render_alignment_test.dart` 的"系统提示词"两条。

6. **表格在窄屏可能横向溢出** —— **已改**：`tableColumnWidth` 用
   `IntrinsicColumnWidth`（`flutter_markdown_plus-1.0.12/lib/src/builder.dart:447-463`
   只在两种列宽下才套横向滚动），于是宽表按自然宽度横滚、不再被压成窄列；
   边框改成只有行分隔线、表头左对齐、单元格 10×16（`MarkdownText.module.css:192-262`）。
   **已知偏离**：窄表不铺满（DSH 三列以内会 `width:100%`），
   且没有 `min-width:100px` / `max-width:30vw` 的等价物。
   断言：`render_alignment_test.dart` 的"宽表要有横向出路"（360 视口）。

7. **流式文本用 Markdown 渲染**（`chat_page.dart:2684`）—— **已核：不是缺陷**。
   DSH 的流式 arm 同样把未闭合围栏渲染成代码块并逐块冻结
   （`ui-primitives/src/markdown/incremental.ts:10-14`）。本轮做的是两件相关的事：
   ① `normalizeInlineHtml` 改成逐行扫描围栏（`~~~` 也是围栏，未闭合一直算围栏内，
   否则会改写围栏内的源码）；② 流式尾条目与持久条目共用 `AssistantHead` + `DshMarkdown`，
   流结束换条目时不再跳一下。
   断言：`markdown_coverage_test.dart` 的"流式：未闭合围栏"两条 + 围栏扫描四条。

8. **`normalizeInlineHtml` 只处理行内** —— **已判定：不改**。DSH 把原始 HTML 当
   **字面文本**显示（`ui-primitives/src/markdown/render.tsx:333-335`："No HTML parser
   enters the pipeline: raw HTML stays literal text"），所以"块级 HTML 也渲染"
   不是 DSH 的行为，我们不该做。我们的偏离（四种行内标签归一、其余去标签保文字）
   已写进 `docs/subsystems/app-channel-client.md` §4.1 的偏离表。

## 隔离实例真机验收（2026-10-20 晚）新发现的两条 —— **下一轮第一、二项**

9. **一轮没有"轮组"，与 DSH Web 结构不同（用户当场指出）**。
   同一轮在两端：
   - DSH Web：`已完成，用时 1 分 7 秒 ⌃` 一个**可展开的轮组**，组内再分
     `已完成分析` / `执行了命令`；上下文注入、思考、工具调用、正文都在组里，
     收起时只剩摘要（`ui-chat/src/client/locale.ts:35,64-65,150-151`、
     `conversation-nodes/step-process.ts`、`TurnProcessNodeView.tsx`）。
   - 手机：**平铺**。上下文注入三行、思考行、工具卡、正文、轮摘要各占一块；
     `TurnProcessRow` 只是"一轮末尾的一行收口"，不收任何东西
     （`chat_turns.dart` 里那句"不做收起该轮 —— 那是组级交互，而我们没有 turn 组"）。

   要补的是**一层结构**（不是样式）：事件里的 `turn`/`step` 进投影 → 条目带轮号 →
   列表按轮分组 → 组头复用 `TurnProcessRow`（加展开/收起，默认收起过程、正文不藏）→
   文案换成 DSH 的 `已完成，用时 ` / `已完成` / `已完成分析` / `N 次工具调用`。
   代价：列表结构、`_keysById` 的跳转语义、以及一组"收起只剩摘要"的测试。

10. **`ask_user_question` 在真机上直接失败**（用户当场指出"提问报错"）。
    模型调了 `ask_user_question`，工具结果是我们的原文：
    `提问缺少 callId：无法为手机答复建立稳定身份`
    （`connector/src/interaction-claims.ts:255`）。
    根因：**DSH 的 ask 载荷里 `wait` 是可选的** —— "absent for indefinite waits"
    （`packages/interaction/user-questions/src/types.ts:140-145`），而未计时的
    `ask_user_question` 正是 indefinite 那种；`callId` 只出现在
    `tool/call.callId` 与 `userQuestions` 投影的 `active[].callId` 上
    （`types.ts:76,142`）。我们只在 `request.wait?.callId` 上取
    （`connector/src/dsh/interactions.ts:205`），于是**所有未计时的提问都答不了**。
    修法方向（**下一轮照这个做**）：`userQuestions` 投影的 `active[].callId`
    就是权威身份，而 `sessionProjections` 已经是连接器的依赖
    （`connector/src/dsh/questions.ts:76-136` 已在读它）。所以：
    1. `InteractionDeps` 加一个端口 `resolveQuestionCallId(dshSessionId, questions)`
       （`connector/src/dsh/interactions.ts:88-93` 那一层，保持"内核不 import DSH"）；
    2. `index.ts` 用它读 `sessionProjections.stateOf(session,'userQuestions').active`，
       按问题 id 集合配对（多个 active 时取**问题 id 完全一致**的那条，配不上就 fail-closed
       抛原来那句，绝不猜）；
    3. `request.wait?.callId` 仍然优先（timed 提问有它，直接信它）；
    4. `connector/tests/` 钉两条：**未计时提问能答**、**配不上时仍 fail-closed**。

11. **电脑侧停一会儿，手机会把"连不上"当成"这台电脑不认我"，清掉配对回配对页**。
    2026-10-20 实测：把隔离实例（中转 + DSH）停掉约 2 分钟再起，手机已经**自动回到配对页**
    并显示「这台电脑已不再认可本机」—— 而电脑侧的 devices 表里那台设备还在、没吊销
    （`GET /api/dsh-mobile/status` 能看到 `paired:1`）。
    链路：中转**进程重启后名册是空的**（`relay/src/device-registry.ts:85-94` 的
    `authenticate` 对"没见过"回 `undefined`），连接器要等 `onConnected: publishDevices`
    （`connector/src/index.ts:890`）把名册重新报上去；在这个窗口里设备换票拿到
    **401**（`relay/src/http-face.ts:59-61`），而 App 把 401 归成
    `notPaired`（`app/lib/core/pairing_client.dart:78-84`）⇒ 终态 ⇒ 清凭据
    （`app/lib/core/sync_client_impl.dart:311-319` 的注释写明这是有意的终态）。
    中转其实已经区分了"电脑离线"（`relay/src/http-face.ts:70`，回 503），
    但它区分不了"从没见过"与"被吊销"。
    两个修法方向（**下一轮定一个**）：
    - 中转侧：名册行**持久化**（或在"连接器未注册过"时回 503 + `retry-after`），
      让"未知设备"不再等于"需要重配"；
    - App 侧：401 只在**连接器明确拒绝**（握手 close 4003 / `protocol/revoked`）时才终态，
      换票 401 先按可重试处理（带次数上限），避免一次中转重启就丢配对。
    判据：停掉电脑侧 → 重启 → 手机**不需要重扫**、自动连回。


## 不算问题（用户 2026-10-20 纠正）

**「示例数据下轨迹页是空态」不是产品缺陷。** 示例数据只是开发辅助，
它显示不出某屏 ≠ 功能坏了。更根本的是：**评估手段不该反过来塑造产品**。
要验真实行为就走**隔离实例**（见下），不靠补示例数据。

示例数据本身可只留给测试用；它在生产路径上只由「看示例数据」这一个
显式动作触发，不会冒充真实数据，所以暂时留着没有害处 —— 但**不必为它加样本**。

## 隔离实例这一轮的验收状态（2026-10-20 22:00）

起法（已跑通，下一轮照抄）：`$env:DSH_HOME='D:\tmp\dsh-e2e'` → 从 web 模板建 profile
→ `dsh plugin --profile mobile-e2e add <connector>` → 中转 `node relay/src/main.ts --config
D:\tmp\dsh-e2e\relay.config.json` → `dsh --profile mobile-e2e --port 63900 --no-open`
→ 出码用 `D:\tmp\dsh-e2e\pair-payload.mjs`（把 `POST /api/dsh-mobile/pair` 的 svg 解回
payload，因为该端点**只回 svg 不回 payload**，`connector/src/admin/routes.ts:241-244`）
→ 手机粘到配对页的输入框（IME 会弹"剪贴板与常用语"，点"不同意"后输入框仍有焦点）。

| 项 | 状态 |
|---|---|
| 流式正文边生成边显示 | **已验**（截图：正文逐段长出来） |
| 代码块 / banner / 复制 | **已验** |
| 宽表横向滚动 | **已验**（六列，左滑看到 Orbit/Notes） |
| 工具卡 + 展开 | **已验**（`pwsh` 卡，展开区 11/16 等宽） |
| 轮摘要真实用时与计数 | **已验**（`第 4 轮 12 分 12 秒 · 6 条消息 · 5 次工具`） |
| 上下文注入三行 | **已验**（修复后是 `上下文注入 · runtime-context` 等三行） |
| 审批接管卡 + 允许一次 | **已验**（真跑通一次越权写入，ACL 脚本落盘） |
| 斜杠命令 | **半验**：`/goal` 被当成普通消息发出去了（不是命令卡），见下 |
| 附件（＋→照片→芯片→发送→计数） | **未验**：两次都被系统"剪贴板与常用语"对话框打断 |
| 历史翻页 | **未验**：快照页 100 条（`connector/src/protocol/recovery.ts:113-115`），本轮没造出那么多真历史 |
| 异常结局 / 重试 / 压缩标记 | **未验**：需要制造失败/重试/压缩，本轮没做 |

**斜杠命令那条要查**（已查清，2026-10-20 23:10）：`/goal finish the render acceptance`
发出去后模型回了一句 "The user typed /goal …" —— 它是被当成**普通用户消息**发的。
根因不在渲染：DSH 的命令执行面是 `commands.execute(agent, line)`
（`packages/interaction/commands/src/index.ts:360-367`，里面才是
`parseCommand(line)` `:125-128`），而**我们的方法面没有这个命令**
（`connector/src/protocol/methods.ts` 只有 `permission.switch` 那条"内部拼
`/permission <preset>`"的路，见同文件 `:70` 的注释）。所以：
- `/` 开头的输入走 `session.prompt` ⇒ 模型看到的是文本，不会有 `command/run`；
- `CommandCard` 只会在**电脑侧执行过命令**时出现（例如 Web 里敲 `/goal`，
  或手机切权限触发的 `/permission`），手机自己发不了命令。

下一轮要做的：加一条 `command.execute`（幂等键与 `session.prompt` 同款），
手机侧把 `/` 开头的输入走它、并把返回的 `CommandResult` 呈现出来
（DSH 的 `CommandResult` 只有 text，`types.ts:34`）。**这与"命令卡渲染"是两件事**，
卡片已经在单测里钉住（`command_item_test.dart`）。

## 端到端验收：起隔离实例（可行，已查实）

`DSH_HOME` 是官方支持的数据根覆盖（`packages/util/home-paths/src/index.ts:17,135`，
`resolveDshHome()` 优先级 = 显式配置 → `$DSH_HOME` → `~/.dsh`）。
设 `$env:DSH_HOME='<临时目录>'` 再启动，credentials / sessions / storages /
attachments 全落在那里，**不碰用户的 `~/.dsh`** —— 于是可以放心配对、建会话、
跑一轮，把上面这些「未验」逐条变成「已验」。

注意：新根里没有装连接器，得先把它装进那个实例（`dsh plugin install …` 之类，
具体命令见 `docs/cookbook/channel-bootstrap.md`）；这也正是这条路径一直没走的
真实成本 —— 不是"不允许"，是"要装一遍"。

## 排查方法（给下一轮，别重新发明）

- **视觉问题没有测试兜底**，所以判据是"真机截图 + DSH 的 CSS/TSX 行号"。
- 探针测试的写法见 `app/test/markdown_coverage_test.dart`：
  用 `find.textContaining(..., findRichText: true)`（`flutter_markdown` 产出
  `RichText`，默认 `find.text` 只看 `Text`，会误判成"什么都没渲染"）。
- 截图前先 `adb shell uiautomator dump` 拿**当前**坐标 ——
  坐标不能跨状态复用（这一条踩过三次）。
