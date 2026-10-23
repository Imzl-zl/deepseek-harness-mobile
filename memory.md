# dsh-mobile 项目状态

> 本文件是**当前状态快照** + 最近活跃窗口，允许覆盖更新。**不做流水追加** —— 历史属于 git 与 `.agents/notes/`。
> 决策与取舍见 `.agents/notes/`，稳定规律与坑点见 `tools.md`，现状事实见 `docs/`。
> 已落地的批次只在文末留一行索引，细节回 git 与笔记找。

## 下一步（新会话从这里开始）

> **2026-10-22：八件对齐（输入法 / 拖拽 / 动效 / 字号 / 每步视图 / 设置 / 版本 / createdAt）**
> 开工单 `.agents/notes/implemented/2026-10-22-running-cues-step-views-font-scale-settings-parity.md`
> 已全部落地，每件一个提交 + 一篇决策笔记：
>
> | 件 | 提交 | 笔记 |
> |---|---|---|
> | G 输入法只由用户点击引起 | `4f52a65` | `2026-10-22-input-focus-only-from-user-tap.md` |
> | F 抽屉拖拽（插入线 / 扫到即显示 / 松手提交最后格） | `6f30f11` | `2026-10-22-drawer-drag-insertion-line.md` |
> | A 运行中动效（共享 ticker 扫光 + 活时钟运行条） | `00f69a1` | `2026-10-22-running-cues-shimmer-and-live-clock.md` |
> | C 字号刻度（base+delta，10–22 默认 14） | `38f0661` | `2026-10-22-type-scale-base-plus-delta.md` |
> | B 每步视图（bash / read / edit） | `376a575` | `2026-10-22-tool-views-three-high-frequency.md` |
> | D 设置三行（默认权限 / 默认预设 / Session Log） | `d11e935` | `2026-10-22-settings-handlers-and-default-mode.md` |
> | E 电脑侧 DSH 版本 | `f5592af` | 同上（§4） |
> | H `workspace.createdAt` | `fab945d` | `2026-10-22-workspace-created-at.md` |
>
> 现状事实各有一篇 `docs/subsystems/`（`input-focus` / `session-ordering` / `running-cues` /
> `type-scale` / `tool-views` / `settings-and-versions`）。
> 门禁：flutter **1080** / connector **586** / relay **86** / protocol **486·26·49** /
> boundary **349**（96 个 Dart 文件）/ icons / tool-paths / analyze+format 0。
> 真机：`d61cf622`，截图在 `D:\tmp\dsh-e2e\shots-2026-10-22\`。
>
> **2026-10-22 晚（本轮）三件 + 一个现场抓到的 bug**：
>
> | 件 | 提交 | 笔记 / 判据 |
> |---|---|---|
> | ① 设置页返回后抽屉仍开（回归） | `a859ef9` | `implemented/2026-10-22-drawer-close-before-push.md` |
> | ② 工具行扫光的真机证据（缺口 8） | `9a9f684` | 追加进 `2026-10-22-running-cues-shimmer-and-live-clock.md`；配方进 `tools.md` |
> | ③ 轮组**阶段 1 已落地**（整轮分组 + 可折叠过程 + 「工作步骤收起时机」） | 见下 | `implemented/2026-10-22-turn-groups-phase-1.md`；现状 `docs/subsystems/turn-groups.md` |
> | 额外：`turn/end` 之后运行条还在转 | `3980fa3` | `implemented/2026-10-22-running-flag-is-events-only.md` |
>
> ① 的根因不是"时序没等"而是 `Navigator.maybePop` **会主动放弃**：
> 它 `await willPop()` 回来重取栈顶，发现变了就 `return true` 什么都不做
> （`navigator.dart:5539,5547-5551`），而"收抽屉 + 同一拍 push"正是这个形状。
> 现在收抽屉一律 `ChatPageState.closeDrawer()`（同步），全屏页走 `openFromDrawer`。
>
> ② 的判据（机械）：工具行矩形内相邻帧差分只有一个约 40px 的窗在变、且窗左移。
> 第一次没抓到是**方法错**（发了 prompt 却按返回键把 App 退到桌面）。
>
> 额外那条：`runningOf` 曾是"事件集 OR `session.list` 快照"，旧快照 `true` 永远关不掉
> ⇒ 运行条转 5 分钟、输入栏永远「排队发送」。现在只有一个真值。
>
> 深夜补的两条（用户看图追问「为啥一个 turn 里好几个助手」「怎么中间显示」）：
> ① **一个 turn 只有一个「助手」头** —— 只有带正文的 `assistant/message` 是助手消息，
> 中间步骤的思考变成 `ReasoningItem`（无头像的过程行，随轮组收起），"几条消息"
> 只数带正文的那条（DSH `hasAssistantReplyContent`）：
> `implemented/2026-10-23-one-assistant-head-per-turn.md`；
> ② **头像在轮次开头**（每组第一条助手侧条目上方，按折叠后可见条目算）：
> `implemented/2026-10-23-assistant-head-at-turn-start.md`。
>
> 同一批改了应用身份：**名字 = DeepSeek Harness**（一处定义 `kAppName`，六处显示：安卓 label / iOS 显示名 / `MaterialApp.title` / 抽屉头部 / 顶栏兜底 / **会话里助手说话者**）、**图标 = DSH 桌面端那枚鲸鱼**
> （`apps/desktop/resources/icon.png`；legacy 五档 + 自适应前景，底色 #FFFFFF）：
> `implemented/2026-10-23-app-name-and-icon-from-dsh.md`。
> 白天用户又追两条：**品牌位全部用同一枚图标** —— 抽屉头部 logo 与「助手」头像都改成
> `DshBrandMark`（`lib/ui/dsh_brand.dart` + `assets/brand/dsh-whale.png`）；
> 启动器里 `DeepSeek Harness` 会被系统省略成 `DeepSeek H…`（名字是用户指定的，留观感问题）。
>
> **2026-10-23（本轮）子会话头部的父级改成数据驱动** —— `7806b2a`：
> 连接器 `session.list` 的子会话行多一个**别名形式**的 `parentSessionId`（根会话不给这个键）
> ⇒ App 头部三档取值（清单行 → 已读目录扫描 → 导航记忆，第三档是老连接器的兜底）；
> 切换面板 root = 当前会话真正的父级，点当前行只关面板；`←` / `PopScope` / 发送方法
> 共用同一个父级判据（孙级逐层返回）；顶栏标题只显示当前子级名（删 `_SubagentCrumb`）；
> 目录读失败时计数 chip 仍出现、点开可重试。
> 笔记 `implemented/2026-10-23-subagent-header-parent-from-data.md`，
> 现状 `docs/subsystems/subagent-page.md` §4；真机截图 `shots-2026-10-23/v*.png`。
> 门禁：flutter **1117**（原 1111），connector 586 / boundary 357 / icons 不变。
> **契约方法面因此变了**（`session.list` 行多一个键）—— 老手机忽略，新手机连老连接器退到记忆。
>
> **同日追加（用户看图追问"子智能体页面怎么没有显示模型"）** —— 两个真 bug：
> ① 子会话的输入栏模型显示「未选择」：连接器顶层 `model` 从**活 agent** 读，
> 子会话不在那张表 ⇒ 改 App 侧**优先取行的投影提示** `modelSelection`（同一包里，
> 零额外往返），输入栏模型名 / 推理等级 / 模型面板的"当前"三处一起走 `AppModel.currentModel`；
> ② 从面板往下钻时孙级的只读档取错了目录（用"当前会话的父级"查 mode ⇒ 查不到 ⇒
> 可续聊的孙级显示成「暂时只读」）⇒ 改成"产出那一行的那条目录"。
> 笔记 `implemented/2026-10-23-subagent-composer-model-and-mode-source.md`；
> 真机 `shots-2026-10-23/w5|w9|w10-*.png`（父/子/孙三层都显示 `auto`）。
> 门禁：flutter **1119**。
> **面板行不显示模型是有意的**（DSH 的 `ui-subagent` 里 `model` 零命中，行第二行是
> `title · mode · activity`）—— 想要就得单独决定"移动端偏离"。
>
> **同轮再查一层（用户问"不会又有细节不到位吧"）**：`_projections` 只有一包、
> 没有"属于谁"的标记 ⇒ 换会话那一刻（以及新会话读失败时）统计条 / token / 权限档
> 显示的是**上一个会话**的数字。修法：`_projectionsSid` + `projections` getter
> 只在 sid 匹配时给（内部 10 处直读全改走 getter）。代价：换会话后到新包落地前是空态
> （显示别人的数字比空一拍更坏）；同一会话重读失败仍保留旧值（"刷新不闪空"不变）。
> 笔记 `implemented/2026-10-23-projections-belong-to-a-session.md`；真机 `y3|y4|y5-*.png`
> 三层数字各自不同。门禁：flutter **1120**。
>
> **同日审查 11 条已全部收口**（`ef33b49` I1 / `8173d3d` I2 / `8679df8` I3+I4 /
> `31984d9` M1·M2·M6 / `9ec3288` M3·M4·M5·M7）：清单移入
> `implemented/2026-10-23-subagent-parent-and-model-truth-review.md`（含落地表与两处偏离）。
> 两条代码项是同一个病根 —— 同一事实两处取数：**模型**（连接器读宿主 state 的 `.next`
> 恒 undefined ⇒ 顶层 `model` 永远只是 lastUsed）改成读 wire view，与 App 同一表达式；
> **父级/mode**（树知道，却回目录里再查、还全表扫描反推 ⇒ 刷新窗口里点孙级显示
> 「暂时只读」）改成由画出那一行的那一层交出。**0 个真机回合**。
> 笔记 `implemented/2026-10-23-connector-model-from-wire-view.md` /
> `implemented/2026-10-23-subagent-parent-and-mode-from-the-layer.md`。
> 门禁：flutter **1121**（+1 条新用例）/ connector **587**（+1 条空串父级），其余不变。

> **2026-10-23（本轮）原型子智能体面板同步 + `verify-subs.mjs`** —— **0 个真机回合**（只跑 headless CDP）：
> 原型 `renderSubs` 从"三条平铺演示行"换成**目录树**。`SUBS` 改成**按父会话分层的直接子级表**
> （可续聊在跑 / 一次性 / external / 目录读失败 / 已知空叶 / 可展开的孙级 + 曾孙），
> 展开才懒加载、三态各一句话（加载中 / 失败+重试 / 读到空）、行 = 活动点 + label + 第二行
> （`title · mode · activity · 时长`）+ 右列 token + 行尾 44×44、缩进 12 只画竖线；
> 点行 = 进入（收起抽屉 + 一句提示）、点行尾 = 只展开；收起连带收整枝。
> 面板 root = **当前会话**（点抽屉里的会话行就换 root，「没有子智能体。」那一态走这条路）。
> 新脚本 `mock/proto/tools/verify-subs.mjs` **41 项**。
> 笔记 `implemented/2026-10-23-proto-subagent-panel-tree.md`；
> `docs/subsystems/subagent-page.md` 的 §6 第 3 条差异（"原型还是平的"）已删、§3.1 行字号回到 12/11、§7 加原型验证行。

> **2026-10-23（本轮）原型轮组同步 + `verify-turns.mjs`** —— **0 个真机回合**（只跑 headless CDP）：
> `#msgs` 从静态平铺改成**一轮一个 `.tgrp`**：过程条目挂 `data-proc`（CSS 只按这一个标记收起）、
> `data-turn` 缺席 = 未归属组永不折叠、`data-closed` 才画组头；组头照落地端 `TurnProcessRow`
> （`第 N 轮` + 统计三段 + 用量 / 复制 pill，落在轮次末尾 —— §4 已定案的有意偏离）。
> 助手头改成**每组一个、轮次开头**（头像 = 鲸鱼、名字 = `DeepSeek Harness`、不再挂模型名）；
> 补了系统提示词 / 上下文注入 / 斜杠命令卡 / 压缩卡四种行（§2.1 的三条细节要靠它们才看得见）；
> 发送流程 `beginTurn` → `finishTurn`（运行中无组头、不可折）；审批 / 提问回执并进最后一组；
> 设置页补「工作步骤收起时机」两档（`next-input` 判据 = 最后一组；手动点过优先）。
> 顺手修：统计条第一格在发送后曾被写成 `第 1 轮 · 3 步`（与 DSH `stats.counts` 冲突、同一句两处写）
> ⇒ 记住初值还原。新脚本 `mock/proto/tools/verify-turns.mjs` **60 项**。
> 笔记 `implemented/2026-10-23-proto-turn-groups-and-verify-turns.md`；
> `docs/subsystems/turn-groups.md` §2 补"内联 diff / 变更文件 / 过程产出的图片"、§3 补箭头朝向、§6 补原型判据。
> **箭头方向**照 DSH/落地端（收起朝下、展开朝上）—— 开工单里"收起后箭头朝右"与两侧真值冲突，未采用。

