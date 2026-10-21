# 子智能体页（目录树 / 子会话头部 / 只读输入区）

手机端的子智能体面：右抽屉里的**目录树**、进入子会话后的**顶栏导航**、以及一次性 /
未知模式子会话的**只读状态框**。结构与判据逐条对齐 DSH Web 的 `ui-subagent`，
容器仍是右抽屉（设计 §7.8）。

引用非本仓参考实现时给 `仓库根\相对路径:行号`；DSH = `D:\sudy\github\deepseek-harness`。

## 1. 数据面（不新增方法面）

| 用途 | 来源 | 形状 |
|---|---|---|
| 目录（**只含直接子级**） | `session.projections` 的 `subagentCatalog` | `[{id, createdAt, mode, label?}]` |
| 子会话此刻跑没跑 | `session.list` 行的 `running` | `bool` |
| 子会话计时 | 同一行的 `projections.values.subagentTiming` | `{settledMs, active?{since,through}, lastTurnCompleted?}` |
| 子会话 token | 同一行的 `projections.values.tokenUsage` | 四个互不重叠的桶 |
| 子会话标题 | 同一行的 `projections.values.title` | `string` |

- `subagentCatalog` 的 view 只有直接子级（`packages/subagent/subagent/src/catalog.ts:111-131`，
  原话 "current direct-child rows in parent catalog event order"）；孙级要**再读一次**
  该子会话自己的 `session.projections`。Web 的对应动作是
  `toggleBranch(childSessionId)` → `refreshProjection(child)`
  （`packages/client/ui-subagent/src/client/SubagentHeaderLineage.tsx:570-577`）。
- 连接器把 `session.list` 行的整包投影提示原样透传（`connector/src/handlers.ts:527-533`），
  所以上面三个提示都到得了手机。
- 目录 id 是**别名 sid**（连接器换过，`connector/src/handlers.ts` 的 `aliasSubagentCatalog`），
  直接 `openSession` 就通。

### 1.1 子会话的地址与写入口（与普通会话不同）

| 用途 | 方法 | 关键点 |
|---|---|---|
| 打开子会话 / 翻历史 | `session.subscribe` / `session.page` | 地址必须是 `{kind:'subagent', parentSessionId, childSessionId, mode:'unknown'}`。宿主对 `kind:'session'` 的子会话直接拒（`session-controller/src/history.ts:347-352`，原文 "subagent Sessions require their durable parent address"） |
| 在可继续子会话里发消息 | `subagent.prompt` | 对子会话调 `session.prompt` 会被拒成 `internal: session "…" is owned by subagent routing`；唯一入口是 `subagents.prompt`（`subagent/src/index.ts:447`） |

- 父级从 `session.list` 行的 `parentSessionId` 取（`connector/src/dsh/sessions.ts` 的
  `resolveSessionAddress`），与 `session.page` 的地址**同一个出处**。
- 行的 `running` / `subagentTiming` / `tokenUsage` 也来自那一包行，而它只在
  **连上 / 建会话**时拉过 —— 所以手机侧补两个时机：**打开子智能体面板**与
  **当前会话的回合结束**（`AppModel.refreshSessionMetrics`）。不轮询。

## 2. 目录三态

三态分开是硬要求：`读到空` 与 `没读到` 的下一步动作不同（换地方找 vs 点重试）。

| 状态 | 判据 | 界面 |
|---|---|---|
| 加载中 | `state == loading` 且 `entries` 空 | 「正在加载子智能体…」 |
| 就绪 | `state == ready` | 行列表；`entries` 空 = **已知空叶** |
| 失败 | `state == error` | 「无法加载子智能体」+「重试」 |

- 已知空叶（`ready` 且空）是**唯一**敢说"它没有下级"的判据
  （`SubagentHeaderLineage.tsx:196-198` 的 `isKnownLeaf`）。
- 刷新时保留上一次的 `entries`（`loading` 且非空 ⇒ 照常显示内容、不闪空；
  同 Web `:244-245`）。
- 「重试」重读**那一层**（根级读根、子级读子级），不是重开整个抽屉。
- 原始错误文本进 `AppModel.lastError`；错误行只说用户能做的下一件事。

## 3. 行规格

