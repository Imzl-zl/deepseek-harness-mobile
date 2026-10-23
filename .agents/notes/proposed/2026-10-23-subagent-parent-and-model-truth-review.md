# 审查清单：子会话父级 / 模型真值 / 投影归属（`7806b2a` `173e1e2` `fb1b31e`）

Status: proposed（**清单，不是决定**；每条都带证据、判据与"别这么修"，用户点头才动代码）

用户 2026-10-23 要求对三笔提交做只读审查并整理成开工单，并指定三条实施约束：
**规范标准 / 用 DSH 原生能力 / 实施要优雅**（可判定口径见 §5）。

审查是只读的：没改代码、没跑门禁、**0 个真机回合**。证据全部是源码与文档的交叉引用，
引 DSH 的一律给 `packages/...:行号`。

> **本文件自足**：新会话只靠这份清单 + 文末 §9 的提示词就能开工，**不依赖上一轮的对话记录**。
> 11 条全部逐条展开（4 条 Important 四格 + 7 条 Minor 四格），没有"见上文"式省略。

## 0. 结论（先看这段）

- **无 Critical**。两条"会错给用户看"的形态都带前置条件，落在 Important。
- **4 条 Important**：I1（模型）、I2（父级 + 只读档）改代码；I3、I4 改文档。
- **7 条 Minor**：规范与过期注释，不改也不会错。
- **两条代码项是同一个病根**：同一个事实有两处取数 ——
  模型有 **state 与 wire view 两套键名**，父级有 **"树知道"与"全表扫描猜"两条路**。
  所以两条都按"收成一个真值"来修，不是加判断。
- **建议先修 4 条**（I1、I2 改代码；I3、I4 改文档），Minor 随后按文件合并 ——
  理由：I1/I2 是"下次一定错"的根，I3/I4 是 3 行的事，顺手清掉免得下轮照着错文档改。

### 0.1 资产：这五条已经成立，修的时候别退回去

| 已核事实 | 判据（可复核） |
|---|---|
| 「在不在子会话里」只剩一个判据 | `_subagentParentSid` 被 `←` / `PopScope.canPop` / 发送方法 / 顶栏标题 / 切换面板 root / `_returnFromSubagent` 六处共用（`chat_page.dart:477,528,637,642,645,1246,1326`） |
| 只读框不会出现在根会话上（反向矛盾不存在） | 闸门是 `_subagentReturnFrom != null`，它与 `_subagentChildSid` 同批写；`openSession` 第一行同步改 `_currentSid`（`app_model.dart:2486`）⇒ 记忆非空时第 3 档必然给出父级 |
| 四条重建路径都留住 `parentSid` 与 `model` | `chat_item.dart:788-793`（构造）/ `:923-941`（copyWith）/ `:954-989`（withCounters + withTitle） |
| `_projections` 私有直读清零 | 全文只剩两处赋值（`app_model.dart:588-589`）与 getter（`:466-467`），10 处读取全走 getter |
| `session.list` 不漏 DSH 原始 id | 父级过 `aliases.ensure`（`handlers.ts:566-569`）；测试钉"别名形式 + 根会话没有这个键"（`handlers.test.ts:810-830`） |

## 1. 定级口径

| 级别 | 判据 |
|---|---|
| Critical | 现在就会错给用户看 / 数据不一致 |
| Important | 现在不错但下次一定错：错键名、错来源、文档与代码相反 |
| Minor | 规范、可读性、过期注释；**不改也不会错** |

## 2. Important（4 条）

### I1. `modelOf` 拿"线格式的键"去读"投影的 state" ⇒ 顶层 `model` 永远只是 lastUsed

**证据**
- `connector/src/dsh/models.ts:120-121`：`const view = projections.stateOf(session,'modelSelection'); const picked = view?.next ?? view?.lastUsed`。
- 同文件 `:43-55` 把 `stateOf` 的返回**声明成线格式** `ModelSelectionProjectionView {lastUsed?, next?}` ——
  这个本地端口类型就是 `tsc` 抓不到它的原因。
- DSH 权威形状：`stateOf` 返回**宿主 state**（`packages/session/session-projection/src/index.ts:312-328`，
  原文 "Read one unit's current host state"）；`modelSelection` 的 **state schema 是
  `{lastUsed, pending}`**（`packages/api/session-controller/src/model-selection-projection.ts:19-22`），
  **只有 `wire.view` 把 `pending` 映射成 `next`**（`:63-65`）。