> **2026-10-23（本轮）缺口 9b：断线期间收口的一轮，重连后运行条不再转** —— **0 个真机回合**：
> 重连进服务态时第一包 `session.list` **重建** `_runningSids`（唯一允许"撤"的地方；
> 平时仍只补不撤），轮次代号（`turn/start` / `turn/end` 各 +1）挡住"请求之后到达的事件"——
> 旧快照不许钉死 `true`，也不许关掉刚起的一轮。第一包按协议可能是增量或快照页
> （`connector/src/protocol/recovery.ts:298-311`）。判据 `app/test/running_reconnect_test.dart`
> 6 条；变异校验两组各恰好 3 / 2 条红。笔记 `implemented/2026-10-23-running-rebuilt-on-reconnect.md`；
> 门禁 flutter **1127**，其余不变。

> **2026-10-23（本轮）斜杠命令执行面：`/goal …` 不再变成普通消息** —— **0 个真机回合**：
> 新方法 `command.execute`（参数 `{sid, line}`，`agentId` 由连接器从 `sid` 解析，附件恒 `[]`，
> 回 `{matched, execution?}` —— **与 `permission.switch` 同一个形状、同一段执行逻辑**
> `connector/src/dsh/command-line.ts`）。**不收窄成"通用命令面"**：白名单 `MOBILE_COMMANDS`
> 只放 `/goal` 与 `/plan`，准入三条（结果只由 `{kind,text}` 承载且不产生会话之外的新产物 /
> 处理器自己是状态机、重复执行落到同一终态 / 没有已存在的窄口）；`/compact` `/export`
> `/feedback` `/permission` 都在外面，拒绝时回 `connector/unsupported` 并报出名单。
> 手机侧**一处分流**（`app/lib/model/command.dart` 的 `sendRouteOf`）：命令 → 新方法、
> 普通文本 → `session.prompt`、子会话恒 → `subagent.prompt`；`matched:false` 按 Web 的
> 输入流水线退成普通消息（`machine.ts:170-175`）并说一句，失败则如实报且文本留在输入框。
> 应答解析上收到一处（`parseCommandOutcome`），`permission.switch` 跟着换。
> 笔记 `implemented/2026-10-23-slash-command-execution-surface.md`；
> 契约 §5.7 加一行、§5.8 的旧数（35/4）校准成 38/2。
> 门禁：connector **587 → 599**（+12）、flutter **1127 → 1137**（+10）、boundary **357 → 360**（+1 个文件），其余不变。

