# 投影的"事件载荷读者"独立成端口（三族）

- 日期：2026-11-06
- 状态：implemented（**三族全部落地**；`app/lib/data/` 的 `fieldOf(` **归零**，
  门禁 `data-no-fieldof` 已加）
- 前情：`data → wire` 四批落地后 `app/lib` 只剩 `data/projection.dart` 一条 wire
  import（`implemented/2026-11-06-p1b-batch4-read-write-ports.md`）。

## Problem

那条 import 只是冰山。`data/projection.dart` 是"事件语义的唯一归宿"（哪条事件变成
界面上什么），但它同时**在读线上字段**：

- 6 个读者从 `wire/events.dart` 直接 import（`readToolCall` / `readToolResult` /
  `readApprovalAsked` / `readApprovalDecided` / `readQuestionReply` / `mergedToolCallOf`）；
- 另外 **42 处 `fieldOf(data, '…')`** 直接读线上字段名，覆盖约 20 种事件。

两件事的变更原因不同：DSH 改字段名只该动 `wire/`，我们改界面表现只该动 `data/`。
混在一起时，改字段名要进投影，改投影又要看懂线上形状。**门禁当时也看不见** ——
`verify-*` 只数 import，所以"1 条 import"底下藏着 42 处字段名。

## 被否掉的方案（先说，免得后人再走一遍）

**在解码边界产出 typed 事件**（`SessionEvent.body` + 每种事件一个 sealed 子类型）：
形状最漂亮，但代价全落在不该付出的地方 ——

- `SessionEvent` 加必填字段 ⇒ **60+ 个构造点**（多数在测试）；
- 动**收帧热路径**（每条事件都要解），而落盘存的是原始 `data`，冷启动还得再解一次；
- 换来的"编译器穷举"在"DSH 上游会加新事件类型"这个现实下**本来就要留 default 分支**，
  等于没换到东西（`projectEvent` 现在就有 `OtherItem` 兜底）。

## 第 1 族（工具 / 审批 / 提问）

```text
core/event_fields.dart      EventFields（第 1 族的 6 个方法，返回可空）+ 5 个载荷值类型
wire/event_fields.dart      WireEventFields：调 wire 读者 → valueOrReport 计数 → 值或 null
```

- **读不出就是 `null`**：计数与出声留在 `wire/`（`valueOrReport`）。因此 `data/` 不再
  需要三态内核（`WireReading` / `WireBad`），那条 import 才真的能删掉。
- **值类型搬进 core**（`ToolCallPayload` 等 5 个）：它们要穿过端口交给 `data/`，类型跟着
  端口走，`wire/events.dart` 里原来那 5 个 `*Wire` 类**删掉**（不 typedef、不留别名）——
  留一份同样的字段表就是两处真值。`command/*` 的载荷没有手机侧消费者，留在 wire。
- **只放真实消费者的方法**：`readCommandRun` / `readCommandDone` 只有 `EventIdReaders`
  与回放用例在用，**不进端口**（端口上多一个没人调的方法就是一处要维护的空转面）。
- **注入**：`HostRpcHolder` 加第三个 getter `eventFields`（纯解码、不碰连接，所以
  `WireHostRpc` 直接给 `const WireEventFields()`）；`projectEvent` /
  `interactionSignalOf` 收 `required EventFields fields`。装配点、`SyncClientDeps`、
  5 处装配行**一行没改**。
- **测试路径不变**：`test/projection_fixture.dart` 传的是**生产那份** `WireEventFields`，
  夹具仍是原始协议 JSON；它同时新增 `interactionSignalOf` 的转发版，19 个用例调用点
  一个字符没改（沿用 P1 给 `projectEvent` 建转发版的同一手法）。

## 第 2 族（消息与内容块）

端口再加 4 个方法，`data/` 里对应删掉 6 个"读原生 map"的助手函数：

| 端口方法 | 把哪些读取搬走了 |
|---|---|
| `message(type, data)` → `MessagePayload{blocks, usage, name}` | `data` / `data.message` 两种持有位置、`content` 在哪、用量在顶层 |
| `sourceKind(data)` | `source.kind` |
| `diffHunks(data)` | `data.meta.diffs` ?? `message.metadata.diffs` 这条兜底链 |
| `isToolError(data)` | `message.isError` / `message.status` |

