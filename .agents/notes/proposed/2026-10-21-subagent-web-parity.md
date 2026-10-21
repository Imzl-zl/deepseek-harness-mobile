# 子智能体页：Web 设计/功能对照与实施清单

Status: proposed（**本轮只记录与对照，不改代码**；实施在新会话按 §7 的提示词走）

## 0. 范围

用户 2026-10-21 问「这个你看 web 的设计和功能是啥样的……你先记录一下，然后根据记录再对照一下」。
范围限定为**子智能体入口、目录、子会话页头部、输入区**；不含左侧会话列表（子智能体本来就不列）。

## 1. Web 事实（全部有行号）

### 1.1 入口：点行 = 整页切换，行尾按钮 = 右侧栏

- 目录行点击 `open()` → `openChild({parentSessionId, childSessionId, mode})`
  （`SubagentHeaderLineage.tsx:279-287`）。
- `openChild` 调 `ctx.uiWorkspace.openSession(address)`
  （`ui-subagent/src/client/index.ts:61-63`）。
- `openSession` 走 `replaceMain(target, signal, 'reveal')`
  （`ui-workspace/src/client/navigation.ts:276-278,499-529`）——
  **主对话区换成子会话**，不是新路由、不是弹层。
- 行尾另有一枚 `sidebarButton`，点击 `openChildAside`
  （`SubagentHeaderLineage.tsx:356-373`）→ `sidebarRight.openResource(...)`
  （`ui-subagent/src/client/index.ts:64-69`），在右侧栏打开同一个子会话
  （`sidebar-chat/index.tsx:120-202`）。**这是第二个入口，不是默认入口。**
- 子智能体在左侧会话树里**不列**：`sessionVisible` 对 `origin === 'subagent'`
  直接 `return false`（`ui-workspace/src/client/tree.ts:238-245`）。

### 1.2 根会话头部：只显示目录，不显示 lineage

- `SubagentCatalogAction` 在 `conversation.session.header.actions`
  （`ui-subagent/src/client/index.ts:82-93`）；子会话上返回 `null`
  （`SubagentHeaderLineage.tsx:760-778`）。
- 触发器是「N 个子智能体」（运行中时是「N 个子智能体，正在运行」），
  带活动点和下拉箭头（`SubagentHeaderLineage.tsx:667-716`）。
- 下拉是 `CatalogDropdown`，根会话为 `variant="count"`，菜单宽 **336px**、
  最大高 **min(560px, 100vh-140px)**、圆角 lg、内边距 4
  （`SubagentHeaderLineage.module.css:91-102`）。

### 1.3 子会话头部：父级 switcher + 自己的子级计数

- 子会话的 `SubagentHeaderLineage` 从 `session.subagent.address` 或
  `subagentCatalog` 反查 `parentId`（`SubagentHeaderLineage.tsx:785-798`）。
- 有父级时渲染两个东西（`:802-821`）：
  1. `variant="switcher"`，`rootSessionId = parentId`，当前子会话高亮；
     触发器标题是**当前子级 label**（拿不到才退回会话标题），最大宽 244px，
     `12/18`、`label-primary`、`w500`（`SubagentHeaderLineage.module.css:33-52`）；
  2. 当前子会话自己的 `variant="count"`（如果它还有下级）。
- 没有父级（根会话）时 lineage 返回 `null`（`:799-801`）。

### 1.4 目录树：直接子级 + 按需展开

- 投影 `subagentCatalog` **只含直接子级**：
  「current direct-child rows in parent catalog event order」
  （`packages/subagent/subagent/src/catalog.ts:117-128`）。
- 行展开才去读那个子会话自己的 catalog：
  `toggleBranch(childSessionId)` → `refreshProjection(childSessionId)`
  （`SubagentHeaderLineage.tsx:570-577`）；`CatalogRows` 递归渲染
  （`:201-...`，children 块在 `:376-...`）。
- 空/加载/错误三态分开：
  - `emptyLoading` → 「正在加载子智能体…」（`:190-193,219-221`）；
  - `state === 'error'` → 错误原文 + 「重试」按钮（`:222-234`）；
  - `isKnownLeaf` 只在**子级 catalog 成功且为空**时成立（`:195-198`）。