> **2026-10-23（本轮）legacy 提问终于有身份 —— 未计时 `ask_user_question` 不再变成工具失败** —— **0 个真机回合**：
> 根因是**两端本来就有同一个身份，只是应答者那一刻没把它交给自己那份 claim**：手机那张卡的 `itemId`
> 是 `t:<callId>`（来自会话事件 `tool/call`，`app/lib/data/projection.dart:1020-1033`），
> `interaction.respond` 发的也是真 call id（`app/lib/data/app_model.dart:3148-3160`）；而 legacy 形态的
> ask **没有** `wait.callId`（legacy 工具调 `ask()` 时不传 `wait`，`tool-ask-user/src/index.ts:98-109`），
> 连接器于是把 `undefined` 写进 claim 的键 → fail-closed 抛出 → DSH 把一次提问变成工具失败。
> 修法：claim 之前从 `agent.session.snapshotEvents()` 认身份 —— `tool/call` 里
> `name === 'ask_user_question'` 且**没有** `tool/result` 的**恰好一条**；不唯一 / 没有就 `next()`
> （交还桌面，不抛也不猜）。纯函数 `connector/src/dsh/question-call.ts`；`interaction-claims.ts`
> 的 fail-closed 保留（它是兜底，不是主路径）。**不改部署成 `mode: timed`**：那要改 shipped preset，
> 还让桌面提问卡带倒计时 —— 本仓要的是"认出身份"，不是"改提问形态"。
> 笔记 `implemented/2026-10-23-legacy-question-identity-from-session-log.md`；
> 契约 §5.7 的 `interaction.respond` 行 + §6.3.1 已写清判据与取舍。
> 门禁：connector **599 → 612**（+13：12 条身份用例 + 1 条"程序化提问不 warn"），其余不变。

