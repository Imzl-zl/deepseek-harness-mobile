# 下一轮提示词：第 0 批（金样机器）+ 第 1 批（`session.list`）

> 用法：新会话整段复制粘贴，或直接说「读 `.agents/notes/proposed/2026-10-25-wire-batch0-and-batch1-prompt.md` 并按它执行」。
> **这一轮写代码**：两个提交（第 0 批、第 1 批各一个），各带门禁与变异校验。
> 预期成本：**0 个模型请求**（不跑真机、不需要 DSH 实例；只跑 `pnpm test` / `flutter test` / `node` 门禁，约十几分钟机器时间）。
> 范围之外的一切都不做 —— 见 §6。

---

## 0. 事实（已经查清，别再重查）

- 项目 `D:\sudy\myproject\dsh-mobile`（Windows / pwsh，中文回复）。
- **先读这五份，按顺序**：
  1. `AGENTS.md`（铁律）、`memory.md`（现状 + 教训九条）、`tools.md`（配方 + 门禁项数的唯一出处）、
     `.agents/notes/AGENTS.md`（笔记规则）。
  2. **`proposed/2026-10-25-wire-design-review.md` —— 本轮的规格**（方案、五判据、七批、
     第一批的形状与要删的行号、代价）。它取代了 `archived/2026-10-25-wire-format-layer.md`
     （旧稿的取证机制不成立，别照它做）。
  3. `implemented/2026-10-25-event-wire-single-decoder.md`（事件面已落地的形态，照它抄手感）。
- 门禁（**改代码后必须全绿**，数字唯一出处 `tools.md`）：connector **657**、flutter **1241**、
  boundary **509**、**`verify-rpc-single-caller` 39 处（预算 39）**、`verify-tool-paths` **23**、
  `dart analyze --fatal-infos` 0、`dart format` 0、契约方法面 **49 / 实现 47**。
- **已经落地的别推翻**：`app/lib/wire/reading.dart`（三态 `WireReading` + `WireDiagnostics`）、
  `app/lib/wire/events.dart`（7 个事件 decoder）、门禁 `wire-field-single-reader`、
  `app/test/event_wire_replay_test.dart` + `fixtures/real-session-events.json`。
- **本轮要落的是规格里的第 0 批与第 1 批**。第 2 批及以后一律不做。

### 三条形状事实（已核实，直接照抄，别再查）

| # | 事实 | 出处 |
|---|---|---|
| 1 | `session.list` 应答 `{sessions:[…]}`，行是**连接器自造**（逐字段构造、不 spread）。**无条件写出**的键：`sid` / `updatedAt` / `running` / `blank` / `subagent`；**条件展开**的 4 个：`parentSessionId` / `model` / `cwd` / `projections` | `connector/src/handlers.ts:738-770`（可选键在 `:750`、`:754-759`、`:760`、`:766-768`） |
| 2 | `session.list` 行里的 `.projections` 是**信封** `{kind, asOfSeq, values}` | 逐键重建在 `connector/src/dsh/sessions.ts:333-341`，过线在 `handlers.ts:766-768` |
| 3 | `session.projections` 的**应答是扁平 `values`**（无信封、永不 `null`，`null`→`{}`） | `connector/src/dsh/projections.ts:68-72` 取 `values`、`:94` 返回 |

第 2 条与第 3 条是同一个名字的两种形状，**这就是本轮要防的那类坑**：第 0 批把它们都收进金样，
第 1 批只解第 2 条（行里的信封），第 3 批（本轮不做）才解扁平 `values`。

---

## 1. 第 0 批：金样机器（一个提交）

**为什么先做它**：真样本是一次性快照，连接器改了应答它不会变，用例永远绿
（与教训第九条同形）。金样由**连接器测试**从真实 handler 产出、深比较守住，App 用例读同一份文件。

1. **新增 `connector/tests/fixtures/wire-shapes.json`**（金样，入库）。结构固定为
   **方法名 → 样本数组**（数组是必须的：多形态方法要放多条）：
   ```json
   {
     "session.list": [ { "sessions": [ … 4 种行 … ] } ],
     "session.projections": [ { "title": "…", "tokenUsage": { … } } ]
   }
   ```