一行 = 活动点 + disclosure + label + 第二行 + 右侧两行指标 + 行尾进入箭头。
出处：`SubagentHeaderLineage.tsx:235-373` 与同目录 `SubagentHeaderLineage.module.css`。

| 元素 | 取值 / 行为 | 依据 |
|---|---|---|
| 活动点 | 在跑 = 转圈（`ongoing`）/ 正常完成 = 绿（`done`）/ 其余 = 灰（`idle`） | `:336-338`，`ui/dsh_state_dot.dart` |
| 活动态 | `running` → 正在运行；停了且 `lastTurnCompleted` → 已完成；否则 → 当前未运行 | `:250-256`，`locales.ts:31-33` |
| 外部任务 | 不可进入、不可展开；第二行**没有** activity 段 | `:236,239,252,279-287` |
| disclosure | 可展开 = 非 external 且子级目录**不是已知空叶**；展开后箭头转 90° | `:242,325-334`，`module.css:214-216` |
| disclosure 占位 | 同层有任一行可展开时，不可展开的行也占一格 | `:213-216` 的 `reserveDisclosure` |
| label | 当前行 `w600`，其余 `w400`；单行省略 | `module.css:232-239` |
| 第二行 | `title · mode · activity`，空段整段不出；mode 词：一次性 / 可继续 / 外部任务 / 模式未知 | `:257-259`，`locales.ts:26-29` |
| token | 四桶之和（全零当作没给，不摆 `0 tok`）+ ` tok` 后缀 | `:66-74,260,268` |
| 时长 | `settledMs + (running ? now−since : active.through−since)`；没有 `active` 就是 `settledMs` | `:77-91` |
| 时长文字 | `59秒` / `1分05秒` / `1小时02分03秒` / `1天1小时` / `约1个月` / `约1年` | `:116-152`，`locales.ts:8-17` |
| 每秒走秒 | 可见行里有在跑的才起 1 秒时钟，没有就停 | `:205-211` |

**手势**：点行 = 进入那个子会话（`openChild` → `openSession`，
`ui-subagent/src/client/index.ts:61-63`）；点行尾的展开按钮 = 只展开（不进入）。
收起时**连带收起整枝**（`closeBranch`，`:556-568`），再展开会重新读一次该层目录。

**环保护**：某行的 id 已经出现在自己的祖先链上时（畸形投影才会有的形状），
那一行不再给展开按钮、递归也不再往下 —— 健康宿主的 catalog 是树，
而递归打穿栈是不可捕获的 `StackOverflowError`（整页白屏）。

### 3.1 触屏排布（**不是**把桌面的那一行缩小）

```
┌──────────────────────────────────────────┐
│ ●  调研实现                    12.3K tok ⌄│
│    可继续 · 已完成 · 1分05秒               │
└──────────────────────────────────────────┘
```

桌面那一行成立的前提是：鼠标能点 14px、窗口 336~600px 宽、10px 字号看得清。
手机右抽屉是 300dp、手指、DPI 高，三条都不成立，于是：

| 项 | Web | 手机 | 为什么 |
|---|---|---|---|
| 展开按钮位置 | label **左边** 14×17 槽（`module.css:186-216`） | 行尾，**44×44**（`ui/subagent_tree.dart` 的 `_SubagentRow.toggleSize`） | 手指点不中 14px；左侧小箭头紧贴整行的"进入"区，两种误触都会发生。右抽屉贴右缘，行尾正好是可拇指够到的一侧 |
| 预留展开槽 | `reserveDisclosure`（`:213-216`） | **不预留** | 那条规则是为了让左缘 label 对齐；这里左缘由活动点占住已经对齐，为 300dp 的行留 44dp 是纯浪费 |
| 右列 | 两行小字：token / 时长（`module.css:248-264`） | **只放 token 一个数** | 右列两行吃 70dp（23%），10px 小字在手机上既小又不齐；数字右对齐最好扫 |
| 时长 | 右列第二行 | 并进详情行（`… · 1分05秒`） | 它是"多久"的短语，与 mode / activity 读在一起更自然 |
| 缩进 / 树线 | 16 + 每行 12px 短横线（`module.css:288-329`） | **12** + 只画竖线 | 300dp 里每层 16 到第三层就吃掉 48dp；短横线是噪音 |
| 行字号 | 12 / 10 | 12.5 / 11 | 与右抽屉任务面板同一条偏离 |
| "进入"箭头 | 行尾另有一枚（侧栏按钮，`:356-373`） | **没有** | 整行都是进入区，行尾已经是展开按钮；同一侧两个箭头两个含义会读乱 |