- 所以 `view.next` 恒 `undefined`，`??` 永远落到 `lastUsed`。文件头 `:20-21` 自己写着
  "投影的线格式是 `view: state => ({lastUsed, next})`" —— 知道形状，读错了那一层。
- 测试替身复现了**错误形状**：`connector/tests/models-face.test.ts:121-144` 让 `stateOf`
  返回 `{lastUsed, next}`，"next 优先"那条断言在假数据上绿。

**影响**
- 顶层 `model` 实际语义 = "上一次请求用的"，与三处文档承诺的 `next ?? lastUsed` 不一致
  （`app/lib/model/chat_item.dart:852-858`、`models.ts:75-81`、笔记
  `implemented/2026-10-23-subagent-composer-model-and-mode-source.md` §改法）。
- 今天被 App 的新第一档遮住（`app/lib/data/app_model.dart:3149-3151` 先取投影提示）。
  但笔记把顶层 `model` 定为**第二档（老连接器兜底）** —— 这一档是坏的：老连接器上刚切完
  模型，手机芯片显示旧模型，直到跑完一轮。
- 任何以后读 `session.list` 的 `model` 的人（第二个客户端、诊断脚本）都会拿到与文档相反的值。

**建议**
1. 必做：让连接器读**同一个线格式** —— `snapshot(session, ['modelSelection']).values.modelSelection`
   （DSH 的 wire view，`session-projection/src/index.ts:330-345`，同步方法），取值表达式与 App 的
   `_modelSelectionOf` 逐字相同（`next ?? lastUsed`）；端口类型跟着改成 snapshot 形状。
   若不想用 `snapshot`，退路是把端口类型改成 `{lastUsed, pending}` 并取 `pending ?? lastUsed`
   —— 两条都行，**不许**保留"类型说 next、运行时是 pending"的现状。
2. 测试替身改成**真形状**（`stateOf` 返回 state / `snapshot` 返回 view），补一条"pending 非空 ⇒ 返回 pending"。
3. 可选、需单独决定（不在本轮）：顶层 `model` 与 `projections.values.modelSelection` 已是同一事实，
   `modelOf` 每行一次 `sessionOf + agents.get + materialize` 是纯重复。最小一步是让 `session.list`
   从**同一行的 hints** 派生 `model`（零额外读）；删掉线上字段是契约变更，不顺手做。

**代价**：2 个文件（`models.ts` + `models-face.test.ts`），约 15 行；跑
`pnpm exec tsc --noEmit && pnpm build && pnpm test`（586 项）。变异校验：把 `pending` 换回
`lastUsed` ⇒ 恰好那条红。换来的是"模型只有一个形状、两个读者同一表达式"。

### I2. 父级与 mode 都在**回查目录**，而 mode 本来就在手里 ⇒ 刷新窗口里点孙级会显示「暂时只读」

**证据**
- `app/lib/ui/chat_page.dart:1298-1306`（`_switchSibling`）与 `:1150-1155`（`_openSubagent`）
  都做同一件事：拿**已经持有的那一行**的 id，回目录里再查一次 `mode`：
  `catalogOf(x).entries.where((row) => row.id == node.id).firstOrNull?.mode`。
  而 `node.row.mode` 就是那一行的 mode（`app/lib/model/subagent.dart:176-192`，
  `SubagentRow.mode` 非空 `String`）—— 这是一次纯冗余回查。
- `_switchSibling` 还要先反推父级：`subagentParentOfCatalogEntry(node.id) ?? _subagentParentSid`
  （`chat_page.dart:1298-1299`）。扫描**只认 `ready`**（`app/lib/data/app_model.dart:838-842`
  的 `continue`），但渲染用的是同一份 `entries`：`SubagentCatalog.loading({entries})` 保留旧内容
  （`model/subagent.dart:147-148`，文档 §2「刷新不闪空」），树照常把行画出来并可点
  （`ui/subagent_tree.dart:146-151`、`:259`）。
- 展开**无条件**触发一次重读：`subagent_tree.dart:183` → `refreshSubagentCatalog`
  （`app_model.dart:518-522`）→ `_readProjections` 先置 `loading`（`:539-542`）。
- 于是：切换面板里展开一个**读过的**子级（行还在、可点）→ 在这一拍里点孙级 ⇒ 扫描返回 `null`
  ⇒ 退到"当前会话的父级"（祖父）⇒ 在祖父目录里查不到孙级 ⇒ `_subagentMode = null`
  ⇒ `_subagentReadOnlyReason` 走 `unknown`（`chat_page.dart:1177-1178`）⇒ **可续聊的孙级显示
  「此子智能体暂时只读」，且不会自愈**（mode 只在进入那一刻取一次）。
  症状与 `173e1e2` 刚修掉的那个一模一样，只是藏在一次往返的窗口后面；网络慢时窗口是秒级。