2. **新增 `connector/tests/wire-shapes.test.ts`**：用现成装置（`createHandlers` +
   `tests/support/fake-aliases.js`，见 `connection-methods.test.ts:43-97` 的 `fixtureHandlers`）
   调**真实 handler**，与金样比较。**比较必须在"线上那一层"**：
   比 `JSON.parse(JSON.stringify(result))`，不比 JS 对象 —— `{a: undefined}` 与 `{}`
   在 JS 里不相等、在线上是同一件事。参照 `error-table-parity.test.ts` 的报错写法（红时打 diff）。
   **只有 `UPDATE_WIRE_SHAPES=1` 时才写盘**（快照测试的老做法），平时只比较。
   本轮只收两个方法：`session.list` / `session.projections`。
3. **扩 `connector/tests/connection-methods.test.ts` 的假行**：`sessions.list()` 今天只有 1 行
   （`:53-64`），扩到 4 种 —— 普通 / 带 `parentSessionId` / 冷行（无 `model`、无 `projections`）/
   带完整信封 `projections`（`values` 里要有 `title` / `modelSelection` / `subagentTiming` / `tokenUsage`）。
   **`model` 这个键要先给 `fixtureHandlers` 注入 `deps.models`** 才会出现
   （`handlers.ts:754-759` 的判据是 `deps.models !== undefined`），今天的 `fixtureHandlers`
   没给 —— 不补这一步，4 种行里没有一行带 `model`，"可选键"那一半等于没测。
4. **新增 `app/test/wire_shapes_replay_test.dart`**：读
   `../connector/tests/fixtures/wire-shapes.json`，**文件不存在直接 `fail`（不许 skip）**。
   本轮只断言三件：① 文件里含 `session.list` / `session.projections` 两个键；
   ② 每条样本 `jsonDecode` 出来是 `Map`；③ 两个键的样本条数 ≥1。
   （真正的 decoder 断言是第 1 批的事 —— 这一条先把"文件在、没缩水"钉住。）
5. **新增 `app/tools/verify-rpc-single-caller.mjs`**：扫 `app/lib/data/` 与 `app/lib/ui/`，
   数 `client.call<` 的出现次数，要求**等于预算常量**。今天的实测预算是 **39**
   （`data/app_model.dart` 38、`ui/chat_page.dart` 1；`core/` 里的是 client 调自己，不在范围）
   —— **2026-10-25 已用下面这份实现实跑过：预算 39 ⇒ PASS；改 38 ⇒ 逐行报出 39 个位置**。
   **它不是空名单**：从第一分钟起就禁止第 40 处。预算只许降，`why` 里写死这条纪律。
   直接照抄（**不要**改用 `firstCodeUse` 那种"块注释替换成空格"的剥法 —— 那会把行号冲掉）：

   ```js
   // 判据：协议知识（方法名 + 参数形状）只许待在 wire/ 外面 —— 这个数只许降，终态 0。
   // Note: 为什么是"会归零的数"而不是"名单表" —— 见 .agents/notes/proposed/2026-10-25-wire-design-review.md
   import { readFileSync, readdirSync, statSync } from 'node:fs'
   import { join, relative } from 'node:path'

   const BUDGET = 39
   const DIRS = ['app/lib/data', 'app/lib/ui']
   /** 行首是注释就不算用法。不剥注释是为了保住行号（块注释会被整段吞掉）。 */
   const COMMENT_LINE = /^\s*(\/\/|\*|\/\*)/

   function walk(dir, out = []) {
     for (const entry of readdirSync(dir)) {
       const full = join(dir, entry)
       if (statSync(full).isDirectory()) walk(full, out)
       else if (entry.endsWith('.dart')) out.push(full)
     }
     return out
   }

   const hits = []
   for (const dir of DIRS) {
     for (const file of walk(dir)) {
       readFileSync(file, 'utf8').split('\n').forEach((line, index) => {
         if (COMMENT_LINE.test(line)) return
         if (/client\.call</.test(line)) hits.push(`${relative('.', file)}:${index + 1}`)
       })
     }
   }

   const ok = hits.length === BUDGET
   console.log(`${ok ? 'PASS' : 'FAIL'} — 实测 ${hits.length} 处，预算 ${BUDGET}`)
   if (!ok) {
     for (const hit of hits) console.log('  ', hit)
     process.exitCode = 1
   }
   ```

   路径全部相对仓库根（`verify-tool-paths.mjs` 会拦盘符字面量），`cd` 到仓库根再跑。
   加入 `app/tools/` 后 `verify-tool-paths.mjs` 扫到的脚本数 23 → 24（那条门禁自己会算出来）。
