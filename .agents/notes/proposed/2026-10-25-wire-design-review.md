# 线上形状：真值在生产者，判据在金样

- 日期：2026-10-25
- 状态：待评审（**用户已准按第 0/1 批开工**，开工单 `proposed/2026-10-25-wire-batch0-and-batch1-prompt.md`；
  每批落地后逐条改判，全部落地才移 `implemented/`）
- 取代旧稿：`archived/2026-10-25-wire-format-layer.md`（同一件事的前一版草案）
- 相关：`implemented/2026-10-25-event-wire-single-decoder.md`（事件面已落地）、
  `implemented/2026-10-24-plan-review-card-from-request.md`（第三次事故现场）、
  `implemented/2026-10-07-three-wire-shape-mismatches.md`（第一次事故现场）、
  `implemented/2026-10-15-projections-envelope-must-be-unwrapped.md`（第二次事故的修法落在哪一侧）

## 结论（三句）

1. **不是"没做设计"，也不是"粒度粗"**，是**不变量声明在一个粒度、判据实现在另一个粒度，且没有任何东西比对这两者**。
   声明是"事件载荷的字段名与类型只在这里断言一次"（`app/lib/wire/events.dart:15`），
   判据是"`'arguments'` / `'toolCallId'` 两个字面量只许出现在 `wire/events.dart`"
   （`app/tools/verify-platform-boundary.mjs:129-134`）。**两个字面量** vs **`data/projection.dart` 里还在读 39 个字面量键**、
   加上 `app_model.dart` 的 84 个下标键——门禁全绿。这个差值本身就是缺陷，而它只在把"声明的"与"拦住的"并排放时才看得见。
2. **方案 a 的方向对，但前一版草案的取证机制不成立**：真样本是一次性快照，连接器改了应答它**不会变**，
   于是用例永远绿 —— 与教训第九条（`memory.md`）逐字同形，只是把"手捏的形状"换成了"过期的真形状"。
   要改成**金样**：样本由**连接器的测试**从真实 handler 产出、深比较落盘，App 用例读同一份文件。
   这个做法在本仓已有先例：`connector/tests/error-table-parity.test.ts:28` 就是从连接器测试里读 Dart 源码做逐字对撞。
3. **五条候选中两条不是独立方案**：b（codegen）今天**没有类型源** —— `MethodHandler` 返回 `Promise<unknown>`
   （`connector/src/protocol/methods.ts:280-283`），`METHODS` 只是 49 个字符串；所以 b = e + 生成器。
   c（运行时 schema）是 a 的**检查器**，不是替代（它要么是第二份要同步的真值，要么就是 a 的输出金样）。
   真正的三选一只剩"**谁把形状写下来**"：生产者（e）/ 消费者（a、d）/ 第三方描述（c）。

## Problem

### 1. 声明与判据的粒度错位（可量化）

| | 声明说的 | 判据拦的 | 生产里实际有的 |
|---|---|---|---|
| 事件载荷 | 字段名与类型只在 `wire/events.dart` 断言一次 | 2 个字面量（`arguments` / `toolCallId`） | `data/projection.dart` 读 **39 个**字面量键，`core/items.dart` 另 6 个，全部放行 |
| RPC 应答 | （没有声明） | 无 | `data/app_model.dart` **41 个读取点 / 104 个字面量字段**；`model/*.dart` **36 个读取点**（字面量下标共 **198** 处，其中 25 处属事件载荷与工具参数，不归这一族） |
| 投影值 | （没有声明） | 无 | App 读 **14 个键**（`title`/`tokenUsage`/`sessionStats`/`turnOutline`/`trajectory`/`contextBreakdown`/`contextPressure`/`imageLimits`/`inbox`/`permissions`/`agentPreset`/`subagentCatalog`/`modelSelection`/`subagentTiming`），散在 `app_model.dart` 的 10 个读取点与 6 个 `model/*`/`core/*` 解析器里 |