> **2026-10-23（本轮）交互改成 gateway 的 owner client —— 桌面与手机由同一个触发关闭**：
> 连接器不再是 host 的 `prepend` answerer。它建 in-process owner peer，接 gateway 的 `$events` 转发流
> （`connector/src/dsh/interaction-client.ts`），同一条 pending 交互**同时**投给桌面与手机：
> 手机先答 → 回 `{kind:'result'}` → gateway 结算 → 给浏览器发 `cancel` → 桌面卡关；桌面先答 →
> 收到 `cancel` → 撤手机在途 claim。三档仲裁只剩"**手机参不参与**"：**不参与就回 `next`（原生委托）**。
> **没有看护计时器**：DSH 的审批没有超时（浏览器的卡也一直挂着），所以不造超时、不记"未处理"、
> 不设 fail-closed 指标 —— 这三样都是 host answerer 时代的自创边界（用户当场点破："DSH 原生是啥样
> 就啥样，不擅自加边界"）。一条 claim 只有三种结局：手机答了 / gateway 发 `cancel` / 插件卸载。
> **三档开关 `approvalTakeover`（never/foreground/always）连根删了**：它是"抢"时代的产物 ——
> 现在两边都弹、谁先答谁赢，没有"谁接管"；不想让手机参与就停传输通道（手机连不上 = 没有投递）。
> 一起删的：`protocol/takeover.ts` 与 `decideTakeover`、`fixture 16`、`protocol/reference/takeover.mjs`、
> store 里没人写的 `takeover` 表、没人读的 `approvalWatchdogMin`、客户端里的 `TakeoverSource`。
> 删除 `dsh/interactions.ts`、`registerApprovalAnswerer`、`Watchdog*`、`UnhandledInteraction`、
> `METRIC.failClosed`；端口入参收窄成 `ClaimRequest { sid, callId, redeliver? }` 且**不接受任何依赖**
> （`createInteractionPort()`）；缺 `typertGateway` / `connection` → **不做手机交互**（没有 fallback）。
> 笔记 `implemented/2026-10-23-interaction-as-gateway-client.md`（含"沉默 + 10 分钟"与"三档"两个
> 被撤掉的方案）（`2026-10-13-answerer-must-be-prepended.md` 移入 `archived/`）；
> 契约 §6.2 / §6.2.1 / §6.3.1 / §8.1 / §10 / §15 同步。
> 门禁：connector **618 → 611**、protocol **486 → 454**（fixture 16 那一份随规则删除；
> 两边同时删、仍对等，`AGENTS.md` 的"fixtures 断言数须 = 454"）。**这是唯一一处破了"门禁只许升"，
> 理由是契约规则本身被删，不是放宽**；其余门禁不变。
> **真机/桌面已验（1 个轮次，22:50 与 23:36 各一次）**：隔离实例装新产物 + 桌面 Web GUI
> （headless 里的真客户端），两边同时弹卡（旧形态下桌面收不到），**手机点「允许一次」→ 桌面卡消失**；
> 会话日志 `approval/asked` → `decided allowed-once`，管理面 `lastInteractedAt` 与 decided 时间差 **1 ms**
> （= 决定来自手机）。截图 `D:\tmp\dsh-e2e\shots-2026-10-23-interaction-client\`（`final-*` 是删掉
> 计时器之后的复验）。"不参与 → next"由单测覆盖，没过真机。

待办（按顺序）:

1. **轮组阶段 1 已落地**（整轮分组 + 折叠过程 + 「工作步骤收起时机」两档）——
   `docs/subsystems/turn-groups.md` 是现状，因果见
   `implemented/2026-10-22-turn-groups-phase-1.md`（原方案移入 `archived/`）。
   原型已追平（`verify-turns.mjs` 60 项）。剩下两件：
   - **阶段 2「语义过程组」**（已完成分析 / 执行了命令）：暂不做，390dp 上两层组头
     要两次点击才看到正文；
   - **收起/展开不改滚动位置**：`reverse: true` 的格数一变，点开的那一轮可能在屏幕外。
2. ~~**`ask_user_question` 未计时提问答不了**~~ **已修（2026-10-23）**：legacy 形态没有
   `wait.callId`，连接器改从会话日志推身份（唯一一条未结算的 `ask_user_question` `tool/call`），
   推不出就交还桌面。笔记 `implemented/2026-10-23-legacy-question-identity-from-session-log.md`。
3. ~~**斜杠命令没有执行面**~~ **已修（2026-10-23）**：新方法 `command.execute`
   （白名单只放 `/goal` 与 `/plan`，准入判据见契约 §5.7 那一行），`/goal …` 不再变成普通消息。
   命令卡的渲染没动（那是另一件事）。笔记 `implemented/2026-10-23-slash-command-execution-surface.md`。
4. **电脑侧停一会儿，手机会清掉配对** —— 中转重启后名册是空的，设备换票拿到 401，
   App 把 401 归成 `notPaired`（终态）⇒ 清凭据回配对页。实测一次（清单第 11 条）。
   **根因已查清（2026-10-24 审计 C1）**：中转那个 401 只说"我的名册里没有你"
   （名册是电脑推上去的），它不是终态 —— 是我们把它读成了终态。
   工单 `proposed/2026-10-24-terminal-identity-from-relay.md`（W3，与已知缺口 3 同批）。
5. **侧边栏移动 / 置顶：真机已验**（2026-10-21 晚，隔离实例）—— 长按菜单四项（无删除）、
   置顶后进本组最前并出图钉、跨置顶分区上移不可点、未分组桶上移/下移不可点、
   归档后从列表消失且能在「归档」页取消、杀 App 重开 + 中转重启后置顶与顺序仍成立。
   同组内**非置顶行之间**的上下移：**2026-10-22 已验**（下移一次，账本顺序变了）。
6. **子智能体进入 / 后台任务看与停：真机已验**（2026-10-21 晚）：点目录行进子会话、`←` 回父、
   系统返回键同一条路、切兄弟后父级记忆不丢、子会话内容能加载、跑完变绿且时长定格、顶栏 running 计数会变。
   两个只在真机暴露的缺陷已修（子会话地址缺父级、子会话发消息被拒 → `subagent.prompt`）。
   孙级（`maxDepth: 2`）已验；一次性子会话本 profile 造不出（两个 in-process 后端只产 `continuable`）。
   **第三个缺陷（头部父级停在祖父）2026-10-23 已修**（`7806b2a`）：父级改数据驱动，
   逐层返回与面板 root 都跟着真值走。
7. **异常结局 / 重试 / 压缩标记**（仍未造出）：没有稳定制造**失败**回合的手段（取消 ≠ 失败）；
   压缩标记未出现。历史翻页这轮用 B 的实验验掉了（见下），附件 D1 已过。
8. **「上传文件」** —— 开工单在 `.agents/notes/proposed/2026-10-20-file-upload-shape.md`
   （DSH 侧入口 `packages/client/file-upload/src/index.ts:105,118`；共 8 个触达点，**别半截提交**）。
9. ~~历史翻页的 `refetch` 标记被丢弃~~ **已修（2026-10-22）**：`SyncClient.refetch` + `page()` 合并 +
   失败如实报（`SessionPage.failure`）。真机实验：把 `refetchThresholdBytes` 调到 1，
   61 条消息的会话滚到顶 → 翻页 + 逐条补取 → **会话开头（系统提示词 + 第一句 prompt）出现在手机上**。
10. ~~失败回合没有"手动重试"入口~~ **不做**：DSH Web 的 `ui-conversation` 也没有这个入口。
11. ~~**在途交互 = host-held pending**~~ **P1/P2a/P2b 已落地（2026-10-23）**：断线**不结算** claim
    （审批与提问同一规则）、手机重订阅时按原 seq **重投在途 ask 事件**（不新增帧 / 方法）、
    App 失败分类（传输失败留卡可重试、`not-pending` 撤卡、失败不写成功回执）。
    笔记 `implemented/2026-10-23-in-flight-interaction-is-host-held.md`。
    **仍未做（明确不顺手做）**：timed 部署（代价是桌面倒计时 + 模型 120 s 后继续）。
    计划审查卡**已查清（2026-10-24，W1 落地时改判）**：`/exit_plan_mode` 的询问带
    `intent.callId`（`plan-mode/src/index.ts:326`），但**手机上没有那张卡** —— 提问卡只从
    `ask_user_question` 的 `tool/call` 生成，`exit_plan_mode` 只落一条普通工具行。
    claim 一条用户看不到的交互会把 DSH 的 `NO_PROVIDER` fail-closed 换成永远挂起 ⇒
    **不做**，限制写进契约 §15 / §6.3.1；要真答需"卡来自请求"的投递（B12 升级）。
12. ~~**交互改成 gateway 的 owner client**~~ **已修（2026-10-23）**：连接器作为 owner client 接
    gateway 的 `$events` 转发流 —— 桌面与手机**同时**收到、谁先答谁赢、其余收 `cancel`；
    host answerer 与 `prepend` 整条路删掉（旧笔记移入 `archived/`）。
    笔记 `implemented/2026-10-23-interaction-as-gateway-client.md`。
    **真机/桌面已验（1 个轮次）**：手机先答 → 桌面卡关（截图 + 管理面 `lastInteractedAt` 判据）。
13. ~~**原生规则审计**~~ **已收口（2026-10-24，0 真机回合）**：27 行逐条求证并归类（B1–B13 +
    C 表去重）+ 3 条新发现 ——
    `自作主张` **2** / `设计缺陷` **7** / `逻辑语义` **3** / `实现缺陷` **6** /
    `验证缺口` **3** / `有意偏离` **4** / `未实现` **2**。
    真正"替宿主做决定"只剩两条：**审批没有 `callId` 就不参与**、**`danger-full-access`
    下审批不入队**（后者在本部署**永久不可达**：`approval: never` 在 dispatch 之前就拒了）。
    新发现三条：**计划审查卡在手机上永远不出现**（`intent.callId` 没读）、
    **内置预设文案已漂一条**（极简模式）、`interaction-face` 的 `pendingOf` 是生产死码。
    总账 `.agents/notes/proposed/2026-10-24-native-rules-audit.md`（B1–B13 + C 表逐行结论 +
    归类统计 + 根因分段）；开工单 **W1** 身份面改读原生 / **W2** 换代不撤 claim /
    **W3** 终态只有一个来源 / **W4** 运行态改读原生，零碎 **Z1–Z6**
    （`proposed/2026-10-24-audit-cleanup-batch.md`）。
    **开工队列（用户已准 2026-10-24；每件一个提交，按"0 真机优先"排序）**：
    ① ~~**W1** 身份面改读原生~~ **✅ 已落地（`4acb23c`，见下条索引）**
    ② ~~**W2** 换代不撤在途 claim~~ **✅ 已落地（见下条索引）**
    ③ **Z5** 配对码关联想 → **Z2** `onOffline` 死码 → **Z1** `fullAccess` 过滤（三件都 0 真机）← **下一步**
    ④ **Z4** `stats.devices` → **Z3** 匿名限流分桶（relay，0 真机）
    ⑤ **Z6a** 预设文案漂移 → **Z6b** §15 一句（0 真机）
    ⑥ **W3** 终态只有一个来源（1–2 回合）→ **W4** 运行态改读原生（1 回合，要加一条契约帧）
    铁律（用户 2026-10-24 复述）：**别擅自加规则，DSH 原生就行**。

别当缺口（定案，别再试）:

- **全局侧滑**：Flutter 原生抽屉本来就是整页可拖（`material/drawer.dart:680` 的 `height: double.infinity`）。
  真限制是**系统返回手势** —— `setSystemGestureExclusionRects` **每条边最多 200dp 总高**。当前实现已是最优。
- **过程摘要的"用时/计数"在历史窗口不全时是如实降级**：`turn/start` 落在未加载的更早一页里，
  所以只说时长、不摆"0 条消息"。**别去"修"**。
- **轨迹页时间轴已经做了，但只做「每轮一格」**：x 轴 = 该轮起止，三条泳道（模型 / 压缩 / 工具），
  数据来自 `trajectory` 投影。**「调用」明细 tab 与甘特式的多轮对齐视图仍然不做** ——
  它们要的是"跨轮对齐"的语义，现在没有这个需求，摆出来就是假入口。
- **时间一律电脑侧算**：`app/lib/` 里出现 `turn/end.time - turn/start.time` 这类减法就是回退。
  手机的条目表只覆盖已加载的一页，窗口外的轮算不出正确用时（这正是 2026-10-22 之前的失真）。
  判据：`app/lib/` 里搜不到时间减法；几何只做 `offsetMs / turn.durationMs` 一次除法。
- **输入栏横滚钮组**只在加第五个钮时才需要（现在四个不换行）。
- **会话流里 `user/message` 不一定是人说的**：运行时上下文 / 技能目录 / 时间快照都是 `user/message`，
  靠 `source.kind === 'user'` 区分（DSH `conversation-nodes/message.ts:79`）。这条已修。

## 八条教训

> 前五条是"替身复现的不是真形状"；第六条是"提交不完整"；
> 第七条是"生产路径上的假数据"；第八条是"线上预算要按帧算"。

1. **投影信封**：`session.projections` 回 `null | {kind, asOfSeq, values}`，**手机要 `values`**。
   连接器曾整包透传 ⇒ 统计条/权限档/子智能体在生产里全空态而单测全绿（修在 `valuesOf`）。
2. **模型目录**：`buildModelCatalog` 返回**对象**（`{default, routableProviders, groups, failures}`）
   不是数组；解析器认错形状 ⇒ 生产里一次都没解析成功过。
3. **`session/select-model` 没有"不能写"的约束**：Web 调的就是它。我曾把**测试纪律**错升成产品约束。
4. **"空"有两种表达，判空只查一种就会漏**：`items.isEmpty` 漏了 `OtherItem`（hero 从未显示）；
   `usage == null` 漏了**字段齐全但全零**的对象（输入框底下显示 `0 tok`）。
5. **判据要能区分"没命中"与"没实现"**：同一句"点了没反应"可能是坐标偏 30px、也可能是回调没跑。
   **先加一行 `debugPrint` 确认回调跑了没有**，再怀疑手势。
6. **一个功能要一次提交完整**：`3979191`（"用量搬到抽屉"）只提交了 `ui/usage_page.dart`，
   它引用的 `UsageProject` / `grouped` 没进库 ⇒ 那个提交单独编译不过。
   规律：**提交前 `git status --porcelain` 必须是空**（除自己有意的未跟踪文件），
   且新加的文件要**反向 grep 一下"谁引用了它"**。
7. **生产路径上的假数据是最容易漏的一类**（不报错、不空屏、样式也对，只是名字/数字是编的）。
   **抓法两条**：① grep `lib/` 里写死的文件名/中文/数字；② grep `_notWired(` 与 `还没做`。
   注意这条规则**不给"弹一句还没做"留例外**。
8. **线上预算要按"帧"算，不按"对象"算**：二进制 `N` → JSON base64 `1.33N` → `box` 的 base64url 再 ×1.33
   ⇒ **一帧 ≈ 1.78N**。**自查的问法**：这个值在线上最终会被**哪一帧**承载？那一帧里还有谁？

## 真机联调的成本纪律（立过规，别问第二遍）

- **`--profile` 只隔进程/插件/端口**，`~/.dsh/{.credentials.yaml,sessions,storages}` 全局共用 ——
  但 `DSH_HOME` 是官方支持的**数据根覆盖**（`packages/util/home-paths/src/index.ts:17,135`），
  所以起隔离实例是可行的（`$env:DSH_HOME='D:\tmp\dsh-e2e'` + `dsh --profile mobile-e2e --port 63900 --no-open`）。
  **`dsh.cmd` 在 PATH 上**（`D:\soft\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd`）；
  直接 `Start-Process` 那个 `DeepSeek Harness.exe` 会因为参数里的空格**静默失败**（`Cannot find module 'D:\soft\DeepSeek'`）。
- **跑之前报一句"这次约几个轮次"并拿到准** —— 审批探针要模型真跑越权命令，花的是用户的钱。
- **这台机器是 root（KernelSU）**：`adb shell id` = `uid=0`。长按拖动这类"必须在 500ms 后仍不动、
  再移动"的手势只能用 `sendevent` 注（`/dev/input/event7`，逻辑像素 ×133.333）；
  `input swipe/motionevent/draganddrop` 都做不出落点 —— recipe 与判据见 `tools.md`。
- 装 App 一律 `flutter build apk --debug` + `adb install -r`；`flutter install` 与
  `flutter test integration_test/` **都会先卸载旧 App**，配对凭据一卸全没。
- 屏幕灭掉 = 引擎暂停 ⇒ `adb shell svc power stayon true`。

## 前置事实（会卡住实施）

- **单帧上限 8 MiB，任何二进制载荷在线上放大 ≈1.78 倍**（契约 §40 + `connector/src/transport/codec.ts:53,77`）。
  **二进制附件的原始字节预算 = 3 MiB**（3×1.78 ≈ 5.3 MiB）。图片由 `MainActivity.encodeForTransport` 压。
- **DSH 运行时 0.2.1-rc.2**；连接器 devDeps/peerDeps 跟 0.2.1-rc.2，`schemastery` 跟 **3.18.5**。
- **Flutter 3.41.9 / Dart 3.11.5 版本锁死**（上界由鸿蒙 fork 定）。Android 构建要
  `ANDROID_HOME='D:\soft\android-sdk'` + `JAVA_HOME='C:\Program Files\Eclipse Adoptium\jdk-21.0.9.10-hotspot'`。
- 明文 HTTP 放行有**四处**，少一处静默不通：Android `network_security_config.xml`（debug）、
  `PairingPage.allowInsecureLocal`、`main.dart` 的 `PairingClient`、profile `cordis.patch.yml`。
- **无线直连三件一起对**：`listenPort: 8790` + `listenHost: '0.0.0.0'`、8790 监听在 `0.0.0.0`、`caps.direct === true`。
  **`relayUrl` 必须写环回** —— 写死局域网 IP 会绕开 `relayHintFor` 的自愈。
- `connector/` 与 `relay/` 是**两个独立 pnpm 工程**，导入风格不同、别顺手统一。本仓库**没有 CI**。

## 方法面 36/38

契约封闭集 **38**、实现 **36**，差额 2 个是契约列了没实现的：`credentials.set` / `credentials.unset`。
2026-10-21 加的五条是 `workspace.insertSessionBefore` /
`workspace.pin` / `workspace.unpin` / `workspace.insertBefore` 与 `subagent.prompt`；
2026-10-22 挂上了 `settings.describe` / `settings.update`（三行电脑侧设置，见
`docs/subsystems/settings-and-versions.md`）；2026-10-23 加了 `command.execute`
（斜杠命令执行面，**白名单**只放 `/goal` 与 `/plan`，准入判据见契约 §5.7 那一行）。
**两个数都从代码里数，不靠减**；数法见 `tools.md`（要数 `METHODS` + `handlers.ts` 的**两种**注册形态）。
**三处必须同步**：`tools.md`、契约 §5.7 的表、这里的"x/38"。

**`session.projections` 是打开全部只读面的那把钥匙**：请求体只有 `{sessionId}`，返回所有投影的当前值。
已核实的键：`modelSelection` / `permissions` / `subagentCatalog` / `deliverables` / `tokenUsage` /
`contextPressure` / `sessionStats` / `turnOutline` / `todos` / `goal` / `plan` / `inbox` / `title` /
`workingDirectory` / `agentPreset` / `userQuestions` / **`trajectory`**（本仓自带，DSH 没有）。

## 已定案的契约（实施时按这个写，不要重新发明）

细则在 `docs/subsystems/` 各篇，这里只列**最容易重新发明错的**：

- **配对 v2**：公开邀请与秘密分离、候选不是设备、**用户确认前不发秘密**；两段式 `beginPairing()` → `commit(code)`。
- **一条连接只服务一台设备**：握手/AEAD 密钥/`fc`/重放窗口全是每设备状态。
- **认证与可见面的边界**：只有握手三帧与 `presence` 明文（`needsBox(t)` 是唯一判据）。
- **AEAD**：AES-256-GCM；nonce 是 `fc` 的 96 位大端。
- **帧头 `id` 与幂等键是两个标识符**：`requestId` 只进信封（如 `i:<callId>` 带冒号），
  帧头 `id` 另铸且必须过 §3 的 ASCII 安全字符集。**把业务键写进帧头 = 连接器按 bad-frame 关连接。**
- **幂等**：两阶段（落盘 `pending` → 执行 → 改 `done`）；**落盘失败即拒绝该写操作**。
- **密钥**：API 密钥值不回传手机，改密钥只发新值。

## 已知缺口（定位过、有证据，都未修）

1. **首配的匿名限流桶是单一全局桶**：约 6 请求/秒即可让所有新设备换票 429（约 10 s 恢复）。
   → 键是字面量 `'pairing:anonymous'`（`relay/src/http-face.ts:41`）；工单 Z3。
2. `stats.devices` 实为**通道数**，与 §8.2 的 `devices` 表不同名同义。
   → `relay/src/core.ts:61-62` 两字段恒等；工单 Z4（删字段）。
3. 握手层 close 4003 与 `protocol/revoked` 帧两条兜底路径仍走退避，未收口。
   → 与下面第 4 条同根（终态判据只覆盖建连失败）；工单 W3。
4. ~~`pairing_page.dart` 的配对码 `TextField` 没关输入法联想，**手打**的 JSON 会被破坏（粘贴没事）~~
   **已修（2026-10-24，Z5）**：`enableSuggestions: false` + `autocorrect: false`
   （Android 是独立标记，iOS 跟着 autocorrect 走，`text_input.dart:623-636`）；
   判据 `app/test/widget_test.dart` 一条 widget 断言 + 变异校验。
5. **PC 端「上报地址」面板没有布局/点击的自动化测试**（只有 i18n 键完整性门禁；API 侧有用例）。
6. **IPv6 隐私地址仍会上报**：`dialOrder` 已把它们排后面，但仍占列表位。
   → **不改码**（Node 不暴露 `temporary` 标记，判据不可靠）；工单 Z6b 只写进契约 §15。
7. ~~"最近工作区"缺 `createdAt`~~ **已修（2026-10-22）**：`workspace.list` 的行现在带
   `createdAt`（宿主 `WorkspaceView.createdAt`，`packages/api/workspace-controller/src/types.ts:27`），
   `newSessionWorkspaceId` 对**没有会话**的工作区按 `Date.parse(createdAt)` 参与比较 ——
   与 DSH 的 `recentWorkspace`（`navigation.ts:565`）同一条。字段缺席（老连接器）仍按"最旧"。
8. ~~工具行自己的扫光没有真机截图~~ **已补（2026-10-22 晚，`9a9f684`）**：
   `shots-2026-10-22/g-213439.png` + 相邻帧差分（变化只在一个约 40px 的窗里、窗左移），
   做法见 `tools.md` 的「真机抓『工具执行中』那一段」。
9. ~~从设置页返回后抽屉仍开着~~ **已修（2026-10-22 晚，`a859ef9`）**：根因是
   `Navigator.maybePop` 在"栈顶已经变了"时**主动放弃**（`navigator.dart:5539,5547-5551`），
   不是等得不够；收抽屉改 `ChatPageState.closeDrawer()`（同步）。
   判据：`app/test/drawer_close_before_push_test.dart` + 真机两轮
   （`a1/a2/a3-*.png`、`a6-*-*.png`）。
9b. ~~断线期间发生的 `turn/end` 收不到 ⇒ 重连前运行条一直转~~ **已修（2026-10-23）**：
    重连进服务态时按第一包 `session.list` **重建** `_runningSids`（唯一允许"撤"的地方；
    平时仍只补不撤），并用轮次代号挡住"请求之后到达的 `turn/end` / `turn/start`"——
    旧快照不许把 `true` 钉死，也不许把刚起的一轮关掉。第一包按协议可能是增量
    （含 `turn/end`）或快照页（`connector/src/protocol/recovery.ts:298-311`）。
    判据 `app/test/running_reconnect_test.dart`（6 条，**0 个真机回合**）；
    因果见 `implemented/2026-10-23-running-rebuilt-on-reconnect.md`。
10. **`workspace.createdAt` 的"空工作区当最近"只有单测**（2026-10-22）：真机上 App 总会恢复
    上一次的会话，而「当前会话所在工作区」是链的第二步、优先级更高；手机没有「取消选中会话」
    的入口 ⇒ 那条分支在真机上够不到。要真机验，得先有一个能落到"无当前会话"的入口。
11. ~~字号"局部刻度"在真机上观感差~~ **已改（2026-10-22 晚）**：设置项换成「界面字号」
    四档倍率（0.9 / 1.0 / 1.15 / 1.3，默认 1.0），由 `MediaQuery.textScaler` 乘在系统字号之上
    **等比放大全部文字**（含 chrome 与 caption），图标也跟随（clamp 1.0–1.4），
    带文字的定高改成 `minHeight`。取舍见
    `.agents/notes/implemented/2026-10-22-global-ui-scale.md`，现状见
    `docs/subsystems/type-scale.md`；旧方案（只放大内容）已移入 `notes/archived/`。
12. **`presence.onOffline` 是死 API**（2026-10-23 删掉两处调用之后留下的）：生产无调用方（只有
    `presence.test.ts` 一条），注释还写着"看护要靠它收口"。同批可删的还有它的离线监听桶。
    → 工单 Z2（死码 + 过期注释一起删）。
13. ~~**`$events` 换代窗口**~~ **已修（2026-10-24，W2）**：换代**不撤**在途 claim（claim 挂在挂载上，
    与 DSH"断线只撤投递"一致），手机在窗口里答的答复等下一代 `ready` 再用新 `clientId` 发出去；
    `dispose()` 才是终态。判据 `connector/tests/interaction-client.test.ts`（3 条），变异校验两组
    各恰好红 3 / 1 条。**残余窗口**（换代期间别人先答）已在笔记里如实写明。
    笔记 `implemented/2026-10-24-claims-survive-stream-generation.md`。
14. **内置预设文案已漂一条**（2026-10-24 审计 B13）：极简模式的描述在 DSH 是"终端和图片
    读取工具，并支持上下文压缩…"（`ui-agent-preset/src/client/locales.ts:100`），我们抄的是旧文案
    （`app/lib/model/agent_preset.dart:51`）；`app/test/agent_preset_test.dart:103-106` 复述同一份
    手抄串，测不出漂移。→ 工单 Z6a（修字 + `tools.md` 升级清单里加"重抄四档"）。
15. ~~**`interaction-face` 的 `pendingOf` 是生产死码**~~ **已删（2026-10-24，W1）**：
    `pendingOf` / `projectPendingQuestions` / `PendingItem` 全删，`itemIdOf` 换成
    `approvalItemId` / `questionItemId` / `interactionItemOf` 三个函数（一处表达）。
16. ~~**审批没有 `callId` 时手机不参与**~~ **已修（2026-10-24，W1）**：审批的 claim 键改成
    `i:<approval/asked.id>`（`connector/src/dsh/approval-call.ts`），`interaction.respond` 的
    键从 `callId` 改成 `itemId`（`i:<approvalId>` / `t:<callId>`），重投也按 id 匹配。
    **认不出身份时仍然委托**（日志 0 条/多条未结算）—— 那时只有桌面能答，契约 §15 已写。

## 范围决定（别再当缺口）

- **刷新令牌轮换不做** / **中转不做多实例**（单实例 + I7 重启收敛就是个人工具的形态）。
- **鸿蒙暂缓**（不是放弃）：Flutter 版本锁保留，OHOS 适配/HUKS/推送全部暂停。
- **插件不做"逐插件页面适配"**：只做清单/状态/启停/安装日志 + `volatile` 字段通用表单。
- **管理页面不做**：二维码唯一出口，DSH 的 `CommandResult` 只有 text 没有图片出口。
- **不做 hard pin**："手动选择"= 立刻试一次（失败回自动）+ 拖动排序。
- **手机上不做（C 类）**：目录选择器、唤起电脑应用、内嵌浏览器/Office 预览、快捷键/窗口管理、
  workflow/schedule/skill、实验性功能。

## 门禁（改代码后必须全绿）

| 命令 | 覆盖 |
|---|---|
| `node protocol/verify-{fixtures,loopback,vectors}.mjs` | **454 / 26 / 49** 项 |
| `node app/tools/verify-platform-boundary.mjs` | **360 项**（22 条规则自检 + 扫 99 个 Dart 文件） |
| `node mock/proto/tools/verify-icons.cjs` / `verify-tool-paths.mjs` | 图标集（100 个）/ 23 个工具脚本无硬编码盘符 |
| `cd app && flutter test` | **1141 项** |
| `cd app && dart analyze --fatal-infos lib test integration_test` + `dart format --output=none --set-exit-if-changed …` | 各 **0** |
| `cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test` | 类型 + 产物 + **616 项** |
| `cd relay && pnpm typecheck && pnpm test` | 类型 + **86 条** |
| CDP 浏览器组 | `verify-proto`（**31**）/ `verify-authz`（18）/ `verify-settings`（28）/ `verify-tasks`（53）/ `verify-picker` / `verify-drawer`（**25**）/ `verify-subs`（**41**）/ `verify-turns`（**60**） |

**项数的唯一出处是 `tools.md`**；**改断言必须做一次变异校验**（故意破坏不变量，确认**恰好**那一条红）。

## 仍未注意就会翻车的

- **改源码只用编辑工具，不用 shell 字符串替换** —— shell 出错是静默的。
- **`dart format` 会重排文件**，之后再编辑同一文件要**重新读一遍**。
- 提交纪律 / 多替身接口 / 真机坐标 / adb 合成不出拖动落点 等**稳定坑点的唯一出处是 `tools.md` → Pitfalls**。

## 已落地批次索引

细节回 `git log`（每篇都有 hash 与决策笔记）。**唯一要记住的资产**：
`app/test/fixtures/real-session-events.json` **是真机落盘事件** —— 手写形状的用例只会复述实现的假设。

- 2026-10-21 子智能体页对齐 Web —— `.agents/notes/implemented/2026-10-21-subagent-catalog-tree-and-state.md`。
- 2026-10-21 晚 真机验收修掉的三条 + 锚定浮层 —— `2026-10-21-subagent-child-address-and-prompt.md`、`2026-10-21-anchored-popover-for-top-bar-panels.md`。
- 2026-10-21 深夜 抽屉行菜单锚定 + 拖动排序 —— `2026-10-21-anchored-popover-for-drawer-rows.md`、`2026-10-21-drawer-drag-and-counts.md`。
- 2026-10-22 轨迹页只做轮次 + refetch 补取 + 新建会话落进工作区 ——
  `2026-10-22-trajectory-turns-only-and-duration-bars.md`、`2026-10-22-refetch-markers-are-fetched.md`、
  `2026-10-22-new-session-lands-in-a-workspace.md`。
- 2026-10-22 轨迹页真时间轴（电脑侧折、手机只画）——
  `2026-10-22-trajectory-timeline-from-host-projection.md`。
- 2026-10-23 子会话头部父级数据驱动（`session.list` 多一个别名形式的
  `parentSessionId`）+ 顶栏标题只显示子级名 ——
  `2026-10-23-subagent-header-parent-from-data.md`。
- 2026-10-23 审查 11 条收口（连接器模型读 wire view / 父级与 mode 由画它的那一层交出）——
  `2026-10-23-connector-model-from-wire-view.md`、`2026-10-23-subagent-parent-and-mode-from-the-layer.md`。
- 2026-10-23 原型子智能体面板同步落地端（目录树 + 三态 + 44×44 + 收起整枝）+ `verify-subs.mjs` 41 项 ——
  `2026-10-23-proto-subagent-panel-tree.md`。
- 2026-10-23 原型轮组同步落地端（一轮一个可折叠组 + 一个助手头 + 「工作步骤收起时机」）+
  `verify-turns.mjs` 60 项 —— `2026-10-23-proto-turn-groups-and-verify-turns.md`。
- 2026-10-23 断线期间收口的一轮：重连按 `session.list` 重建运行态（轮次代号护栏）——
  `2026-10-23-running-rebuilt-on-reconnect.md`。
- 2026-10-23 斜杠命令执行面：`command.execute` + 白名单（`/goal` `/plan`），
  两个命令门共用 `dsh/command-line.ts`，手机侧一处分流 ——
  `2026-10-23-slash-command-execution-surface.md`。
- 2026-10-23 legacy 提问的身份从会话日志推（唯一一条未结算的 `ask_user_question` `tool/call`）——
  `2026-10-23-legacy-question-identity-from-session-log.md`。
- 2026-10-23 在途交互 = host-held pending（断线不结算 + 重连重投 ask 事件 + App 失败分类）——
  `2026-10-23-in-flight-interaction-is-host-held.md`。
- 2026-10-23 交互改成 gateway 的 owner client（`$events` 转发流 + `$events/result`，桌面与手机同时可见、
  谁先答谁赢）—— `2026-10-23-interaction-as-gateway-client.md`；
  旧的「应答者必须 prepend」移入 `archived/`。
- 2026-10-24 交互身份改读原生（审批 `i:<approval/asked.id>`、`interaction.respond` 的键 = `itemId`；
  删 `pendingOf` 死码；**计划审查不接线**并写进 §15）——
  `2026-10-24-interaction-identity-from-native-ids.md`。门禁：connector **611 → 615**、
  flutter **1140**、protocol 454·26·49、boundary 360。
  顺带修：手机侧 fixtures 回放条数 16 → 15（`2da3745`，那条门禁从 `fce4f9e` 起一直是红的）。
- 2026-10-24 `$events` 换代不撤在途 claim（claim 挂挂载；窗口里的答复等下一代 ready 再发）——
  `2026-10-24-claims-survive-stream-generation.md`。门禁：connector **615 → 616**，其余不变。
- 2026-10-24 配对码输入框关掉输入法联想（`enableSuggestions` + `autocorrect`）——
  零碎清理 Z5；flutter **1140 → 1141**。**原计划的 `keyboardType: visiblePassword` 查 SDK 后砍掉**
  （它的文档不含"关联想"，见 `text_input.dart:623-636`）。