**块只解到"种类"这一层**：`ContentBlock{kind, text}`，`kind` 是
`text / reasoning / image / file / other`。哪块算正文、哪块算思考、附件怎么数仍是
`data/` 的判断（那是语义，不是形状）—— 所以 `textOfContent` / `reasoningOf` /
`attachmentCountOf` 从"读原生 map"变成"折叠解好的块表"，`MessageProjection` 与
`messageProjectionOf` 直接删掉（`projectEvent` 里现算三样值）。

**复用 `model/tool_view.dart` 的 `DiffHunk`**，不新造一个：同一个概念（一段
旧文本→新文本）在仓里只能有一个类型，否则 `+N/−M` 的两条算法各认各的形状。

## 第 3 族（重试 / 轮次收口 / 压缩 / 交互工具入参）

端口再加 4 个事件载荷方法 + 1 个工具入参方法：

| 端口方法 | 把哪些读取搬走了 |
|---|---|
| `retry(data)` → `RetryPayload` | `retry` / `maxRetries` / `delayMs` / `failure.message` / `failure.code`（`llm/retry` 与 `llm/retry-started` 两支） |
| `turnEnd(data)` → `TurnEndPayload` | `turn`、`reason.kind`、`reason.error.{message,code}`、`reason.reason.{kind,reason}` |
| `compaction(data)` → `CompactionPayload` | `sourceCommandId`（手动 `/compact` 的判据）、`summary` 块表（复用 `ContentBlock`）、`shadowedSeqs`、`shadowedTokenCount` |
| `interactionQuestions(arguments)` → `List<InteractionQuestion>` | `questions[].{id,question,header,detail,multi_select,options[].{label,description}}` |
| `planText(arguments)` | `exit_plan_mode` 的 `arguments.plan` |

- **第 5 个方法是第 3 族补的，不在最初的四格里**：`data/` 里除了这 4 个方法覆盖的读取，
  还剩两处 `fieldOf` —— `tool/result` 的 `data.message` 与计划审查的 `arguments.plan`。
  前者由 `diffHunks` 自己取消息、结果自带的 `name` 进 `MessagePayload.name`（投影解一次、
  名字与正文都从同一份值里用）；后者单列 `planText`。不补这两个，"`fieldOf` = 0" 不成立。
- **"（推荐）"的识别搬到 `model/interaction.dart`**（`InteractionOption.fromToolSchema`）：
  它是"标签 → 选项字段"的构造规则，与 `InteractionOption` 同住一处；投影不再自己写第二条
  正则。问题/选项直接复用 `InteractionQuestion` / `InteractionOption`，**没有在 core
  再造一份值类型**。
- **判据仍留在 `data/`**：哪一种 `reason.kind` 算失败 / 停止、登出的 `hook` +
  `deepseek-account/signed-out`、`shadowedSeqs.length` 才是条目数、摘要里哪块算正文 ——
  端口只把字段读出来（`shadowedSeqs` 的"每项都得是安全非负整数"是**形状**判据，与 DSH
  `command.ts:113-115` 同一处，所以留在 wire）。
- **计数口径**：身份 / 必需字段走 `wire/events.dart` 的 `readXxx` + `valueOrReport`；
  `retry` / `turnEnd` / `compaction` / 工具入参是**宽松取值**（那些字段本来就可能缺），
  不计数 —— 与 `message` / `sourceKind` / `diffHunks` 同一档。

## 收尾批（命令 / 审批收口 / 改动）：`data/` 的字段名归零

三族之后 `data/` 还剩 9 处 `stringField` / `intField` —— 5 个事件，字段全部照 DSH 的
事件 schema 对齐：

| 事件 | DSH schema | 端口方法 / 载荷 |
|---|---|---|
| `command/run` | `{commandId, name, args?, source}`（`packages/interaction/commands/src/types.ts:105`） | `commandRun` → `CommandRunPayload`（`source` 手机不消费，不搬） |
| `command/done` | `{commandId, kind: 'success'\|'error', text?, sourceEventSeq?}`（同上 `:112-117`） | `commandDone` → `CommandDonePayload` |
| `approval/asked` | `{id, toolName, callId?, reason?}`（`user-approval/src/types.ts:44-49`） | 复用已有的 `approvalAsked`（第 1 族就有，投影当时没接） |
| `approval/decided` | **`{id, outcome}`**（同上 `:55-58`） | `approvalDecided` → 载荷加 `outcome` |
| `workspace/changes` | `{turn: number}`（`deliverables/workspace-changes/src/types.ts:106`） | `changesTurn` → `int?` |