6. **变异校验**：把金样里 `session.list` 某一行的 `running` 改成字符串 `"true"`
   ⇒ 连接器比较**恰好那一条**红。确认金样不是恒真，改回来。

**第 0 批验收**：门禁全绿 + 上条变异恰好 1 红 + 预算脚本在新加一处 `client.call` 时红（临时探针，
验完删）+ `git diff` 里新增 4 个文件（金样、连接器用例、App 回放用例、预算脚本）、改 1 个
（`connection-methods.test.ts`）。

### 两个已经拍过的决定（别重新讨论）

- 金样放 **`connector/tests/fixtures/`**，不放 `protocol/`（`protocol/` 是三端协议向量，性质不同；
  生成者是连接器测试，就跟连接器测试放一起）。
- **`repo.info` 不进第 0 批金样**：它的 `methods` 是 `Object.keys(handlers).sort()`
  （`handlers.ts:1519`），加任何方法它都会变，会为与形状无关的原因常年红。
  要收它先归一成"方法条数"，留到第 4 批。

---

## 2. 第 1 批：`session.list`（一个提交）

### 新文件 `app/lib/wire/rpc/session.dart`

```dart
/// `session.list` 的**唯一入口**：发请求 + 解码。方法名与参数形状只在这个文件里。
/// 收 `SyncClient`（`core/sync_client.dart:140-144` 的既有端口，**不新造 RpcCaller 之类的平行抽象**）。
/// 应答 `{sessions: [...]}`（`connector/src/handlers.ts:738-770`）；行是连接器自造的，
/// 形状出处是连接器而不是 `packages/...`。
Future<List<SessionSummary>> loadSessionList(SyncClient client);

/// 纯解码，给回放用例与"已经拿到应答"的调用方（不收 client，用例里不启传输）。
WireReading<List<SessionSummary>> readSessionList(Object? result);

/// 一行。缺 `sid` / 恒发键 ⇒ WireBad（整行丢 + 计数）；
/// 4 个可选键读不出 ⇒ 该字段降级为 null + 计数（不丢整行）。
WireReading<SessionSummary> readSessionRow(Object? row);
```

**调用必须跟着搬**：`_fetchSessionRows` 改成 `await loadSessionList(client)`，预算 **39 → 38**。
不搬调用，`data/` 就仍然知道方法名与参数形状 —— 那是协议知识漏在 `wire/` 外面，
预算也就降不下来。搬的理由是这个，不是为了迁就某条 grep。

- **产出已有模型类** `SessionSummary`（`app/lib/model/chat_item.dart:778-913`），**不新造 DTO**。
  `chat_item.dart` 不 import `wire/`（已核），所以 `wire → model` 是单向的，不成环。
  `pendingCount` / `itemCount` 是本地派生，由调用方 `copyWith` 补（`app_model.dart:2245-2253`）。
- **必填/可选的分界看生产方式，不看名字**：`handlers.ts:739-769` 里无条件写出的键
  （`sid` / `updatedAt` / `running` / `blank` / `subagent`）缺失 = 漂了 ⇒ `WireBad`；
  被 `...(cond ? {} : …)` 包住的 4 个键缺失 = 正常 ⇒ `null`。
- **`model` 不是恒有的键**：`handlers.ts:754-759` 只在 `deps.models` 存在且 `modelOf(sid)`
  有值时才写。金样必须覆盖"有 `model`"与"整键缺席"两种行，否则第一版 decoder 会把冷行全丢掉。
- **`projections` 是信封**：只断言 `values` 是 `Map`（`kind` / `asOfSeq` 手机不用 ⇒ 不声明）；
  `values` 不是 `Map` ⇒ 四个投影字段全降级 + 计数一次。**头注写明"这是信封，不是扁平 map"**。
- **裸数组分支必须一起删**：`_parseSessionList` 现在两种形状都收（`app_model.dart:3766-3772`，
  注释说"早期的假客户端与将来的简写"），而连接器**从来只回 `{sessions: [...]}`**（`handlers.ts:738`）。
  删分支的同时把 `test/session_list_wiring_test.dart:136-147`（`裸数组也认…`）**改成反向断言**：
  裸数组 ⇒ 空列表 + `badCount == 1`。这是把"容忍假客户端"换成"钉线上形状"，不是删断言。