同一份 `wire/events.dart` 里那条不变量写得很清楚（`:15-23`），但它**没有任何机制检查它是否仍然成立**。
这不是"设计没做"，是"设计做了、断言强度不够"。

### 2. 三次事故的**形态**其实有两种，草案把它们并成了一种

| 事故 | 真因 | 属于 |
|---|---|---|
| `repo.info.commands`：`string[]` → `{name,description?}[]`（`connector/src/handlers.ts:94-102`、`app/lib/model/command.dart:95-119`） | 生产者**有意**改形状，消费者两种都收 | **兼容决定**，不是缺陷 |
| `session.projections`：信封装错层（`connector/src/dsh/projections.ts:25-40`） | 同一个概念**两种形状**同时在线上 | 生产者侧不一致 |
| 计划卡：`arguments` 是 JSON 字符串，投影按对象读（`projection.dart` ↔ `items.dart`） | 同一个字段**两个读者**，错的那个静默 `null` | 消费者侧多读者 |

**第二种和第三种是同一族的两个方向**：一个是"同一个名字两种形状"（生产者），
一个是"同一个形状两个读者"（消费者）。第一种根本不是缺陷。草案的单一不变量
（"每个字段的形状必须有出处"）对第一种会把兼容误判成漂移，对第三种则无处安放出处
（工具参数是**模型**产出的自由 JSON，没有线上生产者可引）。

### 3. 形状来源其实有五类，只有三类适用"引用出处"

| # | 类别 | 谁给的 | 读取点（同一正则） | 规矩 |
|---|---|---|---|---|
| 1 | 会话事件载荷 | DSH 会话格式（落盘 jsonl） | `projection.dart` 68 + `items.dart` 12 | 可引 `packages/...:行号` |
| 2 | RPC 应答 | **连接器**（`handlers.ts` 的对象字面量） | `app_model.dart` 34（读取点 41）+ `model/*` 36 | 可引 `connector/src/...:行号` |
| 3 | 投影值 | DSH 各投影的 wire view | 同上两个位置 | 可引 `packages/...:行号`；**注意两层形状不同**（下条） |
| 4 | 本仓自己的帧/封箱/存储 | 我们自己（契约 §3/§4/§8.3） | `core/frame.dart`、`core/handshake.dart`、`platform/*_store.dart` 等 | **不在本轮范围**，不是"线上形状漂移" |
| 5 | 工具参数（`arguments` 解开后） | **模型**（自由 JSON），键由宿主工具 schema 定 | `projection.dart` 的 `plan`/`questions`/`multi_select`、`model/changed_path.dart`、`model/tool_view.dart` | **只按已知工具解，未知工具宽进**；出处只能引宿主工具定义行号 |

第 5 类是本轮对草案的实质修正：不把它单列出来，"每个字段必须有出处"这条会逼人给
`plan` / `multi_select` 编一个引用，规矩从第一周就开始造假。

### 4. 一个仍在生产里的活雷：同一个名字 `projections` 有两种形状

| 位置 | 形状 | 决定行 |
|---|---|---|
| `session.projections` 的**应答** | 扁平的 `values` 映射（**没有信封、永不 `null`**，`null`→`{}`） | `connector/src/dsh/projections.ts:68-72` 取 `values`、`:94` 返回 |
| `session.list` 行的 `.projections` | **完整信封** `{kind, asOfSeq, values}` | `connector/src/dsh/sessions.ts:333-341` 逐键重建；`handlers.ts:766-768` 过线 |

两个决定各自都有充分理由（前者"拆信封"是第二次事故的修法；后者"原样透传、不挑键"是
`dsh/sessions.ts:155-161` 的注释），**合起来就是一个 50% 会踩的坑**，而且踩错的表现是静默空值。
App 侧对应两套读法：`app_model.dart:558-578`（直读 map）与 `:758-763`（`values` 信封）。
单靠"每个方法一个 decoder"**抓不到**这个 —— 它能被抓住的唯一形态是"金样里两种形状并存，谁读错谁红"。