- **`CommandRunWire` / `CommandDoneWire` 搬进 `core/`** 并改名 `CommandRunPayload` /
  `CommandDonePayload`：它们本来就是照 DSH 抄的，留在 wire 只是因为第 1 族当时判断
  "`command/*` 没有手机侧消费者"—— 那个判断错了，消费者是投影，只是它用 `stringField`
  手读同几个字段，所以没被算成"读者"。现在 `wire/events.dart` 里**一个载荷类型都不留**。
- **`approval/decided` 没有 `toolName`**：DSH 只写 `{id, outcome}`。投影里那行
  `stringField(data, 'toolName') ?? '审批'` 是读一个永远不会出现的字段（真实日志下标题
  恒为「审批」），随这次收口**删掉**，标题改成常量。
- **缺 `id` 不是展示语义**：`approval/asked` 的 `id` 在 DSH 是必填、由服务端在 append
  之前铸造（`user-approval/src/index.ts:251-257`），而我们的 `itemIdOf` 缺它直接抛
  （`core/items.dart:151-155`）—— 缺 id 的事件到不了投影。投影里 `approvalAsked` 为空时
  仍画一行通用文案，与工具卡在 `toolCall == null` 时的处理同一档：不静默丢事件。
- `workspace/changes` 的 `turn == null ⇒ skip` 保留：`projectEvent` 的 `itemId` 是**入参**
  （调用方可以给任何 id），纯函数不能假设它由 `data` 算出，所以这条兜底不是死代码。

## 工具结果 meta：`model/tool_view.dart` 的那一整块读者

`tool/result.data.meta`（DSH 的 `presentationMeta`）原先由 `model/tool_view.dart` 自己读：
`_field(data, 'meta')` / `_string` / `_int`，外加 hunk 与行号的键名（19 处）。同一个
不变量（事件载荷的字段名只许在 `wire/`），只是破口在 `model/`。

- 端口加 `toolMeta(data)` → `ToolResultMeta`。**类型住在 `model/tool_view.dart`**（与
  `FileTextLine` / `DiffHunk` 同处），core 只 import：搬进 core 会造一条
  `core/event_fields ↔ model/tool_view` 的直接环，而这些类型本来就是"这个视图的输入"。
- `toolResultViewOf({name, meta, text})`：正文由调用方给（`textOfContent(resultMessage.blocks)`），
  不再自己解一遍 `message.content`；`_field` / `_string` / `_int` / `_parseHunks` /
  `_contentText` 全删。**hunk 解码只留一处**：`diffHunks` 与 `toolMeta` 共用
  `_diffHunks`（同一个 `meta.diffs` 原先有两个读者）。
- 测试：`test/tool_view_fixture.dart` 提供同名转发版（收**原始结果载荷**，meta 与正文都走
  `WireEventFields`），`tool_views_test.dart` 的 8 个调用点一个字符没改 —— 解码器仍在测试
  路径上。

## 门禁（第 3 族落地后加）

`verify-platform-boundary.mjs` 新增 **`data-no-field-name`**：`app/lib/data/**` 里**把线上
字段名当字面量传给宽松取值助手**（`fieldOf` / `stringField` / `intField`）即红，**报文件与
行号**（`stripComments` 把注释换成等长空白，行号仍对得上；注释里提到不算违规）。判据一句
话：**事件载荷的字段名只许在 `wire/` 断言，`data/` 只收解好的值**。

第一版规则钉的是 `fieldOf(` 这个**拼写**：`fieldOf` 归零时 `data/` 里还留着 9 处
`stringField`，等于规则自己给绕路留了门（同一天发现、当天收紧）。规则钉"字段名当字面量"
之后，`fieldOf(x, 'k')` 与 `stringField(x, 'k')` 是同一件事。自检 4 条：两种拼写各一条
反例、注释一条正例、解好的值一条正例。

## 验证

- `dart analyze --fatal-infos lib test` / `integration_test` → 各 0。
- `flutter test` → **1759** 全过（三族与收尾批前后同数：没有新增用例，行为不变）。
- `verify-platform-boundary.mjs` → **827** 项全过（自检 **29** 条 + 扫描 **187** 个 Dart
  文件；`data-no-field-name` 让 `app/lib/data/` 的 19 个文件各多过一遍 = 804 → 825 → 827）。
