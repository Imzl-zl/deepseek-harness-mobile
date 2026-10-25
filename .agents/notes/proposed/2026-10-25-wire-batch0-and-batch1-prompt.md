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
  boundary **509**、`dart analyze --fatal-infos` 0、`dart format` 0、契约方法面 **49 / 实现 47**。
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
   调**真实 handler**，与金样 `deepStrictEqual`；不一致就红并打印 diff。
   **只有 `UPDATE_WIRE_SHAPES=1` 时才写盘**（快照测试的老做法），平时只比较。
   本轮只收两个方法：`session.list` / `session.projections`。
3. **扩 `connector/tests/connection-methods.test.ts` 的假行**：`sessions.list()` 今天只有 1 行
   （`:53-64`），扩到 4 种 —— 普通 / 带 `parentSessionId` / 冷行（无 `model`、无 `projections`）/
   带完整信封 `projections`（`values` 里要有 `title` / `modelSelection` / `subagentTiming` / `tokenUsage`）。
4. **新增 `app/test/wire_shapes_replay_test.dart`**：读
   `../connector/tests/fixtures/wire-shapes.json`，**文件不存在直接 `fail`（不许 skip）**。
   本轮只断言三件：① 文件里含 `session.list` / `session.projections` 两个键；
   ② 每条样本 `jsonDecode` 出来是 `Map`；③ 两个键的样本条数 ≥1。
   （真正的 decoder 断言是第 1 批的事 —— 这一条先把"文件在、没缩水"钉住。）
5. **加门禁规则 `wire-rpc-single-reader`**（`app/tools/verify-platform-boundary.mjs`）：
   名单是 `方法名 → 唯一允许出现的文件`，**本轮从空数组开始**（空名单不拦任何东西）。
   规则形态照现有 `wire-field-single-reader`（`:129-134`）：`appliesTo` 排除目标文件、
   `firstCodeUse` 先剥注释再匹配字面量。配 **2 条自检**：反例 = 方法名出现在 `data/`（应红）、
   正例 = 出现在 `wire/rpc/`（应放过）。
6. **变异校验**：把金样里 `session.list` 某一行的 `running` 改成字符串 `"true"`
   ⇒ 连接器深比较**恰好那一条**红。确认金样不是恒真，改回来。

**第 0 批验收**：门禁全绿 + 上条变异恰好 1 红 + `git diff` 里新增 4 个文件、改 2 个。

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
/// `session.list` 的应答：`{sessions: [...]}`（`connector/src/handlers.ts:738-770`）。
/// 行是连接器自造的，形状出处是连接器而不是 `packages/...`。
WireReading<List<SessionSummary>> readSessionList(Object? result);

/// 一行。缺 `sid` / 恒发键 ⇒ WireBad（整行丢 + 计数）；
/// 4 个可选键读不出 ⇒ 该字段降级为 null + 计数（不丢整行）。
WireReading<SessionSummary> readSessionRow(Object? row);
```

- **产出已有模型类** `SessionSummary`（`app/lib/model/chat_item.dart:778-913`），**不新造 DTO**。
  `pendingCount` / `itemCount` 是本地派生，由调用方 `copyWith` 补（`app_model.dart:2245-2253`）。
- **必填/可选的分界看生产方式，不看名字**：`handlers.ts:739-769` 里无条件写出的键
  （`sid` / `updatedAt` / `running` / `blank` / `subagent`）缺失 = 漂了 ⇒ `WireBad`；
  被 `...(cond ? {} : …)` 包住的 4 个键缺失 = 正常 ⇒ `null`。
- **`projections` 是信封**：只断言 `values` 是 `Map`（`kind` / `asOfSeq` 手机不用 ⇒ 不声明）；
  `values` 不是 `Map` ⇒ 四个投影字段全降级 + 计数一次。**头注写明"这是信封，不是扁平 map"**。
- 行内二次读（`values.title` / `values.modelSelection` / `values.subagentTiming` / `values.tokenUsage`）
  全部收进本文件；`parseSubagentTiming` / `parseTokenUsage` 仍住 `model/`（它们是投影值解析，第 3 批才搬）。

### 要删掉的旧读法（全在 `app/lib/data/app_model.dart`，行号是 2026-10-25 实测）

| 行 | 是什么 | 处置 |
|---|---|---|
| `747-750` | `_titleHintOf` | 删，进 decoder |
| `758-763` | `_projectionValueOf` | 删，进 decoder（**头注要写"这是信封"**） |
| `2229-2232` | `_fetchSessionRows`（唯一调用点） | 改成 `valueOrReport(readSessionList(await client.call<Object?>('session.list', const {})), 'session.list') ?? const []` |
| `3765-3843` | `_parseSessionList`（79 行、12 个字段） | 整段删 |
| `3853-3857` | `_modelSelectionOf` | 删，进 decoder |
| `3864-3876` | `_parseModelRef` | 删，进 decoder |

`chat_item.dart:854` 与 `app_model.dart:1333` 提到 `_parseSessionList` 的两处注释要跟着改指向。
`_parseModelRef` 若还有别的调用点，先 `grep` 确认（2026-10-25 查过：只在上面两处）。

### 门禁与用例

- 把 `session.list` 加进 `wire-rpc-single-reader` 的名单（唯一允许文件 `app/lib/wire/rpc/session.dart`）；
  旧读法没删干净这条会先红 —— **先加规则、再删代码、最后绿**。
- `app/test/wire_shapes_replay_test.dart` 补 decoder 断言：4 种行各一条，全部 `WireOk` 且
  `WireDiagnostics.badCount == 0`；**断言值全部来自金样本身，不写常量**。
- 补 2 条"形状错要响"的用例：缺 `sid` ⇒ `WireBad` 且计数 +1；`projections` 的 `values` 是字符串
  ⇒ 该行仍 `WireOk`、四个投影字段为空、计数 +1。

**第 1 批验收**：门禁全绿 + `session.list` 在 `app/lib/` 只剩 1 处（在 `wire/rpc/session.dart`）+
`git diff` 里 `_parseSessionList` 整段消失 + 变异校验恰好 1 红
（把 decoder 里 `entry['running']` 改成 `entry['isRunning']`）。

---

## 3. 已知的坑（别重踩）

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
- `session.prompt` 的写路径要不要搬进 `wire/rpc/`（它在 `ui/chat_page.dart:562-571`）——
  留到第 1 批落地后单独定。
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
cd connector; pnpm test 2>&1 | Select-Object -Last 20
cd ..\app; flutter test 2>&1 | Select-Object -Last 10
```