**复核数字自己跑**（不抄前一版草案：它说 103 处 / 17 文件 / `projection.dart` 64 / 28 个方法，四项都对不上）：

```powershell
node -e "const fs=require('fs');const p='app/lib';const walk=d=>fs.readdirSync(d,{withFileTypes:true}).flatMap(e=>e.isDirectory()?walk(d+'/'+e.name):e.name.endsWith('.dart')?[d+'/'+e.name]:[]);let n=0;for(const f of walk(p)){const t=fs.readFileSync(f,'utf8');const c=(t.match(/fieldOf\(|stringField\(|nonEmptyString\(|\bis Map\b|\bas Map\b|jsonDecode\(/g)||[]).length;if(c){n+=c;console.log(String(c).padStart(4),f)}}console.log('total',n)"
```

实测：**157 处 / 23 文件**（`projection.dart` 68、`app_model.dart` 34 处、
`sync_client_impl.dart` 13、`items.dart` 12、其余 13 个文件共 30）。
其中**本仓协议**那一类（`frame` / `handshake` / `flow` / `outbox` / `pairing*` / `*_store` / `store`）约 12 处不属于本轮范围。
方法面：**契约 49、连接器实现 47、`app/lib/` 里出现的方法名 46 个且各恰好 1 次**
（`core/` 的连接层 5 个：`session.page` / `session.refetch` / `session.subscribe` / `session.unsubscribe` / `sync.hello`），
其中 **7 个方法的应答形状没有任何一侧断言**：`session.cancel` / `session.updateQueue` /
`job.follow` / `job.unfollow` / `interaction.respond` 连返回形态都不判（`app_model.dart:927`、`:968`、
`:1072`、`:1085`、`:3696`），`session.prompt` / `subagent.prompt` 直接 `call<void>`
（`ui/chat_page.dart:565`）—— 应答里的 `{accepted}` 从来没读过。这不是缺陷（没有人消费它），
但它们**不该被算进"已搬"**。
"28 个方法"复现不出来。

## Decision

**一条不变量，拆成两半；四个机制；五条准入门槛。**

不变量（拆开之后两半都成立，合起来才覆盖三次事故）：

- **R1 传输形状**：线上载荷的字段名与类型**由生产者给出**，消费者只能引用，不能推断。
  引用必须是 `connector/src/...:行号`（第 2 类）或 `packages/...:行号`（第 1、3 类）。
- **R2 内容形状**：载荷里的**自由 JSON**（工具参数）只按**已知工具**解，未知工具一律宽进
  （`Map` 原样、不猜键）；每个已知工具的键出处是宿主工具定义的 `packages/...:行号`（第 5 类）。

四个机制：

1. **一个面一个读者，读者住 `wire/`**：`wire/events.dart`（事件，已落地）+
   `wire/rpc/<family>.dart`（应答与投影值）。理由只有一个、但足够：**门禁按路径豁免**
   （现有 `wire-field-single-reader` 就是这么做的，`verify-platform-boundary.mjs:132`），
   别的方案都无法把"只此一处"变成一条可判定的规则。
2. **失败语义只有一个**：`WireReading<T>` 三态（`wire/reading.dart:34-60`）。
   面内分层规则：**身份键与"生产者无条件写出的键"缺失 ⇒ 整条丢并计数**；
   **可选键组里的东西读不出来 ⇒ 该字段降级 + 计数，不丢整条**（丢整行会让会话从列表消失，比空标题坏得多）。
3. **金样（golden）而不是快照**：`connector/tests/fixtures/wire-shapes.json`，
   由连接器测试用**真实 handler** 产出、**深比较**守住（不相等就红并打 diff）；
   App 的用例读**同一份文件**。这是"漂移怎么被发现"的唯一机械答案，先例是
   `connector/tests/error-table-parity.test.ts:28`（连接器测试读 App 的源码做逐字对撞）。
