# 线上形状：真值在生产者，判据在金样

- 日期：2026-10-25
- 状态：**已全部落地**（协议知识口禁 0 处、金样 43 个方法、`BUDGET` 常量已删）。
  **实际的批次切分与本篇「迁移」表的七批不同**（落成 8 批：0 / 1 / A1 / A2 / B1 / B2 / B3 / C1 / C2），
  差异与原因记在 `implemented/2026-10-25-wire-rpc-layer-layout.md` 的批次表 —— 那份是施工图，
  本篇是被否方案与判据的来处。
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
   `wire/rpc/<family>.dart`（应答与投影值）。理由不是"层更漂亮"，是**协议知识必须只有一个归属** ——
   方法名、参数形状、应答字段这三样只要还有第二处出现，就会有一处先漂，而漂的表现是静默空值。
   能被度量，所以能被门禁（见机制 4）。
2. **失败语义只有一个**：`WireReading<T>` 三态（`wire/reading.dart:34-60`）。
   面内分层规则：**身份键与"生产者无条件写出的键"缺失 ⇒ 整条丢并计数**；
   **可选键组里的东西读不出来 ⇒ 该字段降级 + 计数，不丢整条**（丢整行会让会话从列表消失，比空标题坏得多）。
   外层 `WireBad` 只留给**信封**错（`{sessions: […]}` 都没了）；行级问题走计数，不升级成 `Bad`——
   否则一行坏就等于整个列表消失。
3. **金样（golden）而不是快照**：`connector/tests/fixtures/wire-shapes.json`，
   由连接器测试用**真实 handler** 产出、**深比较**守住（不相等就红并打 diff）；
   App 的用例读**同一份文件**。这是"漂移怎么被发现"的唯一机械答案，先例是
   `connector/tests/error-table-parity.test.ts:28`（连接器测试读 App 的源码做逐字对撞）。
   **比较必须在"线上那一层"**：比 `JSON.parse(JSON.stringify(result))`，不比 JS 对象 ——
   `{a: undefined}` 与 `{}` 在 JS 里不相等、在线上是同一件事。
4. **判据是一个会归零的数字，不是一张会长大的名单**：
   `app/tools/verify-rpc-single-caller.mjs`（新脚本，二十行）扫 `app/lib/data/` 与 `app/lib/ui/`，
   数 `client.call<` 的**代码**出现次数，要求 **等于预算**；预算逐批下降，**终态 0**。
   实现上**逐行判注释行、不剥注释** —— 剥块注释会冲掉行号，而它必须能报出"哪一行"。
   正则取 `client\.call<` 是精确的：这两个目录里所有 RPC 调用都带显式泛型，
   而 `onEndpointsChanged?.call(...)` 那类回调**不带 `<`**，不会误命中（2026-10-25 实测 39/39）。
   预算是文件里的**一个数**，改它就是"这一批搬了哪个方法"，`git diff` 里看得见。
   为什么不是"方法名 → 唯一文件"的表：那是**代理指标**（方法名字面量在哪 ≠ 应答被谁解释），
   而且一条规则只能表达一个事实 ⇒ 41 个方法就是 41 条规则、每条 +111 项检查，
   规则表本身长成了一个新的真值源。预算只有一个事实：**协议知识还有几处漏在 `wire/` 外面**。
   为什么不是"响应键字面量只许在一处"：`'sessions'` 有三种意思（`session.list` 的行数组
   `handlers.ts:738`、`sync.hello` 的订阅集 `core/sync_client_impl.dart:205`、
   `usage.summary` 的**会话计数 `int`** `model/usage_summary.dart:167`），例外会多到没人看。

**为什么"发请求"也要搬进 `wire/`**：留下调用就等于留下"方法名 + 参数形状"这两样协议知识 ——
`data/` 里仍得知道 `{sid: sid}` 长什么样。所以 `wire/rpc/<family>.dart` 同时是**唯一发请求**和
**唯一断言应答**的地方；它直接收 `SyncClient`（`core/sync_client.dart:140-144` 的既有端口），
**不新造 `RpcCaller` 之类的平行抽象** —— 端口已经有了，再造一个是重复。

准入门槛（可机械判定）：