- 旁证两条：① 扫描无自引用/环保护（树里有 `ancestors`，`subagent_tree.dart:143-155`；
  畸形投影里"自己是自己的子级"会让 `←` 原地重进自己）；② 每次 `build` 被调 4 次
  （`chat_page.dart:637,642,645` + `_subagentLabel:1193`），复杂度 `O(目录数 × 行数)`。

**影响**：把可续聊的孙级说成"只读"——用户被凭空禁掉输入，而且退出重进才恢复。
根因不是"少一个兜底"，而是**父级与 mode 都从别处猜**，而它们都在手上。

**建议**（照 DSH 的 `openChild(address)`，见 §5.2）
1. `_subagentMode = node.row.mode`（两处）—— 删掉两次目录回查。"查错目录"这一整类 bug 随之消失。
2. `SubagentTree.onOpen` 带父级：`void Function(SubagentNode node, String parentSid)`，
   `_Level` 的 `sid` 就是它（`subagent_tree.dart:213,243`）；`_switchSibling(node, parent)` 与
   `_openSubagent(node, parent)` 都用传入的父级写 `_subagentReturnFrom`（第 3 档兜底）。
3. `subagentParentOfCatalogEntry` 只剩 `_subagentParentSid` 第 2 档一个调用点；加一行
   `entry.key != sid` 的自引用守卫。
4. 顺带（可选）：`_subagentMode` 的 `== null` 半支在修完后就不可达了（进入即赋值）。
   要么删掉（memory 非空 ⇒ mode 必非空），要么留一行注释说明它是 fail-closed 的默认。
   **别两边都写**。

**代价**：3 个文件（`subagent_tree.dart` + `chat_page.dart` + `subagent_tree_test.dart` 的
`onOpen` 签名），约 25 行、**净减约 10 行**（删掉两次回查）。判据：替身用 `Completer` 挂住
`session.projections` 的应答，在挂住期间点孙级，断言输入栏**不是**只读框（静态可写，不需要真机）。
变异校验：把 mode 改回回查 ⇒ 那条红。换来的是"一行的事实由画它的那一层交出"，与 DSH 同构。

### I3. `remote-channel.md` 的 `session.list` / `subagent.prompt` 行与代码相反（三处）

**证据**
- `docs/subsystems/remote-channel.md:371`：「**标题不在这里** …… 手机用 `cwd` 末段 + 相对时间兜底」。
  - 行里**有**标题：`connector/src/dsh/sessions.ts:331-341` 原样透传 `projections.values`
    （注释自己写"`values.title` 就是列表标题"），App 在 `app_model.dart:3118` 解析。
  - `cwd` 兜底**已删**：`chat_item.dart:893-910`（"两级兜底全部删掉，与 Web 对齐"）；
    全仓 `cwd` 只剩 `chat_page.dart:1918` 一处用途（文件面板）。
- `:378`：「一次性 / **外部任务**子会话在手机上是只读框」——`external` 根本进不去
  （`subagent_tree.dart:259` 的 `onTap: row.isExternal ? null : …`），`_subagentReadOnlyReason`
  也没有 `external` 分支（`chat_page.dart:1174-1181`）。而 `subagent-page.md:68` 写的是
  "不可进入、不可展开"——**两份文档对同一件事给了两个答案**。

**影响**：最容易让下一轮"照文档改代码"踩回去的一类 —— 把已删除的 `cwd` 兜底加回来
（历史上正是它让手机上出现一串工作区目录名当会话名）；把 `external` 当只读档去补一个不存在的分支。

**建议**：`:371` 改成"标题在行的投影提示里（`projections.values.title`）；`cwd` 只给挑靶子与
文件面板，不做标题兜底"；`:378` 删掉"外部任务"，或改成"外部任务行不可进入"。

**代价**：1 个文件、2 行。**不改不会让用户看错，但下次一定改错。**

### I4. `subagent-page.md` §7.3 D2 把一个**已修**的缺口写成"发现缺口"

**证据**
- `docs/subsystems/subagent-page.md:269`：「**但 `sync_client_impl.dart:956` 把 `refetch` 项直接跳过、
  从不调 `session.refetch`** ⇒ 超过 1 MiB 的条目会留下静默的洞」。
- 实际：`app/lib/core/sync_client_impl.dart:958-1007` 就是 refetch 的实现（`:980-989` 逐项补取，
  `:997-1007` 调 `session.refetch`）；`memory.md` 已知缺口 10 记着"已修（2026-10-22）+ 真机实验通过"。