- 行内二次读（`values.title` / `values.modelSelection` / `values.subagentTiming` / `values.tokenUsage`）
  全部收进本文件；`parseSubagentTiming` / `parseTokenUsage` 仍住 `model/`（它们是投影值解析，第 3 批才搬）。

### 要删掉的旧读法（全在 `app/lib/data/app_model.dart`，行号是 2026-10-25 实测）

| 行 | 是什么 | 处置 |
|---|---|---|
| `747-750` | `_titleHintOf` | 删，进 decoder |
| `758-763` | `_projectionValueOf` | 删，进 decoder（**头注要写"这是信封"**） |
| `2229-2232` | `_fetchSessionRows`（唯一调用点） | 改成 `await loadSessionList(client)` |
| `3765-3843` | `_parseSessionList`（79 行、12 个字段，含 `3766-3772` 的裸数组分支） | 整段删（裸数组分支同时消失） |
| `3853-3857` | `_modelSelectionOf` | 删，进 decoder |
| `3864-3876` | `_parseModelRef` | 删，进 decoder |

`chat_item.dart:854` 与 `app_model.dart:1333` 提到 `_parseSessionList` 的两处注释要跟着改指向。
`_parseModelRef` 若还有别的调用点，先 `grep` 确认（2026-10-25 查过：只在上面两处）。

### 门禁与用例

- **预算 39 → 38**（`app/tools/verify-rpc-single-caller.mjs` 里那一个常量）。
  这一批若只搬了解码、把 `client.call<Object?>('session.list')` 留在 `app_model.dart`，
  处数还是 39 ⇒ 预算对不上 ⇒ 红。这就是"调用必须搬"的机械执行者。
- `app/test/wire_shapes_replay_test.dart` 补 decoder 断言：4 种行**各一条用例**，全部 `WireOk` 且
  `WireDiagnostics.badCount == 0`；**断言值全部来自金样本身，不写常量**（照
  `event_wire_replay_test.dart` 的 `setUp` 里 `reset()` + 收集 sink）。
- 补 2 条"形状错要响"的用例：缺 `sid` ⇒ `WireBad` 且计数 +1；`projections` 的 `values` 是字符串
  ⇒ 该行仍 `WireOk`、四个投影字段为空、计数 +1。
- **变异校验打在可选键上**：把 `values.title` 改成 `values.tittle` ⇒ **恰好 1 条**红。
  别打在恒发键上（`running` 那种会让 4 条同时红，看不出哪一行坏）。

**第 1 批验收**：门禁全绿（含预算 38）+ `data/` 里不再出现 `session.list` 字样 +
`git diff` 里 `_parseSessionList` 整段消失（含裸数组分支）+ 那条旧用例改成反向断言后仍绿 +
变异校验恰好 1 红。

---

## 3. 已知的坑（别重踩）

- **判据有三条路走不通，别试**（都是 2026-10-25 试过并否掉的）：
  ① "方法名在 `app/lib/` 里只出现一次" —— 今天 41 个方法**全都**只出现一次，现在就绿，恒真；
  ② "响应键字面量只许出现在 `wire/rpc/`" —— `'sessions'` 三种意思（`session.list` 的行数组
  `handlers.ts:738`、`sync.hello` 的订阅集 `core/sync_client_impl.dart:205`、
  `usage.summary` 的计数 `int` `model/usage_summary.dart:167`），例外会多到没人看；
  ③ "名字 → 唯一文件"的名单表 —— 一条规则只能表达一个事实，41 个方法 = 41 条规则，
  规则表自己长成第二个真值源。
   **能用的只有"会归零的数"**：`data/`+`ui/` 里 `client.call<` 的处数，39 → 0。
  它度量的是"协议知识还有几处漏在 `wire/` 外面"，不是某个字面量在哪。
- **不要为了迁就判据去改架构**：初稿曾为了"让 grep 看见方法名"而把调用搬进 `wire/`、
  还造了个 `RpcCaller` 回调把 `core/` 挡在外面 —— 顺序反了。搬调用是对的，
  但理由是"`data/` 不该知道方法名与参数形状"；端口 `SyncClient` 本来就有，直接用。
- **裸数组那条用例是真的存在**（`test/session_list_wiring_test.dart:136-147`），删分支时必须同时改它，
  否则第 1 批会红在一个"看起来与本次改动无关"的文件上。