4. **门禁即进度表**：`verify-platform-boundary.mjs` 里加一条 `wire-rpc-single-reader`，
   名单随批次增长（一条规则一个方法名）。**名单就是"哪些方法已搬完"的清单**——
   不需要任何索引文件，且每加一条就多锁死一个方法。

准入门槛（可机械判定）：

1. **一个方法名在 `app/lib/` 里只出现一次**，且在 `wire/rpc/`（`core/` 的连接层方法除外）。
   今天 46 个方法**已全部满足"只出现一次"**，只是位置在 `data/` / `ui/` / `core/`。
2. **decoder 头注必须有出处**：`connector/src/...:行号` 或 `packages/...:行号`。
   没有行号的 decoder 视为未完成（评审一句话就能核）。
3. **金样覆盖**：`wire-shapes.json` 里每个**已搬**方法至少一条样本，App 用例在每条样本上
   `badCount == 0`；金样键集合不许缩水（缺一个方法就红）。
4. **旧读法必须删掉**：搬一个方法，`app/lib/` 里它原来的解析代码**整段消失**（不是留着不用）。
   判据 = 门槛 1 + `git diff` 里是负行数。
5. **变异校验一次**：故意把 decoder 里一个键名改错，确认**恰好**红一条用例。

## Alternatives considered

五个候选 × 六判据：

| | a 手写 decoder（本方案） | b 从 TS 类型 codegen | c 运行时 schema 校验 | d 逐模型类 `fromJson`（现状改良） | e 形状责任推回连接器 |
|---|---|---|---|---|---|
| **谁是真值** | 连接器（引用式，人核） | 连接器的**类型** —— **今天不存在** | 第三份描述（schema） | 同 a | 连接器的 DTO 类型 |
| **失败语义** | 统一三态 + 计数 ✔ | 编译期最强；运行时仍要 2 态 | 校验失败 = 响 ✔ | 今天三种并存（抛 / `null` / 默认值）✘ | 只剩传输失败（乐观假设） |
| **迁移成本** | 46 个调用点，一批一提交，可停 | 先写 46 个 TS 应答类型 + 生成器（最大） | 49 张 schema，且与 decoder 重复 | 0（但缺口留原样） | 连接器重写 + 手机换解码（很大） |
| **漂移怎么被发现** | **靠金样**；光靠真样本快照发现不了 | 改类型即编译失败 ✔✔ | schema 自身会漂，漂了同样静默 | 不能发现 | 靠金样或 codegen |
| **评审能不能核** | 能（头注行号 + 金样 diff）✔ | 能（生成物 diff）✔ | 不能（三份要人比） | 今天多数没行号 ✘ | 能（DTO 即规格）✔ |
| **对 DSH 升级的韧性** | 好（只断言消费的键） | 好，但覆盖不到"从哪个键取" | 差（`strict()` 撞新字段） | 同 a | 最好 |

1. **a. 手写 decoder 层（`wire/rpc/<family>.dart`）** —— **采纳**
   - 最强的理由：唯一能把"只此一处"写成路径判据的形态；且内核（三态 + 计数）已经在生产里跑着，
     增量只是加文件，不加概念。
   - 被否的部分：前一版草案把**真样本快照**当漂移判据 —— 那部分否掉，换成金样（机制 3）。
2. **b. 从连接器 TS 类型生成 Dart**
   - 最强的理由：形状永远与生产者一致，是这件事的终点形态；漂移在**编译期**响，比任何回放都强。
   - 为何被否（**今天不可选，不是不好**）：没有类型源。`METHODS` 是 49 个字符串
     （`connector/src/protocol/methods.ts:27-170`），参数信封 `params?: unknown`（`:235-240`），
     处理器 `=> Promise<unknown>`（`:280-283`）。要 codegen 得先写 46 个应答类型 —— 那就是 e。
     更关键：**它治不了本案的两类事故** —— `session.projections` 是"取错层"、计划卡是"取错键名"，
     两者类型都对、层次全错。codegen 覆盖的是形状，覆盖不到"从哪个键取、取的是哪一层"。
     留作下一阶段的真值升级路径，触发条件写在 `Consequences`。