- 行结构（`:235-373`）：
  - 左侧 14px 活动点（running/inactive/completed）；
  - 14px disclosure 槽；有下级且未确认空叶时可展开；
  - label（当前行 `font-weight:600`，`:237-239`）；
  - 第二行 `summary.title · mode · activity`（`:248-259`）；
  - 右侧两行 metrics：token 总数 + 真实耗时（`:260-277`）；
  - 行尾 `sidebarButton`（28×28，`:266-286`）。
- 缩进：children `margin-left:16px; padding-left:3px`，带树线
  （`SubagentHeaderLineage.module.css:288-295`）。
- 行高 44px、padding `6px 7px 6px 9px`、gap 6、行本体 **12/17**（`:139-155`）；
  label 继承行字号，summary/metrics 是 **10/15**（`:218-255`），这是桌面密度。

### 1.5 子会话页本身

- 正文、头部、统计条都是普通 conversation（`openChild` 只换 main selection，
  不换页面组件）；子会话不是独立路由。
- 头部 switcher 可以切到父级下的其他子级；根会话的目录下拉不出现
  （子会话上 `SubagentCatalogAction` 为 `null`，见 §1.2）。
- 输入区按 `selectReadOnlySubagent` 接管（`ui-subagent/src/client/index.ts:37-49`）：
  - `one-shot` → 只读；
  - `unknown` → 只读；
  - `parentAvailable === false` 且子会话已停 → 只读；
  - 可续聊且父级可用（或正在跑）→ 正常 composer。
- 只读 UI 是**一条横向状态框**：`min-height:54px; margin:0 24px 20px;
  padding:10px 16px; border:0.5px border-l4; radius:lg; bg:layer-1;
  font:13/20`，`strong` 用 primary/510（`SubagentReadOnlyComposer.module.css:1-22`）。
- 文案逐字：
  - 一次性：「一次性子智能体记录 / 一次性任务不支持后续消息，可在这里查看完整执行记录。」
  - 未知：「此子智能体暂时只读 / 读取子会话后才能确定是否可继续。」
  - 父级不可用：「此子智能体暂时只读 / 父会话当前不在线，重新打开父会话后即可继续发送消息。」
  （`ui-subagent/src/client/locales.ts:55-60`）

### 1.6 右侧栏版本（可选入口）

- `SidebarChat` 用 `sessions.retain(address)` 拿同一个子会话引用，
  内嵌普通 conversation（`sidebar-chat/index.tsx:102-117,125-168`）。
- 手机是否做，见 §6 的取舍；**不是本次必做**。

## 2. 手机现状（文件 + 行为）

| 面 | 现状 | 文件 |
|---|---|---|
| 入口 | 右抽屉子智能体行 → 关抽屉 → `openSession(child)`；主对话区切换 | `app/lib/ui/chat_page.dart` `_openSubagentSession` |
| 返回 | 内容区上方 34px 面包屑「← 返回上一个会话 / 正在查看子智能体」，只有返回，无标题、无兄弟切换 | `chat_page.dart` `_SubagentBreadcrumb` |
| 目录数据 | `session.projections` 的 `subagentCatalog` **只取当前会话直接子级**；`Map<sid, List<SubagentRow>>` | `app_model.dart:672-679`、`core/job.dart:207-230` |
| 目录行 | 复用 `_JobPanel`：44px、状态点、label/状态两行或一行、时长、chevronRight；无 token、无 title 副行、无展开、无 loading/error | `ui/side_pane.dart` `_JobPanel` / `_JobRow` |
| 分组 | `isLive` 决定「进行中 / 已结束」；子智能体的 `isLive` 来自 mode | `core/job.dart:190-200` |
| 顶栏 | 子智能体计数 chip 取当前会话 catalog；点开右抽屉 | `chat_page.dart` `_subsFor`、`dsh_app_bar.dart` |
| 输入区 | 已补 `one-shot`/`unknown` 只读说明；`continuable` 保留 composer | `chat_page.dart` `_subagentReadOnlyReason`、`_SubagentReadOnlyNote` |
| 父级离线 | 未判（`parentAvailable` 不在 `session.list` 字段里） | 同文件注释 |
| 测试 | 进入/返回 + 一次性只读；面板数据解析；两步停 | `subagent_enter_test.dart`、`subagent_panel_test.dart`、`side_pane_test.dart` |

### 2.1 数据其实够用，不需要新方法面