- 同句的 `handlers.ts:1001` 也已漂走：`session.page` 在 `handlers.ts:1085`、`session.refetch` 在 `:1098`。

**影响**：§7.3 是"真机造不出来、靠静态审查定的缺口"清单 —— 它现在**报告一个不存在的洞**，
并指向证明相反的代码。下一轮会花时间"修"一个已修的东西。

**建议**：改成"已修：`SyncClient.refetch` + `page()` 合并（`sync_client_impl.dart:958-1007`），
判据见 `memory.md` 已知缺口 10"，并核对本句所有 `handlers.ts:` 行号。

**代价**：1 个文件、1 行。

## 3. Minor（7 条，逐条四格；不改也不会错）

### M1. `_subagentLabel` 的第二档不可达，第三档是 App 名而文档说"会话自己的标题"

**证据**：`app/lib/ui/chat_page.dart:1203-1204` 的 `summary?.displayTitle` 与
`AppModel.currentTitle`（`app/lib/data/app_model.dart:1339-1343`）是**同一次 `_sessions` 查找**
（都是"按 sid 取那一行，取不到 null"），所以前者永远不可能在后者为 null 时给出值；
真正生效的第三档是 `kAppName`（`:1204`）。文档 `docs/subsystems/subagent-page.md:130`
只写了"找不到 → 会话自己的标题"，没提 App 名。

**影响**：无行为影响。但读代码的人会以为有"会话行标题"这一档在兜底；实际是子会话头部显示
"DeepSeek Harness" + 一枚 `chevronDown`（冷启动、`session.list` 还没到时可见）。

**建议**：删掉 `summary` 那一段，直接 `widget.app.currentTitle ?? kAppName`；
`subagent-page.md:130` 补一句"再退到 App 名"。

**代价**：1 个文件、3 行。不改也不会错。

### M2. 三处注释还在描述已删除的东西

**证据**
- `app/lib/ui/dsh_app_bar.dart:406-408`：「子会话的 **crumb** 不加这个上限：它要**自己量**
  "父级 + 子级放不放得下"」—— `_SubagentCrumb` 与那套 `TextPainter` 量宽在 `7806b2a` 已删，
  现在子会话标题走 `_switcher`（`:491-516`），没有量宽。
- `app/lib/ui/chat_page.dart:173,334,1217` 用"面包屑会挂在无关会话上"指代已经不存在的部件
  （现在只有 `←` + 标题；`_subagentLabel` 的文档注释 `:1183` 也写"面包屑上那个标题"）。
- `app/lib/data/app_model.dart:833-835`：「用它扫会既扫不到东西、又**往表里塞一堆空行**」——
  `subagentCatalogOf`（`:823-824`）是 `map[sid] ?? const loading()`，**纯查询，不插入**。

**影响**：读代码的人会去找一个不存在的宽度计算 / 面包屑部件，或者误以为扫描有副作用。
零行为影响。

**建议**：三处各改一句 —— `dsh_app_bar` 那句删掉"自己量"改成"`Expanded` 给的就是右簇摆完的
剩余宽度"；`chat_page` 三处"面包屑"改成"子会话头部/返回按钮"；`app_model` 删掉"塞空行"。

**代价**：2 个文件、3 行。不改也不会错。

### M3. `subagent-page.md:24` 的行号引用已漂到别的函数

**证据**：`docs/subsystems/subagent-page.md:24` 引 `connector/src/handlers.ts:527-533`（投影提示透传）；
那一段现在是 `session.create` 的参数收窄与 `workspaceId/cwd/agentPreset`（`handlers.ts:520-535`），
真正的透传在 `:595-601`。正是本批在它上面插了 17 行造成的。

**影响**：违反 `AGENTS.md`「引用行号会漂移，改文档时顺手核对」；下一个人会读 `session.create`
去理解列表行。零行为影响。

**建议**：改成 `:595-601`，或去掉行号只留"`session.list` 的投影提示透传"。

**代价**：1 个文件、1 行。不改也不会错。

### M4. 一条用例钉了 DSH **不会产生**的形状，且注释说"DSH 的线格式就是这样"

**证据**：`app/test/session_list_wiring_test.dart:310-318` 构造
`modelSelection: {lastUsed: {…}, next: null}`，注释写"DSH 的线格式就是这样"。
DSH 的 view 是 `view: state => ({lastUsed, next: state.pending ?? state.lastUsed})`
（`packages/api/session-controller/src/model-selection-projection.ts:65`）⇒ `lastUsed` 非空时
`next` **不可能**为 null。