3. **c. 运行时 schema 校验（每个方法一张 JSON Schema）**
   - 最强的理由：形状错误在进系统前就被拦，消费端可以完全不设防。
   - 为何被否：schema 与 decoder 是两份要同步的真值，而我们需要的恰恰不是"通用校验"，
     是"这 46 个方法的字段各是什么类型、从哪一层取"—— 那正是 decoder 干的事。
     它的**可行形态**是本方案的机制 3（用生产输出当金样），不是手写 schema。
4. **d. 逐模型类 `fromJson`（现状改良，最少新概念）**
   - 最强的理由：**它已经是事实标准**，而且是最新两个方法（`file.list` / `file.read`）采用的形态：
     `model/workspace_files.dart:59-111` 把形状写在一处、引宿主行号、认不出给 `null` 由调用方当失败。
     所以 d 与 a 的差别**只有两处**，不是"两代设计"：(i) 失败语义是否统一；(ii) 能不能用路径做门禁。
   - 为何被否：它现在有三种失败语义并存 —— `null`（`file.list` 路径）、默认值（`job` 状态缺键
     → `'running'`，`app_model.dart:1170`；`settings.update` 回执认不出仍 `return true`，`:1668-1678`）、
     抛错（`session.create` 缺 `sid`，`:3114-3120`）。不变量要求**一个**语义，那属于一层，不属于每个类。
     另外它散在 13 个 `model/*.dart` 里，路径判据无从写起。
5. **e. 把形状责任推回连接器（契约里定稳定 DTO，手机不解释宿主形状）**
   - 最强的理由：真值本该在生产者手里；DSH 升级只改连接器，手机不动。
   - 为何被否（**不是被否，是被降级成"下一阶段"**）：今天的连接器**已经**是 e 的一半 ——
     `handlers.ts` 逐字段造行、不 spread（`:719-720`、`:739-769`），内部也有类型
     （`SessionSummaryRow`，`dsh/sessions.ts:132-162`）。但**线上那一侧没有任何类型**：
     方法面返回 `unknown`，那层 DTO 只活在实现里、评审时靠读注释。
     事故照样发生（`session.list` 就是自造 DTO 之后又出过两次事）。所以 e 要真正生效，
     必须有 b 的生成或机制 3 的金样；而金样的成本是 e 的几十分之一。

## Consequences

- 收益：形状知识从 23 个文件里**除本仓协议之外的 20 来个**收到 `wire/`；失败语义只有一个且可计数；
  漂移在**改连接器的那个提交**里就能被看见（金样 diff + App 回放用例），
  不用等真机 —— 这是三次事故里唯一真正缺的一环。
- 收益：**门禁即进度表**。`wire-rpc-single-reader` 的名单只增不减，评审看一眼名单就知道搬完几个方法，
  不需要维护任何索引文件。
- 代价：46 个调用点分 7 批搬，每批"抓金样 → 写 decoder → 删旧读法 → 加一条门禁名单"四件事，
  `app_model.dart` 会瘦一大圈（那是好事，但那是个大 diff）。
- 代价：**引入两个工程之间的测试耦合**。App 的用例要读 `../connector/tests/fixtures/wire-shapes.json`；
  该文件缺失时**必须直接 `fail`，不许 skip**（否则门禁会静默退化成空跑）。
  先例已存在（`connector/tests/error-table-parity.test.ts` 反向读 App 源码），所以不是新范式，但是新的**方向**。
- 代价：`session.page` / `session.refetch` 的 decoder **不能只产出已有模型类** ——
  `SessionPage` 要 `await` 补取（`core/sync_client_impl.dart:990-1016`），一个纯 decoder 不能 await。
  这两个方法需要一个两字段的中间结构（`SessionPageWire`），违反"不新造 DTO"的承诺**在这个方法上**；
  如实记账，不用它去否定整条路。