## 4. 子会话顶栏

进入子会话后**没有额外的头部条**：那一层导航就在顶栏里（手机的主流形态 ——
"进入下一层"= 导航栏左侧返回，标题即位置）：

- 左侧 `←`（`chevronLeft`，tooltip「返回父会话」）—— 回到进来之前的那个会话
  （**导航记忆**，见下）。抽屉仍能从左缘跟手拖出，不丢入口。
- 标题 = **`父会话 › 子级名`**（父级 12px/tertiary，子级 13px/w500），右边一枚
  `chevronDown`；点它开「切换子智能体」底部 sheet。
  **放得下才带父级**：两个名字 + ` › ` + 箭头用 `TextPainter`（含 `textScaler`）
  量过顶栏剩余宽度，放不下就只留子级名 —— 硬塞会各截一半，
  而"我在哪个子智能体里"比"父级叫什么"要紧。
- 右侧不变：连接状态点 / 两枚计数 chip / `＋`。
- **系统返回键 = 同一条路**：按 Android 返回（手势/键）回父会话，
  而不是退出聊天页。判据是 `PopScope.canPop`
  （`packages/flutter/lib/src/widgets/pop_scope.dart:83-96`）；抽屉开着时不抢
  —— 抽屉自己挂了 `LocalHistoryEntry`（`packages/flutter/lib/src/material/drawer.dart:526-546`），
  而 `ModalRoute.popDisposition` 先看它（`packages/flutter/lib/src/widgets/routes.dart:942-947`）。

| 要素 | 规则 | 依据 |
|---|---|---|
| 左侧 | 子会话里 `panelLeft` → `chevronLeft`（`ui/dsh_app_bar.dart` 的 `onBack`） | — |
| 当前子级名字 | 父级 `subagentCatalog` 里**当前子级那一行**的 `label`（缺则 id）；找不到那一行才退回会话标题 | `SubagentHeaderLineage.tsx:490-495` |
| 父会话名 | 父会话行的 `displayTitle`（空 ⇒「未命名」）；**只在量得下时显示** | `:490-495` 的 `switcherDisplayTitle` + `displayTitle` |
| 标题宽度 | 子会话标题**不吃** `kDshTitleMaxWidth`：`Expanded` 给的就是右簇摆完的剩余宽度，由 `_SubagentCrumb` 自己量 | — |
| 切换目内容 | 父级的**直接子级树**（可再展开），当前行加粗 | `:802-821` |
| 选中兄弟 | 换主对话区（`openChild`），父级记忆不变 | `ui-subagent/src/client/index.ts:61-63` |
| 系统返回 | 子会话里回父会话；抽屉开着时先关抽屉；其余情况不拦 | `pop_scope.dart:83-96`、`drawer.dart:526-546` |

**父级从哪来**：`subagentCatalog` 的 view 不带 `parentId`
（`packages/subagent/subagent/src/catalog.ts:77-94`），所以父会话靠
**导航记忆**：点目录行进入时记下当前会话。子会话在会话列表里不列
（`packages/client/ui-workspace/src/client/tree.ts:238-245`），没有这条记忆就找不回来。

**有意偏离**（都是触屏决定，不是漏做）：

1. **导航就地在顶栏**，不另起一条 40dp 的 lineage 条：手机竖屏每一 dp 都是对话高度。
   DSH 的 lineage 是**桌面 header 里的一段**（`:802-821`），这里同样放进 header，
   只是左侧那枚从"抽屉开关"换成"返回"。
2. 切换用**锚定浮层**（`ui/dsh_popover.dart`），不用 Web 的 336px 浮层下拉
   （`module.css:91-102`）也不再用底部 sheet：手机没有 hover，所以复用的是
   **同一棵树**而不是 Web 的浮层实现；而面板必须**长在标题下方**——
   第一版用底部 sheet，用户 2026-10-21 当场否掉（"点击在上面，下面弹出你不觉得
   不跟手吗"）。判据是 `panel.top - crumb.bottom < 80`（`subagent_enter_test.dart`）。