**影响**：用例本身无害（防御性解析），但它把"不可能的输入"当规范写进注释，
会诱导后续实现照这个形状做分支，也会让下一个人以为 I1 那种错键名是"线格式允许的"。

**建议**：注释改成"防御性用例：`next` 缺失/为 null 时退 `lastUsed`（真实 view 不会同时给
`lastUsed` 与非 null 之外的 next）"；断言不动。

**代价**：1 个文件、1 行注释。**不要动断言**（它会因此变宽）。不改也不会错。

### M5. 连接器对 `parentSessionId === ''` 也会铸别名，App 侧却把空串当"没有"

**证据**：`connector/src/handlers.ts:566-569` 只判 `undefined`；
`connector/src/alias.ts:120-136` 的 `ensure` 对任何字符串都分配（不校验空串）；
App 侧 `app/lib/data/app_model.dart:3135-3139` 明确"空串按没有处理" —— 这条防线在真实链路上
**不可达**，因为空串已经被换成别名了。笔记
`implemented/2026-10-23-subagent-header-parent-from-data.md` 自己写着"不为 `undefined` 建别名
（否则别名表会多一行空映射）"，同一条理由对 `''` 也成立。

**影响**：DSH 的 `parentSessionId` 是 branded string，给空串概率很低；一旦发生，
手机拿到一个不存在的父级别名，`←` 会 `openSession` 到一个空会话（白屏 + `lastError`）。

**建议**：`row.parentSessionId === undefined || row.parentSessionId === ''` 都按没有处理；
或让 `aliases.ensure('')` 抛。补一条"空串父级不铸别名"的断言。

**代价**：1 个文件、1 行 + 1 条断言。不改也不会错。

### M6. 三处「sid 守卫」在 `projections` getter 之后成了重复判据

**证据**：`app/lib/data/app_model.dart:875-878`（`queueOf` 先 `if (_currentSid != sid) return const []`
再读 getter，而 getter 已按 `_currentSid` 判过）；`:768-772`（`permissionValue`）与
`:1986-1989`（`agentPresetValue`）同样先判 `_currentSid == null`；
`app/lib/ui/chat_page.dart:1026-1031`、`:1054-1058` 里 `final sid = …; if (sid == null) …`
之后不再用 `sid`。

**影响**：无（两处判据给同一答案）。只是读起来像"getter 不管归属"，
而且新加的 getter 语义（"不匹配就当作没有"）在两处被判了第二遍。

**建议**：`permissionValue` / `agentPresetValue` 直接 `return parseX(projections)`；
`queueOf` 保留 `sid` 参数但删掉第一行；`_modelLabel` / `_reasoningLabel` 去掉局部 `sid`。

**代价**：2 个文件、约 10 行。不改也不会错。

### M7. `subagent-page.md:140-149` 是变迁叙述，违反 `docs/AGENTS.md` 去废话守则 1

**证据**：`docs/AGENTS.md`「只记当下事实，严禁『以前 / 现在 / 不再』这类变迁叙述」；
`docs/subsystems/subagent-page.md:141-143`「所以父级**曾只能靠**导航记忆 —— 而记忆只有一层 ……
屏幕上**就成了**"每一层都显示它自己"」。同一段因果已经完整写在
`implemented/2026-10-23-subagent-header-parent-from-data.md` 的「原来为什么必然坏」。

**影响**：零（对外行为无关）。但这是 `docs/` 目录的硬规则，不是口味；`docs/` 会逐批变长。

**建议**：§4 只留"父级三档 + DSH 次序 + 老连接器兜底"的当下事实，因果指向笔记
（与 M3 同文件，可合并一次提交）。

**代价**：1 个文件、约 8 行。不改也不会错。

## 4. 实施顺序、提交拆分、判据