- `session.list` 的行已经**原样透传** `projections.values`
  （`connector/src/handlers.ts:527-533`）；其中就有子会话的
  `subagentTiming` / `tokenUsage` / `title`。
- 手机目前只从 `projections.values.title` 取了标题，其他值丢了
  （`app_model.dart:2483-2531`）。
- 子会话自己的 catalog 可以用现有 `session.projections(sid)` 读；
  **不需要加 connector 方法**。
- 但 `AppModel.refreshProjections(sid)` 会无条件覆盖 `_projections`
  （当前会话那一包，`app_model.dart:460-484`）；给嵌套目录用会污染当前会话的
  统计/标题。实施时要拆成「当前会话投影」与「目录投影」两个入口，或只在
  `sid == currentSid` 时覆盖 `_projections`。

## 3. 对照结果（按优先级）

| # | 差距 | Web | 手机 | 判定 | 优先级 |
|---|---|---|---|---|---|
| 1 | **活动态错误** | `running` 来自会话状态；one-shot 结束是 completed，continuable 结束是 inactive | `SubagentRow.status` 由 mode 推出：one-shot=completed，其余=running；`isLive=mode!='one-shot'` | **真缺陷**：可续聊子会话跑完后，面板/顶栏仍显示「正在运行」，分组也永远在「进行中」 | P0 |
| 2 | **耗时是假增长** | `subagentTiming.settledMs + active`，结束取 `active.through` | `finishedAt ?? now`，而 `finishedAt` 从未从投影解析 | **真缺陷**：一次性任务时长永远涨 | P0 |
| 3 | 没有 token | 行右侧 `N tok`（`tokenUsage` 四桶求和） | 无 | 功能缺失 | P1 |
| 4 | 第二行信息不足 | `title · mode · activity` | 只有 mode 词（一次性/可续聊） | 功能缺失 | P1 |
| 5 | 不能展开嵌套 | 直接子级 + 按需 `refreshProjection(child)` 递归树 | 只有当前会话直接子级，平铺 | 功能缺失 | P1 |
| 6 | 空/加载/错误不分 | loading / error+retry / empty 三态 | 只要 `subagentsOf` 为空就「没有子智能体」 | 功能缺失（与项目「空有两种表达」纪律冲突） | P1 |
| 7 | 子会话头部没有 switcher | 父级 catalog 的 switcher + 当前子级高亮；能切兄弟 | 只有「返回上一个会话」，不能切兄弟 | 功能缺失（但比 Web 的桌面下拉更适合触屏的做法可以再定） | P1 |
| 8 | 只读说明版式不同 | 54px 横向状态框，13/20，strong + body | 12px 纵向卡片，标题/正文两行 | **有意偏离未写明**；建议按 Web 的横向框对齐，触屏边距用 12 而不是 24 | P2 |
| 9 | 父级离线只读未判 | `parentAvailable === false` 且已停 | 未判 | 已知差异，需数据面决策 | P2 |
| 10 | 右侧栏子智能体聊天 | `openChildAside` 独立入口 | 右抽屉只有目录，没有子会话聊天 tab | 可选；当前设计未要求 | P3 |
| 11 | 目录容器 | 336px 浮层下拉 | 右抽屉 300px 面板 | **有意偏离**（设计 §7.8：手机右抽屉三个面板）；保留 | — |
| 12 | 行字体 | 10/15 桌面密度 | 12.5 / 11.5 触屏密度 | **有意偏离**；但结构（缩进、两行、metrics）要补 | — |

### 3.1 已经对齐的

- 点行 → 主对话区切到子会话（不是弹层）；子智能体不进左侧列表。
- 一次性 / 未知模式输入栏只读；可续聊保留 composer。
- 顶栏有子智能体计数 chip；右抽屉有子智能体面板。
- 子会话返回父会话的导航记忆已存在（面包屑）。

## 4. 关键设计判断（实施前先认）

1. **不要为了 Web 的浮层把手机右抽屉改掉**。设计 §7.8 已定：右抽屉三个面板
   （文件/任务/子代理），手机没有 hover，浮层下拉不如抽屉稳。要补的是**抽屉里的树**，
   不是换容器。
2. **目录树的数据是“直接子级 + 懒加载”**，不是一次拉全量。手机也应这样：
   展开某个子级才 `session.projections(child)`；不要为“全树”新增方法。