- 风险：金样必须**确定性**（无时间戳、无随机 id）。连接器测试已有可复用的确定装置
  （`createFakeAliases`，`connector/tests/support/fake-aliases.js`），第一次落地时若发现不确定字段，
  在生成器里归一，不在比较时放过。
- 风险（记在账上）：`WireDiagnostics` 是进程级计数，没有按会话/按方法分桶。排错面板要用它时再加维度。

## 迁移：批次与每批的机械验收

顺序与前一版草案不同 —— **先落机器（金样 + 门禁），再搬第一个面**。理由：没有金样，
前七批的"验收"都只是"用例绿"，而那正是三次事故里全绿的那个绿。

| # | 面 | 方法 | 每批的机械验收（四条同时成立） |
|---|---|---|---|
| 0 | 机器 | — | ① `wire-shapes.json` 存在且含 `session.list` / `session.projections` 两条；② 连接器深比较用例在改一个字段时红；③ App 侧一条"金样在就不会空跑"的用例（文件缺失即 `fail`）；④ 门禁加一条**空名单**规则（名单为空时不拦任何东西，但规则与自检就位） |
| 1 | 会话身份 | `session.list` | ① 门槛 1（方法名只出现一次且位置对）；② 金样含 4 种行（普通 / 带 `parentSessionId` / 冷行无 `model`+无 `projections` / 带信封的 `projections`）；③ 删掉 `app_model.dart:747-750,758-763,3765-3843,3853-3857,3864-3876`；④ 变异校验恰好 1 条红 |
| 2 | 历史页（连接层） | `session.page` / `session.refetch` | ① `SessionPageWire` 的判别联合（`record` / `refetch`）在金样上解全；② `throughSeq` 明确"读了但不用"或"不读"（**今天没读，写成注释**）；③ `core/sync_client_impl.dart:957,990-1016,1024,1038-1052` 的形状读取搬走，`await` 循环留下；④ 变异恰 1 红 |
| 3 | 投影 | `session.projections` | ① 头注写清"**这里是扁平 `values`，不是信封**"，并交叉引用第 1 批的信封读法；② 金样含全部 **14** 个被 App 消费的键；③ 6 个 `model/*` 解析器（`session_stats` / `subagent` / `trajectory` / `image_limits` / `permission.currentValue` / `agent_preset`）搬进 `wire/rpc/projections.dart`；④ 变异恰 1 红 |
| 4 | 能力面 | `repo.info` | ① `commands` 两种形状**都收**，并在头注写明"这是兼容，不是两个真值"（`handlers.ts:1525`）；② 金样两条：带 `commands` / 不带 `commands`；③ 三个 `caps` 布尔与 `dshVersion` 的缺失语义固定；④ 变异恰 1 红 |
| 5 | 文件与引用 | `file.list` / `file.read` / `refs.files` / `refs.sessions` | ① `model/workspace_files.dart` 的 `fromWire` 变成返回 `WireReading`（**唯一一处 d→a 的机械改造**，形状不动）；② 金样含 `size?` / `bytes?` 缺席两条；③ 门禁名单 +4；④ 变异恰 1 红 |
| 6 | 插件 | `plugin.list` / `listBundles` / `install*` | ① `plugin.installStatus` 的"4 键 unknown vs 8 键"两形态各一条金样（`connector/src/dsh/plugin-install.ts:250-262`）；② `plugin.list` 的 `patchId?` / `readOnlyReason?` 恰有一个，decoder 不能两个都当必填；③ 门禁 +6；④ 变异恰 1 红 |
| 7 | 收尾 | `usage.summary` / `settings.*` / `job.*` / `command.execute` / `workspace.*` / `endpoint.describe` / `sync.hello` | ① 每个方法至少一条金样；② `workspace.*` 的"归档/置顶全集"三处共用一份 decoder；③ 门禁覆盖除上文 7 个"无人消费应答"之外的全部方法；④ 全量门禁绿 + 变异恰 1 红 |