| 顺序 | 条目 | 改动面（文件数） | 提交 | 判据 | 变异校验 | 笔记 |
|---|---|---|---|---|---|---|
| 1 | I1 | 2 | `fix(connector): 模型从 wire view 读，不再是 state` | `models-face.test.ts` 改真形状 + 新增 pending 用例；`pnpm exec tsc --noEmit && pnpm build && pnpm test`（586） | 取 `lastUsed` 换掉 `pending` ⇒ 恰好那条红 | `implemented/` 一篇（含"为什么 state ≠ view"） |
| 2 | I2 | 3 | `fix(app): 子智能体的父级与 mode 由画它的那一层交出` | 新用例：挂住 `session.projections` 期间点孙级 ⇒ 不是只读框；`subagent_enter_test` 13 条全绿；`flutter test`（≥1120）+ `dart analyze --fatal-infos` + `dart format --set-exit-if-changed` + boundary（357） | 把 `node.row.mode` 改回回查 ⇒ 恰好那条红 | `implemented/` 一篇（照 DSH 的 `openChild(address)`） |
| 3 | I3 + I4 | 2 | `docs: session.list 行与 §7.3 D2 回到当下事实` | 逐句对代码；`git grep` 复核被引行号 | — | 不需要（机械订正） |
| 4 | M1 / M2 / M6 | 3 | `refactor(app): 删死分支与重复判据，注释回到当下事实` | `flutter test` + analyze + format + boundary | M1 删分支后若有用例红 ⇒ 说明那支不是死的，停下来重看 | 不需要 |
| 5 | M3 / M4 / M5 / M7 | 4 | `docs+test+connector: 行号、注释与空串父级` | connector 那半边跑 `tsc + build + test`；docs 逐句对代码 | M5 加断言后做一次变异（去掉 `=== ''` ⇒ 那条红） | 不需要 |

> 顺手（可跳过）：`.agents/notes/proposed/next-session-prompt.md` 是 2026-10-20 渲染轮的旧开工单，
> 早已过期且无任何引用 —— 按"决定不能删"的口径移进 `archived/`，或留着别动。

### 4.1 门禁命令（照抄，改哪半边跑哪半边）

```pwsh
# app（改 app/lib 或 app/test 之后；从仓库根开始）
node app/tools/verify-platform-boundary.mjs          # 357 项 / 98 个 Dart 文件
cd app
flutter test                                          # ≥1120
dart analyze --fatal-infos lib test integration_test
dart format --output=none --set-exit-if-changed lib test integration_test
cd ..

# connector（改 connector/src 之后；从仓库根开始）
cd connector
pnpm exec tsc --noEmit
pnpm build
pnpm test                                             # 586

# 只改 docs / notes：不用跑门禁，但要 git status 看完整清单
```

**起点先跑一遍确认是绿的**，红了先修起点再动手（别把既有红算到本轮账上）。

## 5. 实施约束（用户 2026-10-23 指定，三条都可判定）

### 5.1 规范标准

1. 门禁基线只许升不许降：flutter **1120** / connector **586** / relay 86 / protocol 486·26·49 /
   boundary **357**（98 个 Dart 文件）/ icons 100 / tool-paths 21 / analyze+format **0**。
2. 注释写"为什么"，不写"是什么"；引 DSH 一律 `packages/...:行号`，查不到写「未找到」。
3. **改行为就删旧路**：I2 修完后 `_switchSibling` 里不许再有目录回查；不许"加一层兜底"。
4. 一件一提交 + 一篇笔记（I1 / I2），代码与笔记同批；`docs/` 只写当下事实。
5. 改源码只用编辑工具（历史两次事故）；提交前看 `git status` 完整清单。

### 5.2 用 DSH 原生能力（本轮两条代码项都靠这条定形状）

- **I2 照 DSH 的 `openChild(address)`**：DSH 在**行被画出来的那一层**就构造地址 ——
  `packages/client/ui-subagent/src/client/SubagentHeaderLineage.tsx:279-287` 的
  `openChild({parentSessionId, childSessionId: entry.id, mode: entry.mode})`，
  而层级递归 `:386` 把 `entry.id` 传给下一层当 `parentSessionId`。
  **父级与 mode 都来自那一层，不查表。** 我们的 `onOpen(node)` 丢掉了这两样，才需要扫描。
- **I1 读 DSH 的 wire view**，不读宿主 state：`snapshot(...).values` 是过 `viewSchema` 的线格式
  （`session-projection/src/index.ts:330-345`），`stateOf` 是宿主内部状态（`:312-328`）。
  手机与连接器读同一个形状，字段名就不再有两套。
- 不新增方法面、不新增往返：I1 用同步 `snapshot`（与 `stateOf` 同量级），I2 靠传参。
- 不为绕问题加层：不许给扫描再加一档 `ready` 判断，不许在 App 侧缓存"父级表"
  （那正是 `7806b2a` 否掉的方案）。

### 5.3 实施要优雅

1. **修在唯一真值上**：模型只有一个出口 `AppModel.currentModel`、一个形状（wire view）；
   父级只有一个出口 `_subagentParentSid`，且"这一行的父级"由画它的那一层给。