- `verify-rpc-single-caller.mjs` → PASS；`dart format --set-exit-if-changed` → 0。
- `git grep -n "^import .*wire/" -- app/lib/data app/lib/ui app/lib/core` → **0 个文件**
  （装配点 `main.dart` 不在这次搬迁范围内，它本来就该认识实现）：`data/projection.dart`
  的最后一条 wire import 也关掉了。
- `data/` 里 `fieldOf(` / `stringField(` / `intField(` → **42 → 22 → 0**（9 → 0 是收尾批）。
- **变异校验**（每批一次，还原后各全绿）：
  - 前两族：`WireEventFields.toolCall` 恒 `null` ⇒ `plan_review_test` +
    `message_rendering_test` + `event_wire_replay_test` **3 条红**；`_blocks` 把 `reasoning`
    当成 `text` ⇒「助手消息的 reasoning 块抽成思考过程」**1 条红**。
  - 第 3 族：`retry` 恒空载荷 ⇒ `turn_outcome_test` **5 条红**；`turnEnd` 恒空载荷 ⇒
    同一文件 **7 条红**；`compaction` 恒空载荷 ⇒ `compaction_item_test` **6 条红**；
    `interactionQuestions` 恒空表 ⇒ `interaction_projection_test` 2 条 +
    `event_wire_replay_test` 1 条 = **3 条红**。
  - 收尾批：`commandRun` 恒 `null` ⇒ `command_item_test` **3 条红**；`changesTurn` 恒
    `null` ⇒ `changes_card_test` **14 条红**；把 `approval/decided` 的 `outcome` 丢掉 ⇒
    **0 条红** —— `ApprovalItem.decision` 没有显示读者（只有 `SessionStore` 的 `==`），
    这个字段目前**没有回归网**，记在这里不假装有。
  - meta 批：`toolMeta` 恒空载荷 ⇒ `tool_views_test` **5 条红**（read 解析、两组 +N−M、
    两条渲染）。
  - 门禁本身：在 `projection.dart` 临时加一行 `stringField(_probeData, 'toolName')` ⇒
    `data-no-field-name: app/lib/data/projection.dart → 命中「stringField(…, 'toolName')
    （第 1112 行）」`，**1/827 红**；删掉即全绿。

## 边界（这一版覆盖到哪里）

- `app/lib/data/` 里**没有**按线上字段名取值的地方（`fieldOf` / `stringField` /
  `intField` 全为 0），门禁 `data-no-field-name` 钉住它：事件载荷的字段名只许在 `wire/`
  断言，`data/` 只收解好的值。
- **门禁认的形状**是"助手调用 + 字段名字面量"；`map['key']` 这种直接下标不在它的匹配里。
  `data/` 目前没有这种读法（工具参数那一层用的是变量键，见下一条），所以这条门禁对
  `data/` 是完整的；换到别的目录（例如 `model/`）就不完整，别再拿它当"零字段名"的证据。
- **`model/` 里的 `fromWire` / `parseX` 是既定分层，不是倒置**：`wire → model/core` 单向
  （`model/` 与 `core/` 零 wire import），值类型自己断言自己的载荷字段，`wire/rpc/*` 只读
  信封键与方法名。这条在 `docs/subsystems/app-channel-client.md` 的规则列表里写成两层判据
  （会话事件 / RPC 应答），此前那句"线上载荷的字段名只在 `wire/` 断言"只对事件成立。
- 真正的不一致已收口：`wire/rpc/projections.dart` 里 4 个**内联**载荷解析器
  （`_sessionStatsOf` / `_contextPressureOf` / `_contextBreakdownOf` / `_turnOutlineOf`）
  搬进值类型 —— `SessionStats.fromWire` / `ContextPressure.fromWire` /
  `ContextBreakdown.fromWire` / `TurnOutlineEntry.listFromWire`。那个文件现在只读投影键
  （`values['key']`）。
- **工具参数**（`changed_path.dart` 的 `file_path` / `old_string`…、`_toolSummaryKeys`）
  不属这两层：它是模型填的工具 schema，不是 DSH 的事件 / RPC 契约。口径写在这里。
- **工具参数键名**（`bash` 的 `command`、`read` 的 `path` 等，`_toolSummaryKeys` /
  `_flatten`）不属于这条门禁：那是模型填的工具 schema，不是 DSH 事件契约。口径写在这里，
  下一批要动它得先改这条判据。
- `app/lib` 里 `wire/` 之外**零 import**（`core/`、`data/`、`ui/` 都是 0）。