**"删掉旧读法"怎么机械化验收**（这是前一版草案没答的问题）：
门禁规则 `wire-rpc-single-reader` 的名单**逐批增长**，每条是"某方法名在 `app/lib/` 只许出现在 `wire/rpc/`"。
名单加进去的那一批，若旧读法还在原地，规则立刻红。于是"删干净"不是靠人在 diff 里找，
而是靠**规则先加、再绿**——这正是现有 `wire-field-single-reader` 的形态（`verify-platform-boundary.mjs:129-134`）。

## 第一批的具体形状（`session.list`）

### decoder（`app/lib/wire/rpc/session.dart`，新文件）

```dart
/// `session.list` 的应答：`{sessions: [...]}`（`connector/src/handlers.ts:738-770`）。
///
/// **行是连接器自造的，不是宿主形状**（`handlers.ts:719-720` 的原话："逐字段构造、不 spread"）。
/// 所以形状出处是连接器，不是 `packages/...`。
WireReading<List<SessionSummary>> readSessionList(Object? result);

/// 一行。缺 `sid` 是形状错（身份丢了，`WireBad` ⇒ 整行丢 + 计数）；
/// 可选键（`parentSessionId` / `model` / `cwd` / `projections`）读不出 ⇒ 该字段降级 + 计数。
WireReading<SessionSummary> readSessionRow(Object? row);
```

- **产出已有模型类**：`SessionSummary`（`app/lib/model/chat_item.dart:778-913`），不新造 DTO。
  `pendingCount` / `itemCount` 是本地派生（`app_model.dart:2245-2253`），由调用方 `copyWith` 补。
- **必填/可选的分界不看名字，看生产方式**：`handlers.ts:739-769` 里**无条件写出**的键
  （`sid` / `updatedAt` / `running` / `blank` / `subagent`）缺失 = 漂了 ⇒ `WireBad`；
  被 `...(cond ? {} : ...)` 包住的 4 个键（`parentSessionId` `:750`、`model` `:754-759`、
  `cwd` `:760`、`projections` `:766-768`）缺失 = 正常 ⇒ `null`。
- **`projections` 是信封**：`{kind, asOfSeq, values}`（`connector/src/dsh/sessions.ts:333-341`）。
  只断言 `values` 是 `Map`（`kind` / `asOfSeq` App 不用 ⇒ 不声明）；
  `values` 不是 Map ⇒ 四个投影字段全降级 + 计数一次。
- 行内二次读（`values.title` / `values.modelSelection` / `values.subagentTiming` / `values.tokenUsage`）
  全部收进本文件；`parseSubagentTiming` / `parseTokenUsage` 仍住 `model/`（它们是投影值解析，第 3 批才搬）。

### 金样从哪来（**不是从真机抓**）

前一版草案说"桌面跑一次 App 抓 ~20 个方法的真样本"。**这条路对本批不成立**：
`session.list` 的应答是连接器自造的行，真机抓一份只能证明"那一刻连接器长这样"，
下次连接器改了它不会红。改为：

1. 扩 `connector/tests/connection-methods.test.ts` 的 `fixtureHandlers()` 里
   `sessions.list()` 的假行（今天在 `:53-64`，只有 1 行），扩到 4 行（普通 / 带 `parentSessionId` / 冷行 / 带信封 `projections`）。
2. 新增 `connector/tests/wire-shapes.test.ts`：调真实 handler，与
   `connector/tests/fixtures/wire-shapes.json` **深比较**；`UPDATE_WIRE_SHAPES=1` 时才写盘（快照测试的老做法）。
3. `app/test/wire_shapes_replay_test.dart` 读 `../connector/tests/fixtures/wire-shapes.json`，
   **文件不存在直接 `fail`**；每条样本喂 `readSessionList`，要求 `WireOk` 且 `badCount == 0`；
   断言值全部来自金样本身（不写常量）。