2. **净删除优先**：I2 的预期是 `-10 行`（删两次回查）；如果改完行数反而涨，说明修法不对。
3. 判据集中：`_subagentParentSid` 里三档各一行，不许在第 2 档里再长出分支。
4. 命名跟着职责收窄：`subagentParentOfCatalogEntry` 修完后只服务"老连接器兜底"，
   文档注释要跟着改（现在是"第二档"的通称）。

## 6. 不要重开（上一轮已定案，修的时候别退回去）

- 顶栏**不显示父级名**（对齐 DSH 的 `switcherDisplayTitle`，`:490-495`）；父级由 `←` 的落点表达。
- 右侧面板的目录行**不显示模型**（DSH 的 `ui-subagent` 里 `model` 零命中）。
- **只读档看导航记忆、发送方法看数据父级**：这是有意的（`_subagentMode` 只在走进那一刻知道，
  见 `implemented/2026-10-23-subagent-composer-model-and-mode-source.md` 的「代价与边界」）。
  I2 只改"mode 从哪来"，**不改**这条分工 —— 恢复出来的子会话仍然不判只读。
- `_subagentReturnFrom` / `_subagentChildSid` 的第 3 档**不能删**（新手机连老连接器）。
- 投影包按会话归属（`_projectionsSid` + getter）是定案；I1/I2 都不碰它。
- 其余见 `docs/subsystems/*.md` 各篇的「有意偏离」与 `memory.md` 的「别当缺口」。

## 7. 真机项

| 项 | 需要真机 | 需要新 agent 回合 |
|---|---|---|
| I2 的刷新窗口 | 不需要（`Completer` 挂住应答即可确定性复现） | **0** |
| I1 / I3 / I4 / M1–M7 | 不需要 | **0** |

本轮**不需要**起隔离实例、不需要 `adb reverse`、不花用户的钱。

## 8. 被否掉的替代（别重提）

1. **只把 `models.ts` 的端口类型改成 `{lastUsed, pending}`**（不动取值）
   - 最强的理由：两行改完 `tsc` 就过，测试不用动。
   - 为何被否：它把"state 与 view 是两个东西"这件事继续藏在连接器里；App 读 view、连接器读 state，
     下一个读 `model` 的人还得再踩一次。要修就修到"一个形状"。
2. **给 `subagentParentOfCatalogEntry` 加"`loading` 也认"**
   - 最强的理由：一行改动，立刻消掉 I2 那个窗口。
   - 为何被否：`loading` 的 `entries` 是**上一次**的内容，拿它认父级会把关系钉在旧树上
     （同 `app_model.dart:839-840` 的注释）；而且真正的答案是"树知道"，不是"扫描放宽"。
3. **在 App 侧维护一张 `child → parent` 表**
   - 最强的理由：查一次就够，O(1)，不依赖目录状态。
   - 为何被否：第二份会漂的真值，重启即丢 —— `7806b2a` 已经否过同一个形状。
4. **把顶层 `model` 从线上删掉**
   - 最强的理由：它已是 `projections.values.modelSelection` 的重复。
   - 为何被否：契约变更（老手机只认这个字段），要单独决定，不在本轮顺手做。

## 9. 新会话提示词（整段复制）