- **`session.page` / `session.refetch` 不在本轮**：它们的解析在连接层
  （`core/sync_client_impl.dart:990-1016`、`:1024`、`:1038-1052`），`SessionPage` 要参与
  `await refetch`，一个纯 decoder 不能 await。它们需要两字段的中间结构，是第 2 批的事。
- **`session.projections` 的 14 个键本轮不解**（第 3 批）。第 0 批只是把它的应答收进金样。
- **金样必须确定性**：不许有时间戳、随机 id、locale 依赖。假 id 走
  `tests/support/fake-aliases.js`；发现不确定字段就在生成器里归一，**不要在比较时放过**。
- **7 个方法的应答今天没有任何一侧断言**（`session.cancel` / `session.updateQueue` / `job.follow` /
  `job.unfollow` / `interaction.respond` / `session.prompt` / `subagent.prompt`）—— 不搬，
  但第 1 批的 `wire/rpc/session.dart` 文件头要把它们列出来，免得下一个人以为漏了。
- **`WireDiagnostics` 是进程级计数**，用例里记得 `reset()`（照 `event_wire_replay_test.dart:67-78`）。
- **`dart format` 会重排文件**，之后再编辑同一文件要**重新读一遍**。
- 改源码**只用编辑工具**（`edit` / `write`），不用 shell 字符串替换 —— shell 出错是静默的。

---

## 4. 交付物

1. 两个提交（第 0 批、第 1 批），各自门禁全绿。
2. 一篇决策笔记 `.agents/notes/implemented/2026-10-25-wire-golden-and-session-list.md`：
   Problem / Decision（金样机制 + 第一批的落地形态）/ Alternatives（至少两条被否的：
   "真样本快照"为什么不够、"`session.page` 一起搬"为什么不一起）/ Consequences（收益 + 代价，
   含"跨工程测试耦合"与"文件缺失必须 fail"）。**代码与笔记同批提交**。
3. `memory.md` 的"下一步"改成下一批（第 2 批或第 3 批，按你的判断），
   `tools.md` 的门禁项数改成实测值（**唯一出处**）。
4. 被约束的代码入口留一行回指注释：`app/lib/wire/rpc/session.dart` 头注指回上面那篇笔记。

---

## 5. 硬规则

- 引用 DSH / 连接器行为给 `packages/...:行号` 或 `connector/src/...:行号`；查不到写「未找到」，**禁止猜**。
- **不许把"枚举/猜类型"当方案**：每个字段的形状必须有出处，出处写进 decoder 头注。
- 门禁项数**只许升**；若因删除行为而减少，在提交信息里写明理由。
- 改断言必须补一次**变异校验**（故意破坏，确认**恰好**那几条红）。
- 提交前看完整 `git status`，重点是**意外的文件**（空的、消失的、没见过的新文件）。
- 不要用 `--no-verify`，不要动 `mock/proto/`。

---

## 6. 明确不做

- 第 2 批及以后（`session.page` / 投影 14 键 / `repo.info` / 文件引用 / 插件 / 收尾）。
- codegen（方案 b）、运行时 schema（方案 c）、连接器侧类型化 DTO（方案 e）—— 触发条件写在
  规格笔记的「仍未决」第 4 条，本轮不碰。
- **`session.prompt` 的写路径（`ui/chat_page.dart:565`）本轮不搬** —— 它是第 7 批的事
  （`sendPrompt(...)`）。**但它最终必须搬**，否则预算归不了零；别把它当成"可以永远留在界面层"。
- 不动 `app/lib/data/projection.dart` 的事件面（那是另一件事）、不动 `mock/proto/`。

---

## 7. 起手命令

```powershell
cd D:\sudy\myproject\dsh-mobile
git log --oneline -5; git status --short
Get-Content .agents\notes\proposed\2026-10-25-wire-design-review.md
Get-Content .agents\notes\proposed\2026-10-25-wire-batch0-and-batch1-prompt.md -TotalCount 40
Get-Content app\lib\wire\reading.dart -TotalCount 60
Get-Content app\lib\wire\events.dart -TotalCount 60
# 复跑一遍基线（改代码前先确认起点是绿的）
node app\tools\verify-platform-boundary.mjs
node mock\proto\tools\verify-tool-paths.mjs
cd connector; pnpm test 2>&1 | Select-Object -Last 20
cd ..\app; flutter test 2>&1 | Select-Object -Last 10
```