1. **`data/` 与 `ui/` 里的 `client.call<` 数量 == 预算，预算只降不升，终态 0。**
   今天实测 **39 处**（`data/app_model.dart` 38、`ui/chat_page.dart` 1；`core/` 里的是 client 调自己，
   不在范围）。**这条判据 2026-10-25 用二十行探针实跑过**：预算 39 ⇒ PASS 并列出 39 个位置；
   改成 38 ⇒ FALSE 并逐行报出那 39 处 —— 它确实不是恒真。
   终态"`app/lib/` 除 `wire/rpc/` 外零 `client.call<`"是**绝对规则、零例外** ——
   这一点比"方法名只出现一次"强得多：后者今天 41 个方法**全都满足**，是恒真的空判据。
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

### 次一级的取舍：怎么让"只有一个读者"成立

方案定了 a 之后，真正的难点是**判据**。下面四条都被否过，两条是 2026-10-25 初稿自己踩的。

1. **"方法名 → 唯一允许文件"的名单表（初稿的写法）**
   - 最强的理由：与 `wire-field-single-reader` 同形，评审一眼能核，谁搬完了一目了然。
   - 为何被否：① 它拦的是**代理指标** —— 方法名字面量在哪，不等于应答被谁解释；
     ② 一条规则只能表达一个事实，41 个方法 = 41 条规则、每条 +111 项检查，规则表自己长成第二个真值源；
     ③ 初稿写的"名单从空数组开始"是死脚手架（空名单拦不住任何东西）。
2. **`RpcCaller` 回调（让 `wire/` 不 import `core/`）**
   - 最强的理由：`wire/` 保持零 `core/` 依赖，层次最"干净"，且同样能让字面量只在一处。
   - 为何被否：**端口已经有了** —— `SyncClient` 就是那个抽象（`core/sync_client.dart:140-144`），
     再造一个 `RpcCaller` 是重复抽象，41 个调用点各多一个闭包换零收益。
     依赖方向本来也对：适配器（`wire/rpc`）依赖端口（`SyncClient`），不是反过来。
3. **"响应键字面量只许出现在 `wire/rpc/`"**
   - 最强的理由：与字段门禁完全同形，不必往方法面看。
   - 为何被否：`'sessions'` 三种意思（行数组 / 订阅集 / 计数 `int`），例外一多，规则就没人看了。
4. **只靠 `git diff` 复核"旧读法删干净"（没有判据）**
   - 最强的理由：零机制成本，改动都在评审眼皮底下。
   - 为何被否：这正是三次事故之前的状态 —— 每次都说"这次我看过了"。
     没有数字的判据在一次赶工之后就等于不存在。

## Consequences

- 收益：形状知识从 23 个文件里**除本仓协议之外的 20 来个**收到 `wire/`；失败语义只有一个且可计数；
  漂移在**改连接器的那个提交**里就能被看见（金样 diff + App 回放用例），
  不用等真机 —— 这是三次事故里唯一真正缺的一环。
- 收益：**进度是一个会归零的数字**。39 → 0 写在 `verify-rpc-single-caller.mjs` 的一个常量里，
  评审看那个数就知道搬到哪；终态是一条零例外的绝对规则，不需要维护任何索引或名单。
- 代价：39 处调用分 7 批搬，每批"抓金样 → 写 decoder → 改调用点 → 删旧读法 → 预算减到位"，
  `app_model.dart` 会瘦一大圈（那是好事，但那是个大 diff）。迁移期间 `data/` 是"新旧混住"的，
  这一点没法避免，只能靠预算把水位逼下去。
- 代价：预算是**手写的一个数**，能被顺手改大。防线是"只许降"写进脚本的 `why` + 提交信息里
  必须写明这一批减了什么。