### 要删掉的旧读法（精确到行，全部在 `app/lib/data/app_model.dart`）

| 行 | 是什么 | 处置 |
|---|---|---|
| `747-750` | `_titleHintOf`（读 `values.title`） | 删，进 decoder |
| `758-763` | `_projectionValueOf`（读信封 `values`） | 删，进 decoder（**头注要写"这是信封，不是扁平 map"**） |
| `2229-2232` | `_fetchSessionRows`（唯一调用点） | 改成 `valueOrReport(readSessionList(await client.call<Object?>('session.list', const {})), 'session.list') ?? const []` |
| `3765-3843` | `_parseSessionList`（79 行，12 个字段） | 整段删 |
| `3853-3857` | `_modelSelectionOf`（`next ?? lastUsed`） | 删，进 decoder |
| `3864-3876` | `_parseModelRef` | 删，进 decoder |

净效果约 **−107 行**（4+6+79+5+13，不含新增的 decoder 与它的头注），方法名从 `data/` 移到 `wire/rpc/`。
`chat_item.dart:854` 与 `app_model.dart:1333` 提到 `_parseSessionList` 的两处注释要跟着改指向。

### `session.page` / `session.refetch` 为什么单独一批

它们的解析住在**连接层**（`core/sync_client_impl.dart:990-1016`、`:1024`、`:1038-1052`），
`core/` 的 `SessionPage` 类型要参与 `await refetch`，一个纯 decoder 不能 await。
所以那一批的形状是：

```dart
sealed class SessionPageItemWire {}
final class PageRecordWire extends SessionPageItemWire { final Map<String, Object?> record; }
final class PageRefetchWire extends SessionPageItemWire { final int seq; }

class SessionPageWire {
  final List<SessionPageItemWire> items;
  final bool hasMore;
}

/// 应答 `{items, hasMore, throughSeq}`（`connector/src/session-page.ts:112`）。
/// `throughSeq` **手机不读**（`app/lib/` 里 grep 零命中）—— 写明，不当它不存在。
WireReading<SessionPageWire> readSessionPage(Object? reply);
```

`await` 补取的循环留在 `_eventsOfPage`，`_eventOfRecord` 的 `record['event']` 读取搬进本文件
（它是 `SessionHistoryRecord` 的整包，出处 `packages/api/session-controller/src/types.ts:440`）。

## 仍未决 / 待补

1. **金样会不会变成第二个真值？** 它由连接器测试产出、深比较守，改动它的唯一方式是改实现。
   但这需要一次真实演练来证明"改一个字段 ⇒ 连接器红 + App 红"两条都成立（第 0 批的验收就是它）。
2. **`session.prompt` 的调用点在 `ui/chat_page.dart:562-571`**（不在 `data/`）。门槛 1 要求方法名只出现一次，
   它今天满足，但位置在界面层。要不要把写路径也收进 `wire/rpc/session.dart`（`sendPrompt(...)`）——
   留到第 1 批落地后单独决定，不在本轮拍。
3. **7 个"无人消费应答"的方法不搬**（`session.cancel` / `session.updateQueue` / `job.follow` /
   `job.unfollow` / `interaction.respond` / `session.prompt` / `subagent.prompt`）：
   它们连返回形态都不判，属于"没有形状可断言"。但要在 `wire/rpc/` 的文件头列出来，
   免得下一个人以为漏了。**若将来有人开始读它们的应答，那一刻才搬。**
4. **e（连接器侧类型化 DTO）的触发条件**（写进这里，免得被当成"永远不做"）：
   ① 方法面超过 60 个；或 ② 同一类"取错层"的事故再发生一次；或 ③ 连接器开始被别的客户端消费。
   满足任一，就把 `handlers.ts` 的返回类型写成 TS 接口并生成 Dart —— 那时 `wire/rpc/*.dart` 就是生成目标，
   手写部分只剩语义映射。