```text
项目：dsh-mobile（D:\sudy\myproject\dsh-mobile，Windows / pwsh）。中文回复。

本轮只做审查清单里的 4 条 Important + 7 条 Minor，清单与证据在
.agents/notes/proposed/2026-10-23-subagent-parent-and-model-truth-review.md
（§0.1 资产清单 / §2 四条四格 / §3 七条四格 / §4 顺序与判据 + §4.1 门禁命令 /
§5 三条实施约束 / §6 不要重开 / §8 被否的替代）。**那份文件自足，不依赖上一轮的对话记录。**
**0 个真机回合**：不需要起隔离实例、不需要 adb、不花用户的钱。

## 0 先读（别跳）
- .agents/notes/proposed/2026-10-23-subagent-parent-and-model-truth-review.md（本轮全部内容）
- memory.md（现状、门禁表、"别当缺口"）
- AGENTS.md（硬规则）+ tools.md 的 Pitfalls（稳定坑点的唯一出处）
- 两篇上一轮笔记的「代价与边界」（本轮不许退回去的东西）：
  .agents/notes/implemented/2026-10-23-subagent-header-parent-from-data.md 与
  .agents/notes/implemented/2026-10-23-subagent-composer-model-and-mode-source.md
- docs/subsystems/subagent-page.md §4（现状事实；I3/I4 要改的两处在 remote-channel.md 与本篇 §7.3）

## 1 现状（省你半天）
- 三笔提交刚落地：7806b2a（父级数据驱动）/ 173e1e2（输入栏模型 + mode 来源）/ fb1b31e（投影包按会话归属）。
- 门禁基线：flutter 1120 / connector 586 / relay 86 / protocol 486·26·49 /
  boundary 357（98 个 Dart 文件）/ icons 100 / tool-paths 21 / analyze+format 0。
- 上一轮该收口的已收口：父级只剩 _subagentParentSid 一个出口、_projections 私有直读清零、
  SessionSummary 四条重建路径都带 parentSid 与 model。修的时候别把这些退回去。

## 2 本轮四件（按顺序；I1/I2 各一个提交 + 一篇笔记，I3/I4 一个 docs 提交）

### I1 连接器：模型从 wire view 读，不从 state 读
models.ts 的 modelOf 用 stateOf（宿主 state {lastUsed, pending}）去读 .next —— 恒 undefined，
顶层 model 永远只是 lastUsed，与三处文档承诺的 next ?? lastUsed 相反；测试替身喂的是线格式，
所以绿。修法见清单 §2 I1：读 snapshot(...).values.modelSelection（与 App 同一表达式），
端口类型改成 snapshot 形状；测试替身改真形状 + 补一条 pending 用例。
判据：tsc --noEmit && pnpm build && pnpm test（586）；变异校验：把 pending 换回 lastUsed ⇒ 恰好那条红。

### I2 App：父级与 mode 由画它的那一层交出（照 DSH 的 openChild(address)）
_switchSibling / _openSubagent 都在拿已经持有的那一行回目录里再查 mode，_switchSibling 还要
全表扫描反推父级；而扫描跳过 loading，渲染却用 loading 保留的 entries ⇒ 展开后那一拍里点孙级，
可续聊的孙级显示「此子智能体暂时只读」且不自愈。
修法见清单 §2 I2：_subagentMode = node.row.mode（两处）；SubagentTree.onOpen 带 parentSid
（_Level 的 sid 就是它）；扫描只剩第 2 档一个调用点并加自引用守卫。
判据：新用例用 Completer 挂住 session.projections，挂住期间点孙级 ⇒ 不是只读框；
subagent_enter_test 13 条全绿；flutter test ≥1120 + analyze --fatal-infos + format + boundary 357。
变异校验：把 mode 改回回查 ⇒ 恰好那条红。预期净减约 10 行。

### I3 + I4 文档：回到当下事实
remote-channel.md:371 的"标题不在这里 / cwd 末段兜底"与 :378 的"外部任务是只读框"；
subagent-page.md:269 的 §7.3 D2 说 refetch 被跳过（已修，且引用行号现在正好是修好它的代码）。
改法见清单 §2 I3 / I4。不需要笔记。

### Minor：M1–M7（清单 §3 七条四格；按 §4 的第 4/5 两条提交走）
M1/M2/M6 合成一个 app 提交；M3/M4/M5/M7 合成一个提交（docs + 测试注释 + connector 判空）。
M4 只改注释（**不要动断言**）；M5 加断言后做一次变异（去掉 `=== ''` ⇒ 那条红）。
M1 删分支后若有用例红，说明那支不是死的，停下来重看。

## 3 硬规则（违反会被退回）
- 规范标准：门禁只许升不许降；注释写"为什么"；引 DSH 给 packages/...:行号，查不到写「未找到」。
- **用 DSH 原生能力**：I2 照 SubagentHeaderLineage.tsx:279-287 的 openChild(address)（父级与 mode
  都在那一层，不查表）；I1 读 snapshot 的 wire view（:330-345），不读 stateOf（:312-328）。
  不新增方法面、不新增往返、不为绕问题加层。
- **实施要优雅**：修在唯一真值上；净删除优先（I2 预期 -10 行，涨了说明修法不对）；
  判据集中（_subagentParentSid 三档各一行；模型只有 currentModel 一个出口）。
- 改源码只用编辑工具，不用 shell 字符串替换（历史两次事故）。
- 一件一提交 + 一篇笔记（I1/I2）；docs 只写当下事实；提交前看 git status 完整清单。
- 断言改动做变异校验（故意破坏不变量，确认恰好那一条红）。
- **动手前先跑一遍门禁确认起点是绿的**（命令照抄清单 §4.1），红了先修起点，
  别把既有红算到本轮账上。

## 4 不要重开（清单 §6）
顶栏不显示父级名 / 面板行不显示模型 / 只读档看导航记忆（I2 只改 mode 从哪来，不改这条分工）/
第 3 档记忆不能删 / 投影包按会话归属是定案 / 顶层 model 字段删不删是另一个决定。
```