- 代价：**`wire/rpc/` 直接收 `SyncClient`**（它是 `core/` 的端口接口）。
  `wire/` 因此多了一条指向 `core/` 的边 —— 方向是对的（适配器依赖端口），
  但它确实让"`wire/` 只依赖 `reading.dart`"这个纯度说法不成立了，如实记账。
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
| 0 | 机器 | — | ① `wire-shapes.json` 存在且含 `session.list` / `session.projections` 两条；② 连接器深比较（**比 `JSON.parse(JSON.stringify(...))`**）在改一个字段时红；③ App 侧一条"金样在就不会空跑"的用例（文件缺失即 `fail`）；④ 新增 `app/tools/verify-rpc-single-caller.mjs`，预算 = **39**（今天实测数）—— **不是空名单**：它从第一分钟起就禁止第 40 处；顺带 `verify-tool-paths.mjs` 扫到的脚本数 23 → 24 |
| 1 | 会话身份 | `session.list` | ① 预算 **39 → 38**；② **调用也搬进 `wire/rpc/session.dart`**（收 `SyncClient`，产出 `List<SessionSummary>`）；③ 金样含 4 种行（普通 / 带 `parentSessionId` / 冷行无 `model`+无 `projections` / 带信封的 `projections`）；④ 删掉 `app_model.dart:747-750,758-763,2229-2232,3765-3843,3853-3857,3864-3876`，并**删掉 `_parseSessionList` 里的裸数组分支**（见「第一批」）；⑤ 变异校验恰好 1 条红 |
| 2 | 历史页（连接层） | `session.page` / `session.refetch` | ① `SessionPageWire` 的判别联合（`record` / `refetch`）在金样上解全；② `throughSeq` 明确"读了但不用"或"不读"（**今天没读，写成注释**）；③ `core/sync_client_impl.dart:957,990-1016,1024,1038-1052` 的形状读取搬走，`await` 循环留下；④ 变异恰 1 红。**预算不变** —— 这两个走的是 `SyncClient` 的具名方法（`page` / `refetch`），根本不是 `call<`，所以它们天然不占预算，也只能靠"decoder + 金样 + 旧形状读取整段消失"验收 |
| 3 | 投影 | `session.projections` | ① 头注写清"**这里是扁平 `values`，不是信封**"，并交叉引用第 1 批的信封读法；② 金样含全部 **14** 个被 App 消费的键；③ 6 个 `model/*` 解析器（`session_stats` / `subagent` / `trajectory` / `image_limits` / `permission.currentValue` / `agent_preset`）搬进 `wire/rpc/projections.dart`；④ 变异恰 1 红 |
| 4 | 能力面 | `repo.info` | ① `commands` 两种形状**都收**，并在头注写明"这是兼容，不是两个真值"（`handlers.ts:1525`）；② 金样两条：带 `commands` / 不带 `commands`；③ 三个 `caps` 布尔与 `dshVersion` 的缺失语义固定；④ 变异恰 1 红 |
| 5 | 文件与引用 | `file.list` / `file.read` / `refs.files` / `refs.sessions` | ① `model/workspace_files.dart` 的 `fromWire` 变成返回 `WireReading`（**唯一一处 d→a 的机械改造**，形状不动）；② 金样含 `size?` / `bytes?` 缺席两条；③ 预算按本批实际搬走的 `call<` 处数下调（实测：`app_model.dart:1771,1800,1998,1999` 四处 → −4）；④ 变异恰 1 红 |
| 6 | 插件 | `plugin.list` / `listBundles` / `install*` | ① `plugin.installStatus` 的"4 键 unknown vs 8 键"两形态各一条金样（`connector/src/dsh/plugin-install.ts:250-262`）；② `plugin.list` 的 `patchId?` / `readOnlyReason?` 恰有一个，decoder 不能两个都当必填；③ 预算按实测下调（`:1855,1856,1889,1938,1955,1968` 六处 → −6）；④ 变异恰 1 红 |
| 7 | 收尾 | `usage.summary` / `settings.*` / `job.*` / `command.execute` / `permission.*` / `workspace.*` / `endpoint.describe` / `session.select-model` / `session.create` / `session.cancel` / `session.updateQueue` / `interaction.respond` / **`session.prompt`** | ① 每个方法至少一条金样；② `workspace.*` 的"归档/置顶全集"三处共用一份 decoder；③ **预算归 0**，并把常量从脚本里删掉（规则从此是零例外的绝对规则）；`ui/chat_page.dart:565` 的 `session.prompt` 搬成 `wire/rpc/session.dart` 的 `sendPrompt(...)`；④ 全量门禁绿 + 变异恰 1 红 |

**"删掉旧读法"怎么机械化验收**（这是前一版草案没答的问题，也是本稿前两版都答错的地方）：

- **判据必须是"协议知识还有几处漏在 `wire/` 外面"，不是"某个字面量在哪"**。
  可度量的代理就是**`data/`+`ui/` 里 `call<` 的处数**：今天 39，搬完方法就必然少一处，
  终态 0。写成一个常量，只许降 —— 这既是判据也是进度表，而且**只有一个数字**。
- 前两版错在：先选"能 grep 的东西"（方法名字面量），再为了让它成立去改架构
  （把调用搬走、造 `RpcCaller`）。顺序反了 —— 应该先定架构（协议知识只在一个模块），
  再找能度量它的最小判据。搬调用仍然是必须的，但**理由变成"`data/` 不该知道方法名与参数形状"**，
  不是为了迁就一个 grep。