3. **状态不能用 mode 代替**。mode 是“能不能续聊”，running 是“此刻跑没跑”；
   两者是不同维度。`SubagentRow` 现在把二者混成 `status`，是这次最该先修的。
4. **耗时/token 来自子会话的投影提示**，不是手机本地计时；`session.list` 已经带了。
5. **父级 switcher**：手机不需要照 Web 的 336px 下拉，但子会话页至少要能
   “返回父会话 + 在同一父级下切换兄弟”。建议用底部 sheet（复用目录树）。
6. **`parentAvailable` 不猜**。要判它得先扩 `session.list`（Host client 快照字段），
   当前没有证据表明手机遇到过这一档；先不做，写进已知差异。

## 5. 实施顺序（新会话按这个走）

### P0：先修“假状态 / 假耗时”（不改布局）

- `core/job.dart`：把 `SubagentRow` 拆成**目录事实**（id/mode/label/createdAt）
  与**运行态视图**（running/activity/durationMs/tokens/title）；或者保留
  `SubagentRow` 但把 `status/isLive` 改成由外部传入，不再从 mode 推。
- `app_model.dart`：解析 `session.list` 行里的
  `projections.values.subagentTiming` / `tokenUsage`；给 `SessionSummary`
  加可选字段（或单独的 `SubagentMetrics` 映射，key=sid）。
- `chat_page.dart` `_subsFor`：用子会话 `SessionSummary.running` 决定
  `activity`，用 `subagentTiming` 算 duration；不要再用 `finishedAt ?? now`。
- 验收：可续聊子会话结束后，面板从「进行中」移到「已结束」；一次性任务时长
  不再增长；顶栏 running 计数与子会话状态一致。

### P1：目录树 + 三态

- `SidePane` 子智能体面板改成树：行有 disclosure（有未知下级才显示）、
  children 缩进 16px + 树线；点行仍进入，点 disclosure 只展开。
- 新增 `AppModel.refreshSubagentCatalog(sid)`：只写 `_subagents[sid]`，
  并在 `sid == currentSid` 时才写 `_projections`；维护
  `loading/ready/error` 状态。空 catalog 与“没读到”分开。
- 行右侧补 token 总数 + 真实时长；第二行补 `title · mode · activity`；
  当前行（父级 switcher 里）加粗。
- 错误态给「无法加载子智能体」+ 重试（照 Web 文案）。
- 验收：展开子级能看到孙级；空叶不显示 disclosure；错误可重试；不触发
  当前会话统计/标题被覆盖。

### P2：子会话头部 + 只读版式

- 面包屑升级：显示当前子级标题 + 「切换子智能体」入口；sheet 里列出父级
  直接子级（可展开嵌套），并保留「返回父会话」。
- 一次性/未知只读说明改成 Web 的横向状态框：strong + body 一行，13/20，
  边框 l4，圆角 lg，背景 layer-1；触屏边距用 12。
- 验证：进入一次性子会话，输入栏不再出现；返回父会话/切兄弟都正常。
- `parentAvailable` 保持不判，写进已知差异。

### P3（可选，先不做）

- 右抽屉加「子智能体聊天」tab，对应 Web 的 `openChildAside`。
- 需要先想清“右抽屉已有目录 + 再嵌一个 conversation”的返回栈和宽度；
  当前设计没有这个要求。

## 6. 验收清单

- [ ] 可续聊子会话结束后：面板显示「已结束」、activity 是「当前未运行」；
      顶栏 running 计数不包含它。
- [ ] 一次性子会话：时长固定为执行时长，不再每秒增长；token 有值（拿得到时）。
- [ ] 展开子级：发出 `session.projections(childSid)`，只更新该子级的目录；
      当前会话的统计/标题不变。
- [ ] 空目录：显示「没有子智能体」；读取失败：显示错误 + 重试，不伪装成空。
- [ ] 子会话页：面包屑有当前标题 + 切换入口；能返回父会话、能切兄弟。
- [ ] 一次性/未知子会话：输入栏只读说明，键盘不弹；可续聊仍可发。
- [ ] `dart analyze --fatal-infos lib test` 0；`flutter test` 全绿；
      `node app/tools/verify-platform-boundary.mjs` 300 项。