## 5. 输入区只读（一次性 / 模式未知）

| 原因 | 判据 | 标题 | 正文 |
|---|---|---|---|
| 一次性 | catalog 行的 `mode == one-shot` | 一次性子智能体记录 | 一次性任务不支持后续消息，可在这里查看完整执行记录。 |
| 模式未知 | 没有 catalog 行 / `mode == unknown` | 此子智能体暂时只读 | 读取子会话后才能确定是否可继续。 |

出处：判据 `ui-subagent/src/client/index.ts:37-49`，文案 `ui-subagent/src/client/locales.ts:30,45-48`。

形状（`SubagentReadOnlyComposer.module.css:1-20`）：**一条横向框**，不是纵向卡片 ——
`min-height 54`、`padding 10/16`、`0.5px` 的 `borderL4`、圆角 `lg`、底色 `layer-1`、
字号 `13/20`、标题 `label-primary` + `w500`、正文 `label-tertiary`。

**有意偏离**：

1. **文字两行**（标题一行、正文一行），不是 Web 的并排 flex row ——
   390dp 上「一次性子智能体记录」+ 26 字正文并排会**交错换行**（各折各的，读起来是断的）。
   框的形状不变（54 高 / l4 发丝边 / layer-1）。
2. 左右边距 `8`，不是 Web 的 `24` —— 这一块顶替输入栏卡片，
   卡片外边距就是 `8`（`app/lib/ui/dsh_composer.dart` 的 `EdgeInsets.fromLTRB(8, 6, 8, 6)`），
   换 24 会在输入栏消失的那一瞬整块横跳。

## 6. 已知差异（不做，也不猜）

1. **`parentAvailable` 第三档（父会话离线 ⇒ 只读）**：该字段是 client session 的快照字段
   （`packages/api/session-controller/src/client/sessions/session.ts:75`），
   不在 `SessionSummary` / `session.list` 里。判它得先扩 Host 契约与连接器；
   在此之前 `continuable` 子会话一律显示可输入（可能被电脑侧拒绝，但不会假装"能发"）。
2. **右侧栏子智能体聊天（`openChildAside`）**：Web 在右侧栏内嵌同一个子会话
   （`ui-subagent/src/client/index.ts:64-69`）。手机不做：右下角抽屉里再嵌一个会话，
   300dp 宽读不了。入口本身留在目录行（点行进入主对话区）。
3. **`mock/proto/` 的子代理面板仍是平的演示列表**（`SUBS` 三条 + 进行中/已结束分组，
   `mock/proto/app.js` 的 `renderSubs`）。本期只改 Flutter 落地端；两边的结构差异
   在此登记，**面板结构以本文件与 `app/lib/ui/subagent_tree.dart` 为准**。
   同步原型要一起做：disclosure 展开、三态演示数据、token / 第二行指标，
   以及一个能跑通的验证脚本（`verify-proto.mjs` 现有项数不含子代理树）。

## 7. 验证

| 命令 | 覆盖 |
|---|---|
| `cd app && flutter test test/subagent_metrics_test.dart` | 活动态 / 时长 / token / 第二行（纯 Dart） |
| `cd app && flutter test test/subagent_panel_test.dart` | 目录三态 + `session.list` 行指标 + 不污染当前会话 |
| `cd app && flutter test test/subagent_tree_test.dart` | 树的渲染 / 两套手势 / 懒加载 / 收起整枝 / 走秒 |
| `cd app && flutter test test/subagent_enter_test.dart` | 进入 / 返回 / 切兄弟 / 只读状态框（跨层）/ **锚定浮层的落点**（`panel.top - crumb.bottom < 80`）/ **子会话发送走 `subagent.prompt`** |
| `cd app && flutter test test/subagent_metrics_refresh_test.dart` | **打开面板 / 回合结束各重拉一次 `session.list`**（否则真机上指标停在连上那一刻） |
| `cd app && flutter test test/side_pane_test.dart` | 右抽屉装配（子智能体面板 = 调用方给的树） |
| `cd connector && pnpm test` | 子会话地址（`resolveSessionAddress` / 订阅 / 翻页）与 `subagent.prompt` 的父级来源 |

### 7.1 真机验收（2026-10-21 晚，`DSH_HOME=D:\tmp\dsh-e2e`）