- 为什么不用"方法名出现次数"：今天 41 个方法**全都只出现一次**，这条判据现在就是绿的，
  恒真 —— 拦不住任何东西。
- 为什么不用"响应键字面量"：`'sessions'` 在同一个方法面里有三种意思（
  `session.list` 的行数组 `handlers.ts:738`、`sync.hello` 的订阅集 `core/sync_client_impl.dart:205`、
  `usage.summary` 的**会话计数 `int`** `model/usage_summary.dart:167`）。例外一多，规则就没人看了。

## 第一批的具体形状（`session.list`）

### decoder（`app/lib/wire/rpc/session.dart`，新文件）

```dart
/// `session.list` 的**唯一入口**：发请求 + 解码。方法名与参数形状只在这个文件里。
/// 收 `SyncClient`（`core/sync_client.dart:140-144` 的既有端口，**不新造平行抽象**）。
/// 应答 `{sessions: [...]}`（`connector/src/handlers.ts:738-770`）；
/// **行是连接器自造的，不是宿主形状**（`handlers.ts:719-720` 的原话："逐字段构造、不 spread"），
/// 所以形状出处是连接器，不是 `packages/...`。
Future<List<SessionSummary>> loadSessionList(SyncClient client);

/// 纯解码，给回放用例与"已经拿到应答"的调用方（不收 client，用例里不启传输）。
WireReading<List<SessionSummary>> readSessionList(Object? result);

/// 一行。缺 `sid` / 恒发键 ⇒ WireBad（整行丢 + 计数）；
/// 4 个可选键读不出 ⇒ 该字段降级为 null + 计数（不丢整行）。
WireReading<SessionSummary> readSessionRow(Object? row);
```

调用点（`app_model.dart` 的 `_fetchSessionRows`）变成 `await loadSessionList(client)`
—— `data/` 从此不知道方法名，也不知道 `{sessions: …}` 长什么样，预算 39 → 38。

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
- **`model` 这个键不是恒有的**：`handlers.ts:754-759` 只在 `deps.models` 存在且
  `modelOf(sid)` 有值时才写。金样要覆盖"有 `model`"与"整键缺席"两种行，
  否则第一版 decoder 会把 `model` 当必填而线上冷行全丢。
- **裸数组分支必须随函数一起删**：`_parseSessionList` 现在两种形状都收
  （`app_model.dart:3766-3772`，注释说"早期的假客户端与将来的简写"），
  而连接器**从来只回 `{sessions: [...]}`**（`handlers.ts:738`）。留着它，
  "认不出就必须留声"这条永远不成立。删分支的同时要把
  `test/session_list_wiring_test.dart:136-147`（`裸数组也认…`）**改成反向断言**：
  裸数组 ⇒ 空列表 + `badCount == 1`。这是把一条"容忍假客户端"的用例换成"钉线上形状"的用例，
  不是删断言。
- **用例与变异校验的对应关系要对齐**：4 种行**各一条用例**（诊断更快），
  变异打在**可选键**上（把 `values.title` 改成 `values.tittle`）⇒ 恰好 1 条红。
  打在恒发键上（如 `running`）会让 4 条同时红，看不出是哪一行坏的。

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
2. **`session.prompt` 的调用点在 `ui/chat_page.dart:562-571`**（不在 `data/`）。**它必须搬**，
   否则预算归不了零；放在第 7 批搬成 `wire/rpc/session.dart` 的 `sendPrompt(...)`。
   （这一条前一版写成"留到落地后再定"，是错的：留着它就等于留一处在 `wire/` 外面说协议。）
3. **7 个"无人消费应答"的方法不搬**（`session.cancel` / `session.updateQueue` / `job.follow` /
   `job.unfollow` / `interaction.respond` / `session.prompt` / `subagent.prompt`）：
   它们连返回形态都不判，属于"没有形状可断言"。但要在 `wire/rpc/` 的文件头列出来，
   免得下一个人以为漏了。**若将来有人开始读它们的应答，那一刻才搬。**
4. **e（连接器侧类型化 DTO）的触发条件**（写进这里，免得被当成"永远不做"）：
   ① 方法面超过 60 个；或 ② 同一类"取错层"的事故再发生一次；或 ③ 连接器开始被别的客户端消费。
   满足任一，就把 `handlers.ts` 的返回类型写成 TS 接口并生成 Dart —— 那时 `wire/rpc/*.dart` 就是生成目标，
   手写部分只剩语义映射。