- [ ] 原型是否需要同步：本轮只改手机端；`mock/proto` 的子智能体面板是
      演示数据，若交互形态变化（树/展开），同步更新 `verify-proto` 或新增
      脚本；**不允许两端各自漂移**。

## 7. 新会话提示词（复制这一段）

```text
项目：dsh-mobile（Windows / PowerShell；工作区 D:\sudy\myproject\dsh-mobile）。
先读根 AGENTS.md、mock/proto/AGENTS.md、tools.md、memory.md，以及
.agents/notes/proposed/2026-10-21-subagent-web-parity.md（本任务的规格与差距清单）。

目标：按 DSH Web 的子智能体设计/功能，补齐手机端（Flutter）子智能体页的
渲染与状态，不改方法面（不加 connector 方法）。

已核实的 Web 事实（以笔记里的行号为准）：
- 点目录行 = openChild → uiWorkspace.openSession(address)，主对话区切换；
  行尾小按钮才是右侧栏 openChildAside。
- 根会话头部是「N 个子智能体」目录下拉；子会话头部是父级 catalog 的
  switcher + 当前子会话自己的下级计数。
- catalog 投影只含直接子级；展开子级才 refreshProjection(child) 懒加载；
  有 loading / error+retry / empty 三态。
- 行 = 活动点 + disclosure + label + 「title · mode · activity」+ token + 真实耗时；
  当前行加粗；children 缩进 16px。
- 输入区按 selectReadOnlySubagent：one-shot / unknown / 父级不可用且已停
  三种只读；Web 的一次性/未知文案和横向状态框见笔记 §1.5。

当前手机端问题（先修 P0）：
1. core/job.dart 的 SubagentRow.status/isLive 由 mode 推出：
   one-shot=completed，其余=running。可续聊子会话结束后仍显示「正在运行」。
2. _subDuration 用 finishedAt ?? now，而 finishedAt 从未解析；一次性时长一直涨。
3. session.list 已经原样透传 projections.values（含 subagentTiming/tokenUsage/title），
   但 app_model 只取了 title；需要解析并挂到子智能体视图。
4. 目录只有直接子级、平铺；无展开、无 loading/error、无 token、无第二行 title。
5. 子会话页只有「返回上一个会话」，没有父级 switcher / 兄弟切换。
6. 一次性/未知只读说明是纵向卡片，Web 是 54px 横向状态框。

实施顺序：
P0 状态与耗时正确（不碰布局）→ P1 目录树 + 三态 + token/第二行 →
P2 子会话头部 switcher + 只读版式 → P3 可选（右侧栏子智能体聊天，先不做）。
不要改右抽屉为浮层（设计 §7.8 已定）；不要为 parentAvailable 扩方法面，
保持“不猜”，写进已知差异。

约束：
- 改源码只用编辑工具，不用 shell 字符串替换。
- 每个新行为补测试；至少跑 dart analyze --fatal-infos lib test、
  flutter test、node app/tools/verify-platform-boundary.mjs。
- 如果改了 mock/proto 的交互，跑 node mock/proto/tools/verify-icons.cjs +
  verify-proto.mjs；图标只走 DshIcons。
- 完成前回读 diff：检查死代码、第二真值源、假数据、未接线回调；
  交付时给出实际命令与项数，不用“应该没问题”代替。

交付：P0+P1+P2 的实现与测试；一份 implemented 决策笔记；
最终报告含 Web 依据（packages/...:行号）、改了哪些文件、门禁数字、
仍未做的差异（parentAvailable / 右侧栏聊天）。
```

## 8. 未决问题（实施前若用户没答，按推荐做）

1. **子会话头部 switcher 的触屏形态**：推荐底部 sheet（复用目录树），
   不照 Web 的 336px 浮层下拉。理由是手机没有 hover，且右抽屉已经承担目录。
2. **嵌套展开的深度**：catalog 是任意层，但手机右抽屉宽度有限；推荐只展开
   显式点击的层级，默认全收起（与 Web 相同）。
3. **`parentAvailable`**：推荐暂不做；要做就先扩 `session.list` 契约，而不是
   在手机侧根据 `continuable` 猜。
4. **右侧栏子智能体聊天**：推荐 P3 或不做；若做，需要单独的设计（宽度、
   返回栈、与右抽屉目录的关系）。