逐条判据与截图（截图在 `D:\tmp\dsh-e2e\shots-1021\`，**不进仓库**）：

| 项 | 结论 | 证据 |
|---|---|---|
| A1 目录 = 直接子级 | 过 | 面板只有 2 行（父会话目录 2 条），孙级不在里面 |
| A2 行 = 活动点 + 标题 + `title · mode · activity · 时长` + `N tok` + 行尾展开 | 过 | `b06-popover.png`；展开按钮 bounds `[965,361][1080,477]`（44dp） |
| A3 展开才加载 / 已知空叶无展开按钮 | 过（孙级未造出） | 点开子级后它的展开按钮消失（目录读回空）；宿主 `maxDepth` 默认 1，派不出孙级 |
| A4 跑完变绿 + 已完成 + 时长定格 | 过 | 隔 32 秒两帧数字相同（`b14` / `b15`）：`49秒` / `1分42秒` |
| A5 顶栏 running 跟着子会话状态变 | 过 | 采样到 `1 个子智能体，正在运行`（21:25:26），其余时刻是 `N 个子智能体` |
| A6 一次性子会话只读框 | 未造出 | 本 profile 两个 in-process 后端都只产 `continuable`；只读框由单测覆盖 |
| B1 `☰→←` + `父会话 › 子级`（放不下只留子级） | 过 | `c04`；长父名时只留子级名（量宽判据在 `_SubagentCrumb`） |
| B2 切换面板选兄弟，`←` 仍在 | 过 | 切到 `Nested subagent: 2+2` 后仍显示「返回父会话」 |
| B3 系统返回键回父会话 | 过 | 子会话里返回 → 父会话标题 + `☰` |
| B4 子会话里左缘拖出抽屉 | 未验 | adb 左缘滑动被 MIUI 系统返回手势吃掉（与 `tools.md` 2026-10-18 同一条），需手指实测 |

同一轮修掉的真机缺陷（缺陷与判据见
`.agents/notes/implemented/2026-10-21-subagent-child-address-and-prompt.md`）：
子会话白屏、子会话发不出消息、面板指标只在重连后更新。

### 7.2 真机验收（2026-10-21 深夜，同一实例，**最终包只装一次**）

`flutter build apk --debug` + `adb install -r`（`firstInstallTime` 不变、`lastUpdateTime` 更新）。
截图在 `D:\tmp\dsh-e2e\shots-1021b\`，**不进仓库**。

| 项 | 结论 | 证据 |
|---|---|---|
| E1 顶栏连接点 → 面板长在点下面 | 过 | `e01c-popover.png`：点 `[870,127][970,227]`，面板首行 `[103,473]`；面板顶边 = 点下沿 + 6dp（测试判据 `panel.top - anchor.bottom < 80`） |
| E2 会话行菜单锚在那一行下面 | 过 | `e02-row-menu.png`：行 `[21,941][908,1112]`，菜单标题 `[68,1159]`（差 47px ≈ 17dp）；触发从长按改成行尾「…」 |
| E3 拖动排序（会话 / 工作区） | **过（2026-10-22 补验）** | 数据条件：同一工作区（`dsh-mobile`）两条可见会话 `Nested Subagent Spawn Test` / `Greeting`。手势用 `sendevent`（本机 root；`input` 那一套做不出落点，recipe 见 `tools.md`）：拖 `Greeting` 到 `Nested` 上半 ⇒ dedupe 出现 `mv-1792606235984569`、返回顺序 `[Greeting, Nested, mGa8Bb…]`，抽屉同步；拖项目头 ⇒ `workspaceIds` 从 `[dsh-e2e, dsh-mobile, …]` 变 `[dsh-mobile, dsh-e2e, …]`。截图 `e40-root-session-drag.png`（拖动中：源行淡出 + chip 跟手） |
| F1 一次性子会话只读框（A6） | 未造出 | 本 profile 两个 in-process 后端（`subagent-spawn-in-process` / `-fork-in-process`）都只产 `continuable`；只读框由单测覆盖 |
| F2 孙级（A3，`maxDepth: 2`） | 过 | `f03-panel-root.png`：根只有 1 行（直接子级）+ 行尾 44dp 展开钮；`f04-panel-expanded.png`：展开后出现孙级行「Reply with fixed text」，它自己再带展开钮（已知空叶） |
| G 子会话里左缘拖抽屉（B4） | 过 | `g03-child-drawer.png` / `g04-child-after-drawer.png`：在子会话里从 `x=40,y=300` 慢拖（落在 gesture-exclusion 的**上半屏**边带）抽屉跟手出来；关掉后标题仍是「Spawn grandchild, report result」、`←` 仍在 |
| D1 附件（＋→照片→芯片→发送） | **过** | 根因是**模型配置**：`llm-pi-ai` 的模型条目不声明 `input` 时，DSH 按 `DEFAULT_INPUT = ['text']`（`packages/llm/llm-pi-ai/src/config.ts:74`）在**发送前**拒成 `Model "auto" does not support image input.`。profile 补上 `input: [text, image]` 后：芯片清空、新轮次起来（`d14-after-modality.png`），电脑侧会话日志里 `user/message` 的 content 有 **6 处 `{"type":"image"}`**，且模型的回复**读出了截图内容**（"984.png — 连接菜单浮层：当前连接 中转 · ws://127.0.0.1:8787/ws/connector…"，`d15-child-chat.png`） |
| D2 历史翻页（快照一页 100 条） | 未造出 | 本实例没有 >100 条事件的会话；造够真历史要 8~12 个真实轮次 |
| D3 异常结局 / 重试 / 压缩标记 | 未造出 | 没有稳定制造**失败**回合的手段（取消 ≠ 失败）；压缩标记本轮未出现 |
| H1 设置页 | 过 | `h01-settings.png`：通用 / 模型 / 连接方式三组都在；端点列表带「当前连接」「首选」「还没试过」 |
| H2 归档→取消归档闭环 | 过 | `h04-archived.png`（未分组 3→2、行从抽屉消失）→ `h05-archive-page.png`（归档页列出 Greeting）→ `h06-unarchived.png`（"暂无已归档会话"）→ `h07-back-in-list.png`（未分组回到 3、行回到抽屉） |
| H3 连接操作三个入口 | 过 | `e01c-popover.png`：重新连接 / 重新配对 / 断开并清掉凭据三项都在（未真点断开） |

**同一包上的其它证据**：容器中转端到端（配对 → 会话列表 → 发一句 → 收到回复）见
`docs/cookbook/relay-on-a-server.md` 的「本机容器验证」；`flutter test` 1009 项全绿。

### 7.3 静态审查（真机造不出来的条目，2026-10-22）

用户要求："验证不了的先静态审查，看逻辑差不多吧"。逐条读代码的结论：

| 项 | 静态结论 | 依据 |
|---|---|---|
| A6 一次性子会话只读框 | **逻辑成立** | 判据是 catalog 行的 `mode == one-shot`，与 `continuable` 分两支；`subagent_enter_test.dart` 两条用例（一次性 / 模式未知）都在跑。未造出只是本 profile 的后端只产 `continuable` |
| D2 历史翻页 | **发现缺口** | 翻页本身两端都全：连接器有 `session.page` + `refetchThresholdBytes`（默认 1 MiB，`connector/src/config.ts:61`）与 `session.refetch`（`handlers.ts:1001`）；手机侧 `recovery.dart` 会按 `hasMore` 累积快照。**但 `sync_client_impl.dart:956` 把 `refetch` 项直接跳过、从不调 `session.refetch`** ⇒ 超过 1 MiB 的条目会在会话里留下一个**静默的洞**（不报错、不缺页、就是少一条） |
| D3 异常结局 / 重试 | **结局成立；"重试"入口不做** | `TurnOutcomeKind` 四档都有渲染（`chat_turns.dart:697` 的 error/interrupted/maxTokens/signedOut）；自动重试有 `ModelRetryItem` 的 `RetryRow`（`:741-768`）。查了 DSH Web：`ui-conversation` 里**也没有"手动重试失败回合"的入口**，所以这不是我们对齐漏了，**不做** |
| E3 拖动排序 | **逻辑成立** | 纯函数 `dropAnchorInDisplayOrder`（拖到自己 / 跨分区 / 顺序没变都返回 null）+ 5 条模型用例 + 3 条抽屉交互用例；真机未验只是"同一工作区两条可见会话"这个数据条件凑不出 |
